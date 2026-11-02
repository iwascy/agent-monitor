import Foundation
import Testing
@testable import AgentMonitorCore

@Suite("Claude Code Hooks Tests")
struct ClaudeHookTests {

    private func createTempDir() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("agent-monitor-test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func appendLine(_ line: String, to url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            try line.data(using: .utf8)!.write(to: url)
        } else {
            let handle = try FileHandle(forWritingTo: url)
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            try handle.close()
        }
    }

    // MARK: - ClaudeHookEventReader Tests

    @Test("ClaudeHookEventReader: incremental read, partial lines, and truncation reset")
    func testReaderIncrementalAndTruncation() throws {
        let tempDir = createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let tsvURL = tempDir.appendingPathComponent("claude.tsv")
        let reader = ClaudeHookEventReader(fileURL: tsvURL)

        // 初始为空，poll 返回空字典
        #expect(reader.poll().isEmpty)
        #expect(reader.lastEvent == nil)

        // 1. 写入第一行完整事件
        let line1 = "1730530000\t{\"session_id\":\"s1\",\"hook_event_name\":\"SessionStart\",\"transcript_path\":\"/path/to/t1.jsonl\"}\n"
        try line1.data(using: .utf8)!.write(to: tsvURL)

        var states = reader.poll()
        #expect(states.count == 1)
        #expect(states["s1"]?.event == "SessionStart")
        #expect(states["s1"]?.transcriptPath == "/path/to/t1.jsonl")
        #expect(reader.lastEvent?.event == "SessionStart")

        // 2. 写入半行（不以 \n 结尾）和完整第二行
        let handle = try FileHandle(forWritingTo: tsvURL)
        handle.seekToEndOfFile()
        let halfLine = "1730530010\t{\"session_id\":\"s2\",\"hook_event_name\":\"Per"
        handle.write(halfLine.data(using: .utf8)!)
        try handle.close()

        // 此时不应解析半行
        states = reader.poll()
        #expect(states.count == 1)
        #expect(states["s2"] == nil)

        // 补齐第二行
        let handle2 = try FileHandle(forWritingTo: tsvURL)
        handle2.seekToEndOfFile()
        let restOfLine = "missionRequest\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls -la\"}}\n"
        handle2.write(restOfLine.data(using: .utf8)!)
        try handle2.close()

        states = reader.poll()
        #expect(states.count == 2)
        #expect(states["s2"]?.event == "PermissionRequest")
        #expect(states["s2"]?.toolName == "Bash")
        #expect(states["s2"]?.toolDetail == "ls -la")
        #expect(states["s2"]?.detailIsCommand == true)
        #expect(reader.lastEvent?.event == "PermissionRequest")

        // 3. 文件被截断（例如从头写入更短内容）
        let truncatedLine = "1730530020\t{\"session_id\":\"s3\",\"hook_event_name\":\"Stop\"}\n"
        try truncatedLine.data(using: .utf8)!.write(to: tsvURL)

        states = reader.poll()
        #expect(states.count == 1)
        #expect(states["s1"] == nil)
        #expect(states["s3"]?.event == "Stop")
        #expect(reader.lastEvent?.event == "Stop")
    }

    @Test("ClaudeHookEventReader: rotation when file exceeds 5MB")
    func testReaderRotation() throws {
        let tempDir = createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let tsvURL = tempDir.appendingPathComponent("claude.tsv")
        let rotatedURL = tempDir.appendingPathComponent("claude.tsv.1")

        // 写入超过 5MB 的假数据
        let largeData = Data(repeating: 0x41, count: 5 * 1024 * 1024 + 100)
        try largeData.write(to: tsvURL)

        // 构造 reader 时应触发轮转
        _ = ClaudeHookEventReader(fileURL: tsvURL)

        #expect(FileManager.default.fileExists(atPath: rotatedURL.path))
        #expect(!FileManager.default.fileExists(atPath: tsvURL.path))
    }

    // MARK: - ClaudeHookInstaller Tests

    @Test("ClaudeHookInstaller: clean install, idempotency, status, and uninstall")
    func testInstallerLifecycle() throws {
        let tempDir = createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let settingsURL = tempDir.appendingPathComponent("settings.json")
        let scriptURL = tempDir.appendingPathComponent("hooks/cc-event.sh")

        let installer = ClaudeHookInstaller(settingsURL: settingsURL, scriptURL: scriptURL)

        // 初始状态：未安装
        #expect(installer.checkStatus() == .notInstalled)

        // 1. 全新安装
        try installer.install(backup: true)
        #expect(installer.checkStatus() == .installed)
        #expect(FileManager.default.fileExists(atPath: scriptURL.path))

        // 验证脚本权限 0755
        let attrs = try FileManager.default.attributesOfItem(atPath: scriptURL.path)
        let perms = attrs[.posixPermissions] as? NSNumber
        #expect(perms?.intValue == 0o755)

        // 验证 settings.json 中的 7 个事件
        let data = try Data(contentsOf: settingsURL)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let hooks = json?["hooks"] as? [String: Any]
        #expect(hooks != nil)
        for event in ClaudeHookInstaller.targetEvents {
            let entries = hooks?[event] as? [[String: Any]]
            #expect(entries?.count == 1)
            let entry = entries?.first
            let hookList = entry?["hooks"] as? [[String: Any]]
            #expect(hookList?.count == 1)
            #expect(hookList?.first?["async"] as? Bool == true)

            if event == "UserPromptSubmit" || event == "Stop" {
                #expect(entry?["matcher"] == nil)
            } else {
                #expect(entry?["matcher"] as? String == "*")
            }
        }

        // 2. 重复安装：幂等性（不重复追加）
        try installer.install(backup: true)
        #expect(installer.checkStatus() == .installed)
        let data2 = try Data(contentsOf: settingsURL)
        let json2 = try JSONSerialization.jsonObject(with: data2) as? [String: Any]
        let hooks2 = json2?["hooks"] as? [String: Any]
        for event in ClaudeHookInstaller.targetEvents {
            let entries = hooks2?[event] as? [[String: Any]]
            #expect(entries?.count == 1)
        }

        // 3. 卸载：只删除自己的条目
        try installer.uninstall()
        #expect(installer.checkStatus() == .notInstalled)
        let data3 = try Data(contentsOf: settingsURL)
        let json3 = try JSONSerialization.jsonObject(with: data3) as? [String: Any]
        #expect(json3?["hooks"] == nil)

        // 4. 用户保留已有其他 hook 的情况
        let customSettings: [String: Any] = [
            "hooks": [
                "Stop": [
                    ["hooks": [["type": "command", "command": "echo custom stop"]]]
                ]
            ],
            "customKey": "preservedValue"
        ]
        let customData = try JSONSerialization.data(withJSONObject: customSettings)
        try customData.write(to: settingsURL)

        try installer.install(backup: true)
        #expect(installer.checkStatus() == .installed)

        // 卸载后自定义 key 和自定义 hook 应保留
        try installer.uninstall()
        let data4 = try Data(contentsOf: settingsURL)
        let json4 = try JSONSerialization.jsonObject(with: data4) as? [String: Any]
        #expect(json4?["customKey"] as? String == "preservedValue")
        let stopEntries = (json4?["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]]
        #expect(stopEntries?.count == 1)
        let cmd = ((stopEntries?.first?["hooks"] as? [[String: Any]])?.first)?["command"] as? String
        #expect(cmd == "echo custom stop")
    }

    @Test("ClaudeHookInstaller: status detection for needsRepair and invalidJSON rejection")
    func testInstallerNeedsRepairAndInvalidJSON() throws {
        let tempDir = createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let settingsURL = tempDir.appendingPathComponent("settings.json")
        let scriptURL = tempDir.appendingPathComponent("hooks/cc-event.sh")
        let installer = ClaudeHookInstaller(settingsURL: settingsURL, scriptURL: scriptURL)

        // 1. 无效 JSON 拒绝写入
        try "Not a valid json {{{".data(using: .utf8)!.write(to: settingsURL)
        #expect(installer.checkStatus() == .needsRepair)
        #expect(throws: ClaudeHookInstallerError.invalidJSON) {
            try installer.install()
        }

        // 2. 只有部分事件配置 -> needsRepair
        let partialSettings: [String: Any] = [
            "hooks": [
                "Stop": [installer.makeHookEntry(for: "Stop")]
            ]
        ]
        let partialData = try JSONSerialization.data(withJSONObject: partialSettings)
        try partialData.write(to: settingsURL)
        try installer.installScript()
        #expect(installer.checkStatus() == .needsRepair)

        // 3. 修复
        try installer.repair(backup: true)
        #expect(installer.checkStatus() == .installed)
    }

    // MARK: - ClaudeCodeAdapter Hook Override Table Tests

    @Test("ClaudeCodeAdapter: Hook override table mapping")
    func testAdapterHookOverrides() throws {
        let tempDir = createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sessionsDir = tempDir.appendingPathComponent("sessions")
        let projectsDir = tempDir.appendingPathComponent("projects")
        let eventsDir = tempDir.appendingPathComponent("events")
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: eventsDir, withIntermediateDirectories: true)

        let tsvURL = eventsDir.appendingPathComponent("claude.tsv")
        let hookReader = ClaudeHookEventReader(fileURL: tsvURL)

        let adapter = ClaudeCodeAdapter(
            sessionsDirectory: sessionsDir,
            projectsDirectory: projectsDir,
            eventsDirectory: eventsDir,
            hookReader: hookReader,
            isPidAlive: { _ in true },
            maxAgeSeconds: 3600
        )

        let now = Date()
        let pid = 12345
        let sessionId = "session-test"

        let sessionJSON = """
        {
            "pid": \(pid),
            "sessionId": "\(sessionId)",
            "cwd": "\(tempDir.path)",
            "status": "busy",
            "updatedAt": \(Int64(now.timeIntervalSince1970 * 1000)),
            "statusUpdatedAt": \(Int64(now.timeIntervalSince1970 * 1000))
        }
        """
        try sessionJSON.data(using: .utf8)!.write(to: sessionsDir.appendingPathComponent("\(pid).json"))

        // 1. 无 hook 时，状态根据 status 为 running
        var sessions = try adapter.scan()
        #expect(sessions.count == 1)
        #expect(sessions.first?.state == .running)

        // 2. PermissionRequest -> waitingForUser + detail
        let hookTime = Int(now.timeIntervalSince1970) + 1
        var line = "\(hookTime)\t{\"session_id\":\"\(sessionId)\",\"hook_event_name\":\"PermissionRequest\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit\"}}\n"
        try appendLine(line, to: tsvURL)

        sessions = try adapter.scan()
        #expect(sessions.first?.state == .waitingForUser)
        #expect(sessions.first?.waitingLabel == "等待授权")
        #expect(sessions.first?.detail == "git commit")
        #expect(sessions.first?.detailIsCommand == true)

        // 3. Notification (permission_prompt) -> waitingForUser
        line = "\(hookTime + 1)\t{\"session_id\":\"\(sessionId)\",\"hook_event_name\":\"Notification\",\"notification_type\":\"permission_prompt\",\"message\":\"Claude 请求授权访问文件\"}\n"
        try appendLine(line, to: tsvURL)

        sessions = try adapter.scan()
        #expect(sessions.first?.state == .waitingForUser)
        #expect(sessions.first?.waitingLabel == "等待授权")
        #expect(sessions.first?.detail == "Claude 请求授权访问文件")

        // 4. Notification (elicitation_dialog) -> waitingForUser ("在问你")
        line = "\(hookTime + 2)\t{\"session_id\":\"\(sessionId)\",\"hook_event_name\":\"Notification\",\"notification_type\":\"elicitation_dialog\",\"message\":\"请问你想采用哪个方案？\"}\n"
        try appendLine(line, to: tsvURL)

        sessions = try adapter.scan()
        #expect(sessions.first?.state == .waitingForUser)
        #expect(sessions.first?.waitingLabel == "在问你")
        #expect(sessions.first?.detail == "请问你想采用哪个方案？")

        // 5. Notification (idle_prompt) -> 不覆盖
        line = "\(hookTime + 3)\t{\"session_id\":\"\(sessionId)\",\"hook_event_name\":\"Notification\",\"notification_type\":\"idle_prompt\",\"message\":\"idle\"}\n"
        try appendLine(line, to: tsvURL)

        sessions = try adapter.scan()
        #expect(sessions.first?.state == .running)

        // 6. Stop -> idle
        line = "\(hookTime + 4)\t{\"session_id\":\"\(sessionId)\",\"hook_event_name\":\"Stop\"}\n"
        try appendLine(line, to: tsvURL)

        sessions = try adapter.scan()
        #expect(sessions.first?.state == .idle)
        #expect(sessions.first?.suppressCompletion == false)

        // 7. StopFailure -> idle + suppressCompletion
        line = "\(hookTime + 5)\t{\"session_id\":\"\(sessionId)\",\"hook_event_name\":\"StopFailure\"}\n"
        try appendLine(line, to: tsvURL)

        sessions = try adapter.scan()
        #expect(sessions.first?.state == .idle)
        #expect(sessions.first?.suppressCompletion == true)
    }
}
