import Foundation
import Testing
@testable import AgentMonitorCore

@Suite("Performance Optimization Regressions")
struct PerformanceOptimizationTests {

    @Test("FastDateParser 准确解析多种 ISO8601 与 SQLite 时间戳格式")
    func testFastDateParserFormats() throws {
        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let isoPlain = ISO8601DateFormatter()
        isoPlain.formatOptions = [.withInternetDateTime]

        // 1. 标准带毫秒 Z
        let s1 = "2026-11-11T02:34:56.789Z"
        let d1 = try #require(FastDateParser.parse(s1))
        let exp1 = try #require(isoFrac.date(from: s1))
        #expect(abs(d1.timeIntervalSince(exp1)) < 0.000_5)

        // 2. 带时区偏移 +08:00 与微秒
        let s2 = "2026-11-11T10:34:56.789123+08:00"
        let d2 = try #require(FastDateParser.parse(s2))
        #expect(abs(d2.timeIntervalSince(exp1)) < 0.001)

        // 3. Antigravity SQLite 空格分隔微秒带偏移格式
        let s3 = "2026-11-11 02:34:56.789123+00:00"
        let d3 = try #require(FastDateParser.parse(s3))
        #expect(abs(d3.timeIntervalSince(exp1)) < 0.001)

        // 4. 无小数秒与负时区偏移
        let s4 = "2026-11-10T21:34:56-05:00"
        let d4 = try #require(FastDateParser.parse(s4))
        let exp4 = try #require(isoPlain.date(from: s4))
        #expect(abs(d4.timeIntervalSince(exp4)) < 0.000_5)

        // 5. 无时区后缀默认按 UTC 解析 + 闰年 2 月 29 日验证
        let s5 = "2024-02-29 23:59:59"
        let d5 = try #require(FastDateParser.parse(s5))
        let exp5 = try #require(isoPlain.date(from: "2024-02-29T23:59:59Z"))
        #expect(abs(d5.timeIntervalSince(exp5)) < 0.000_5)

        // 6. C 字符串指针零拷贝入口（模拟 sqlite3_column_text 返回的 UnsafePointer<UInt8>）
        let d6 = s3.utf8CString.withUnsafeBytes { rawBuf -> Date? in
            guard let ptr = rawBuf.bindMemory(to: UInt8.self).baseAddress else { return nil }
            return FastDateParser.parse(cString: ptr)
        }
        #expect(d6 != nil)
        #expect(abs((d6?.timeIntervalSince(d3) ?? 1.0)) < 0.000_001)

        // 7. 非法输入安全返回 nil（如平年 2 月 29 日或乱码）
        #expect(FastDateParser.parse("2025-02-29T12:00:00Z") == nil)
        #expect(FastDateParser.parse("not-a-timestamp") == nil)
        #expect(FastDateParser.parse("") == nil)
    }

    /// 用于验证定向刷新的计数型适配器桩。
    private final class CountingAdapter: AgentAdapter, @unchecked Sendable {
        let kind: AgentKind
        let watchPaths: [URL]
        private let lock = NSLock()
        private(set) var scanCount: Int = 0
        var stubbedSessions: [AgentSession]

        init(kind: AgentKind, watchPaths: [URL], stubbedSessions: [AgentSession]) {
            self.kind = kind
            self.watchPaths = watchPaths
            self.stubbedSessions = stubbedSessions
        }

        func scan() throws -> [AgentSession] {
            lock.lock()
            defer { lock.unlock() }
            scanCount += 1
            return stubbedSessions
        }
    }

    @Test("SessionStore 按变更路径定向刷新目标 Adapter，并支持 SQLite WAL 伴生文件匹配")
    func testSessionStoreTargetedPathRefresh() throws {
        let fm = FileManager.default
        let baseDir = fm.temporaryDirectory.appendingPathComponent("perf-store-\(UUID().uuidString)")
        let claudeDir = baseDir.appendingPathComponent("claude")
        let codexDir = baseDir.appendingPathComponent("codex")
        let agDbFile = baseDir.appendingPathComponent("antigravity/conversation_summaries.db")
        try fm.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: codexDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: agDbFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: baseDir) }

        let claudeAdapter = CountingAdapter(
            kind: .claudeCode,
            watchPaths: [claudeDir],
            stubbedSessions: [AgentSession(id: "claudeCode:1", kind: .claudeCode, title: "Claude 1", state: .running)]
        )
        let codexAdapter = CountingAdapter(
            kind: .codex,
            watchPaths: [codexDir],
            stubbedSessions: [AgentSession(id: "codex:1", kind: .codex, title: "Codex 1", state: .idle)]
        )
        let agAdapter = CountingAdapter(
            kind: .antigravity,
            watchPaths: [agDbFile],
            stubbedSessions: [AgentSession(id: "antigravity:1", kind: .antigravity, title: "AG 1", state: .waitingForUser)]
        )

        let store = SessionStore(adapters: [claudeAdapter, codexAdapter, agAdapter])
        nonisolated(unsafe) var latestSessions: [AgentSession] = []
        store.onSessionsUpdated = { latestSessions = $0 }

        // 1. 首次全量刷新：三个适配器各扫描 1 次
        _ = store.refresh()
        #expect(claudeAdapter.scanCount == 1)
        #expect(codexAdapter.scanCount == 1)
        #expect(agAdapter.scanCount == 1)
        #expect(latestSessions.count == 3)

        // 2. 仅 Codex 子目录文件变更：只有 codexAdapter 重扫，其余两个完全复用缓存
        codexAdapter.stubbedSessions = [AgentSession(id: "codex:1", kind: .codex, title: "Codex Updated", state: .running)]
        let codexRolloutPath = codexDir.appendingPathComponent("2026/11/11/rollout-1.jsonl").path
        _ = store.refresh(changedPaths: [codexRolloutPath])
        #expect(claudeAdapter.scanCount == 1)
        #expect(codexAdapter.scanCount == 2)
        #expect(agAdapter.scanCount == 1)
        #expect(latestSessions.count == 3)
        #expect(latestSessions.first(where: { $0.id == "codex:1" })?.title == "Codex Updated")

        // 3. SQLite WAL 伴生文件变更（模拟 /private/var 与 /var 标准化）：精准触发 antigravity 重扫
        let walPath = agDbFile.path.replacingOccurrences(of: "^/var/", with: "/private/var/", options: .regularExpression) + "-wal"
        _ = store.refresh(changedPaths: [walPath])
        #expect(claudeAdapter.scanCount == 1)
        #expect(codexAdapter.scanCount == 2)
        #expect(agAdapter.scanCount == 2)

        // 4. 已禁用的适配器发生文件变更：直接短路，零扫描开销
        store.disabledKinds = [.claudeCode]
        _ = store.refresh()
        let prevClaudeCount = claudeAdapter.scanCount
        let prevCodexCount = codexAdapter.scanCount
        let prevAgCount = agAdapter.scanCount
        _ = store.refresh(changedPaths: [claudeDir.appendingPathComponent("sessions/123.json").path])
        #expect(claudeAdapter.scanCount == prevClaudeCount)
        #expect(codexAdapter.scanCount == prevCodexCount)
        #expect(agAdapter.scanCount == prevAgCount)
    }

    @Test("ClaudeHookEventReader 在运行期超过阈值时原地轮转并保留活跃会话状态")
    func testClaudeHookRuntimeRotation() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("hook-rot-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let eventsFile = dir.appendingPathComponent("claude.tsv")
        let rotatedFile = dir.appendingPathComponent("claude.tsv.1")

        // 阈值设为 300 字节：首条约 220 字节不触发轮转，追加第二条后超过 300 字节触发运行期轮转
        let reader = ClaudeHookEventReader(fileURL: eventsFile, maxFileSizeBeforeRotation: 300)

        let ts1 = Int(Date().timeIntervalSince1970)
        let padding = String(repeating: "x", count: 120)
        let line1 = "\(ts1)\t{\"session_id\":\"sess-alpha\",\"hook_event_name\":\"PermissionRequest\",\"tool_name\":\"Bash\",\"message\":\"\(padding)\"}\n"
        try Data(line1.utf8).write(to: eventsFile)
        let states1 = reader.poll()
        #expect(states1["sess-alpha"]?.event == "PermissionRequest")
        #expect(fm.fileExists(atPath: eventsFile.path) == true)

        // 第二次追加使总大小超过 300 字节，poll 读完末尾后应自动轮转为 .tsv.1
        let line2 = "\(ts1 + 1)\t{\"session_id\":\"sess-beta\",\"hook_event_name\":\"Stop\",\"message\":\"\(padding)\"}\n"
        let handle = try FileHandle(forWritingTo: eventsFile)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line2.utf8))
        try handle.close()

        let states2 = reader.poll()
        #expect(fm.fileExists(atPath: rotatedFile.path) == true)
        #expect(fm.fileExists(atPath: eventsFile.path) == false)
        // 轮转后内存中的两个活跃状态均不得丢失
        #expect(states2["sess-alpha"]?.event == "PermissionRequest")
        #expect(states2["sess-beta"]?.event == "Stop")

        // 轮转后新产生的日志文件从偏移 0 创建写入，应能无缝继续读取
        let line3 = "\(ts1 + 2)\t{\"session_id\":\"sess-alpha\",\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"Bash\"}\n"
        try Data(line3.utf8).write(to: eventsFile)
        let states3 = reader.poll()
        #expect(states3["sess-alpha"]?.event == "PostToolUse")
        #expect(states3["sess-beta"]?.event == "Stop")
    }

    @Test("CodexAdapter 缓存命中与增量追加后立即感知状态更新")
    func testCodexAdapterCacheInvalidationOnAppend() throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("codex-cache-\(UUID().uuidString)")
        let calendar = Calendar(identifier: .gregorian)
        let now = Date()
        let dayDir = tempDir
            .appendingPathComponent("sessions")
            .appendingPathComponent(String(format: "%04d", calendar.component(.year, from: now)))
            .appendingPathComponent(String(format: "%02d", calendar.component(.month, from: now)))
            .appendingPathComponent(String(format: "%02d", calendar.component(.day, from: now)))
        try fm.createDirectory(at: dayDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let indexURL = tempDir.appendingPathComponent("session_index.jsonl")
        let sessionID = "019c0000-1111-7222-8333-444455556666"
        let iso = ISO8601DateFormatter()
        let tsStart = iso.string(from: now.addingTimeInterval(-20))
        let tsDone = iso.string(from: now.addingTimeInterval(-5))

        try Data("{\"id\":\"\(sessionID)\",\"thread_name\":\"Initial Title\",\"updated_at\":\"\(tsStart)\"}\n".utf8)
            .write(to: indexURL)

        let rolloutURL = dayDir.appendingPathComponent("rollout-2026-\(sessionID).jsonl")
        let initialRollout = """
        {"timestamp":"\(tsStart)","type":"session_meta","payload":{"id":"\(sessionID)","cwd":"/tmp/demo","originator":"codex_cli_rs"}}
        {"timestamp":"\(tsStart)","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1"}}
        {"timestamp":"\(tsStart)","type":"event_msg","payload":{"type":"agent_reasoning","text":"Analyzing"}}
        """ + "\n"
        try Data(initialRollout.utf8).write(to: rolloutURL)

        let adapter = CodexAdapter(sessionsDirectory: tempDir.appendingPathComponent("sessions"), sessionIndexURL: indexURL)

        // 首次扫描（冷扫建立缓存）与二次扫描（命中缓存）均应为 running
        let first = try adapter.scan()
        let second = try adapter.scan()
        #expect(first.count == 1)
        #expect(first.first?.state == SessionState.running)
        #expect(second.first?.state == SessionState.running)
        #expect(second.first?.title == "Initial Title")

        // 追加 assistant 回复与 task_complete 事件并增量追加索引标题，缓存应因 FileStamp 变化立即失效并解析出最新状态
        let handle = try FileHandle(forWritingTo: rolloutURL)
        try handle.seekToEnd()
        let assistantLine = "{\"timestamp\":\"\(tsDone)\",\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"All done\"}]}}\n"
        let completionLine = "{\"timestamp\":\"\(tsDone)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\",\"turn_id\":\"turn-1\"}}\n"
        try handle.write(contentsOf: Data((assistantLine + completionLine).utf8))
        try handle.close()

        let idxHandle = try FileHandle(forWritingTo: indexURL)
        try idxHandle.seekToEnd()
        try idxHandle.write(contentsOf: Data("{\"id\":\"\(sessionID)\",\"thread_name\":\"Renamed Title\",\"updated_at\":\"\(tsDone)\"}\n".utf8))
        try idxHandle.close()

        let third = try adapter.scan()
        #expect(third.count == 1)
        #expect(third.first?.state == SessionState.idle)
        #expect(third.first?.title == "Renamed Title")
        #expect(third.first?.detail == "All done")
    }

    @Test("PaseoAdapter 本地文件扫描支持嵌套工作区子目录并命中 FileStamp 缓存")
    func testPaseoNestedWorkspaceSubdirectoryCache() throws {
        let fm = FileManager.default
        let tempHome = fm.temporaryDirectory.appendingPathComponent("paseo-nested-\(UUID().uuidString)")
        let wsDir = tempHome.appendingPathComponent(".paseo/agents/Users-cyan-code-Demo")
        try fm.createDirectory(at: wsDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempHome) }

        try Data("srv-local-1\n".utf8).write(to: tempHome.appendingPathComponent(".paseo/server-id"))
        let agentID = "11111111-2222-3333-4444-555555555555"
        let agentJSON = """
        {
          "id": "\(agentID)",
          "title": "Nested Workspace Agent",
          "cwd": "/Users/cyan/code/Demo",
          "provider": "claude",
          "status": "idle",
          "updatedAt": "2026-11-11T02:00:00.000Z"
        }
        """
        let agentFile = wsDir.appendingPathComponent("\(agentID).json")
        try Data(agentJSON.utf8).write(to: agentFile)

        let adapter = PaseoAdapter(home: tempHome, application: URL(fileURLWithPath: "/nonexistent/Paseo.app"))
        let first = try adapter.scan()
        let second = try adapter.scan()
        #expect(first.count == 1)
        #expect(second.count == 1)
        #expect(second.first?.title == "Nested Workspace Agent")
    }
}
