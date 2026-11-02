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
        #expect(installer.checkStatus() == .invalidJSON)
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

    // MARK: - P0-4 & P1 & P2 补齐测试

    @Test("ClaudeHookEventReader: 单行 UTF-8 解码失败只跳过该行，不丢弃整块有效行")
    func testReaderCorruptedLineSkipping() throws {
        let tempDir = createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let tsvURL = tempDir.appendingPathComponent("claude.tsv")
        let reader = ClaudeHookEventReader(fileURL: tsvURL)

        // 第一行正常
        let line1 = "1730530000\t{\"session_id\":\"s1\",\"hook_event_name\":\"SessionStart\"}\n"
        var data = line1.data(using: .utf8)!

        // 第二行是非法 UTF-8 字节（如 0xFF, 0xFE）
        data.append(contentsOf: [0xFF, 0xFE, 0xFD, 0x0A])

        // 第三行正常
        let line3 = "1730530020\t{\"session_id\":\"s3\",\"hook_event_name\":\"Stop\"}\n"
        data.append(line3.data(using: .utf8)!)

        try data.write(to: tsvURL)

        let states = reader.poll()
        #expect(states.count == 2)
        #expect(states["s1"]?.event == "SessionStart")
        #expect(states["s3"]?.event == "Stop")
    }

    @Test("ClaudeHookInstaller: 符号链接指向的 settings.json 能安装，链接本身保持不变")
    func testSymlinkSettingsInstall() throws {
        let tempDir = createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let realSettingsURL = tempDir.appendingPathComponent("real_settings.json")
        let linkSettingsURL = tempDir.appendingPathComponent("link_settings.json")
        let scriptURL = tempDir.appendingPathComponent("hooks/cc-event.sh")

        // 真实文件初始为空字典
        try "{}".data(using: .utf8)!.write(to: realSettingsURL)
        // 创建软链接
        try FileManager.default.createSymbolicLink(at: linkSettingsURL, withDestinationURL: realSettingsURL)

        let installer = ClaudeHookInstaller(settingsURL: linkSettingsURL, scriptURL: scriptURL)
        try installer.install(backup: true)

        // 验证软链接依然是软链接
        let attrs = try FileManager.default.attributesOfItem(atPath: linkSettingsURL.path)
        #expect(attrs[.type] as? FileAttributeType == .typeSymbolicLink)

        // 真实文件被正确写入了 hooks
        let realData = try Data(contentsOf: realSettingsURL)
        let json = try JSONSerialization.jsonObject(with: realData) as? [String: Any]
        let hooks = json?["hooks"] as? [String: Any]
        #expect(hooks?.count == ClaudeHookInstaller.targetEvents.count)

        // 备份文件生成在真实文件同目录
        let backupURL = tempDir.appendingPathComponent("settings.json.agentmonitor-backup")
        #expect(FileManager.default.fileExists(atPath: backupURL.path))
    }

    @Test("ClaudeHookInstaller: 修复时的备份等于修复前的文件内容")
    func testRepairBackupMatchesOriginal() throws {
        let tempDir = createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let settingsURL = tempDir.appendingPathComponent("settings.json")
        let scriptURL = tempDir.appendingPathComponent("hooks/cc-event.sh")

        let originalContent = "{\n  \"custom_setting\": \"preserve_me\"\n}"
        let originalBytes = originalContent.data(using: .utf8)!
        try originalBytes.write(to: settingsURL)

        let installer = ClaudeHookInstaller(settingsURL: settingsURL, scriptURL: scriptURL)
        try installer.repair(backup: true)

        let backupURL = tempDir.appendingPathComponent("settings.json.agentmonitor-backup")
        #expect(FileManager.default.fileExists(atPath: backupURL.path))
        let backupBytes = try Data(contentsOf: backupURL)
        #expect(backupBytes == originalBytes)
    }

    @Test("ClaudeHookInstaller: 结构错误（如 hooks 为含非对象元素的数组或 hooks[event] 非数组）时拒绝写入，文件不变")
    func testInvalidHooksStructureRejection() throws {
        let tempDir = createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let settingsURL = tempDir.appendingPathComponent("settings.json")
        let scriptURL = tempDir.appendingPathComponent("hooks/cc-event.sh")
        let installer = ClaudeHookInstaller(settingsURL: settingsURL, scriptURL: scriptURL)

        // 情况 1: hooks 是含非对象元素的数组
        let invalidHooksContent = "{\n  \"hooks\": [\"not_an_object\", 123]\n}"
        let invalidBytes = invalidHooksContent.data(using: .utf8)!
        try invalidBytes.write(to: settingsURL)

        #expect(throws: ClaudeHookInstallerError.unrecognizedHooksStructure) {
            try installer.install()
        }
        let currentBytes1 = try Data(contentsOf: settingsURL)
        #expect(currentBytes1 == invalidBytes)

        // 情况 2: hooks[event] 不是数组
        let invalidEventContent = "{\n  \"hooks\": {\n    \"Stop\": \"invalid_string\"\n  }\n}"
        let invalidEventBytes = invalidEventContent.data(using: .utf8)!
        try invalidEventBytes.write(to: settingsURL)

        #expect(throws: ClaudeHookInstallerError.unrecognizedHooksStructure) {
            try installer.install()
        }
        let currentBytes2 = try Data(contentsOf: settingsURL)
        #expect(currentBytes2 == invalidEventBytes)
    }

    @Test("ClaudeHookInstaller: hooks[event] 中的非字典元素原样保留，只追加我们的 hook")
    func testPreserveNonDictionaryEntries() throws {
        let tempDir = createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let settingsURL = tempDir.appendingPathComponent("settings.json")
        let scriptURL = tempDir.appendingPathComponent("hooks/cc-event.sh")
        let installer = ClaudeHookInstaller(settingsURL: settingsURL, scriptURL: scriptURL)

        let mixedContent = """
        {
          "hooks": {
            "Stop": [
              "raw_string_entry",
              42,
              { "hooks": [{ "command": "echo custom" }] }
            ]
          }
        }
        """
        try mixedContent.data(using: .utf8)!.write(to: settingsURL)

        try installer.install(backup: false)

        let data = try Data(contentsOf: settingsURL)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let stopList = (json?["hooks"] as? [String: Any])?["Stop"] as? [Any]
        #expect(stopList?.count == 4)
        #expect(stopList?[0] as? String == "raw_string_entry")
        #expect(stopList?[1] as? Int == 42)
    }

    @Test("ClaudeHookInstaller: 卸载没有我们条目的文件时，文件字节不变")
    func testUninstallWithoutOurEntriesDoesNotModifyFile() throws {
        let tempDir = createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let settingsURL = tempDir.appendingPathComponent("settings.json")
        let scriptURL = tempDir.appendingPathComponent("hooks/cc-event.sh")
        let installer = ClaudeHookInstaller(settingsURL: settingsURL, scriptURL: scriptURL)

        let originalContent = "{\n  \"hooks\": {\n    \"Stop\": [\n      {\"hooks\": [{\"command\": \"echo custom\"}]}\n    ]\n  }\n}"
        let originalBytes = originalContent.data(using: .utf8)!
        try originalBytes.write(to: settingsURL)

        let mtimeBefore = try FileManager.default.attributesOfItem(atPath: settingsURL.path)[.modificationDate] as? Date

        try installer.uninstall()

        let currentBytes = try Data(contentsOf: settingsURL)
        #expect(currentBytes == originalBytes)
        let mtimeAfter = try FileManager.default.attributesOfItem(atPath: settingsURL.path)[.modificationDate] as? Date
        #expect(mtimeBefore == mtimeAfter)
    }

    @Test("ClaudeCodeAdapter: hook 早于 statusUpdatedAt - 1s 时不覆盖状态")
    func testHookEarlierThanStatusUpdatedAtDoesNotOverride() throws {
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
        let pid = 12346
        let sessionId = "session-time-test"

        let statusUpdatedTimestamp = Int64(now.timeIntervalSince1970 * 1000)
        let sessionJSON = """
        {
            "pid": \(pid),
            "sessionId": "\(sessionId)",
            "status": "busy",
            "updatedAt": \(statusUpdatedTimestamp),
            "statusUpdatedAt": \(statusUpdatedTimestamp)
        }
        """
        try sessionJSON.data(using: .utf8)!.write(to: sessionsDir.appendingPathComponent("\(pid).json"))

        // hook 时间早于 statusUpdatedAt - 1s
        let hookTime = Int(now.timeIntervalSince1970) - 2
        let line = "\(hookTime)\t{\"session_id\":\"\(sessionId)\",\"hook_event_name\":\"PermissionRequest\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rm -rf /\"}}\n"
        try appendLine(line, to: tsvURL)

        let sessions = try adapter.scan()
        #expect(sessions.count == 1)
        #expect(sessions.first?.state == .running)
    }

    @Test("ClaudeCodeAdapter: UserPromptSubmit、SessionStart、SessionEnd 三种事件不覆盖状态")
    func testNonOverridingHookEvents() throws {
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
        let pid = 12347
        let sessionId = "session-no-override-test"

        let sessionJSON = """
        {
            "pid": \(pid),
            "sessionId": "\(sessionId)",
            "status": "busy",
            "updatedAt": \(Int64(now.timeIntervalSince1970 * 1000)),
            "statusUpdatedAt": \(Int64(now.timeIntervalSince1970 * 1000))
        }
        """
        try sessionJSON.data(using: .utf8)!.write(to: sessionsDir.appendingPathComponent("\(pid).json"))

        let hookTime = Int(now.timeIntervalSince1970) + 1
        for event in ["UserPromptSubmit", "SessionStart", "SessionEnd"] {
            let line = "\(hookTime)\t{\"session_id\":\"\(sessionId)\",\"hook_event_name\":\"\(event)\"}\n"
            try appendLine(line, to: tsvURL)

            let sessions = try adapter.scan()
            #expect(sessions.count == 1)
            #expect(sessions.first?.state == .running)
        }
    }

    @Test("ClaudeCodeAdapter: adapter 优先使用 hook 里的 transcript_path")
    func testAdapterPrefersHookTranscriptPath() throws {
        let tempDir = createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sessionsDir = tempDir.appendingPathComponent("sessions")
        let projectsDir = tempDir.appendingPathComponent("projects")
        let eventsDir = tempDir.appendingPathComponent("events")
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: eventsDir, withIntermediateDirectories: true)

        let hookTranscriptURL = tempDir.appendingPathComponent("hook_transcript.jsonl")
        let hookTranscriptContent = """
        {"type":"custom-title","customTitle":"TitleFromHookTranscript"}
        """
        try hookTranscriptContent.data(using: .utf8)!.write(to: hookTranscriptURL)

        let defaultProjectDir = projectsDir.appendingPathComponent("default-project")
        try FileManager.default.createDirectory(at: defaultProjectDir, withIntermediateDirectories: true)
        let defaultTranscriptURL = defaultProjectDir.appendingPathComponent("session-pref.jsonl")
        let defaultTranscriptContent = """
        {"type":"custom-title","customTitle":"TitleFromDefaultProject"}
        """
        try defaultTranscriptContent.data(using: .utf8)!.write(to: defaultTranscriptURL)

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
        let pid = 12348
        let sessionId = "session-pref"

        let sessionJSON = """
        {
            "pid": \(pid),
            "sessionId": "\(sessionId)",
            "cwd": "\(defaultProjectDir.path)",
            "status": "busy",
            "updatedAt": \(Int64(now.timeIntervalSince1970 * 1000))
        }
        """
        try sessionJSON.data(using: .utf8)!.write(to: sessionsDir.appendingPathComponent("\(pid).json"))

        let hookTime = Int(now.timeIntervalSince1970) + 1
        let line = "\(hookTime)\t{\"session_id\":\"\(sessionId)\",\"hook_event_name\":\"SessionStart\",\"transcript_path\":\"\(hookTranscriptURL.path)\"}\n"
        try appendLine(line, to: tsvURL)

        let sessions = try adapter.scan()
        #expect(sessions.count == 1)
        #expect(sessions.first?.transcriptPath == hookTranscriptURL.path)
        #expect(sessions.first?.title == "TitleFromHookTranscript")
    }
}
