import Foundation
import Testing
@testable import AgentMonitorCore

@Suite("UsageTracker and UsageFormatter Tests")
struct UsageTests {
    private func createTempDir() -> URL {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("am-usage-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        return temp
    }

    // MARK: - UsageFormatter Table Tests

    @Test("UsageFormatter: short and long table specification")
    func testFormatterTable() {
        // 26 -> "26", "26"
        #expect(UsageFormatter.short(tokens: 26) == "26")
        #expect(UsageFormatter.long(tokens: 26) == "26")

        // 5093 -> "5.1k", "5.1k"
        #expect(UsageFormatter.short(tokens: 5093) == "5.1k")
        #expect(UsageFormatter.long(tokens: 5093) == "5.1k")

        // 62846 -> "62.8k", "62.8k"
        #expect(UsageFormatter.short(tokens: 62846) == "62.8k")
        #expect(UsageFormatter.long(tokens: 62846) == "62.8k")

        // 10000 -> "10k", "10k" (去掉 .0)
        #expect(UsageFormatter.short(tokens: 10000) == "10k")
        #expect(UsageFormatter.long(tokens: 10000) == "10k")

        // 459554 -> "460k", "459.6k"
        #expect(UsageFormatter.short(tokens: 459554) == "460k")
        #expect(UsageFormatter.long(tokens: 459554) == "459.6k")

        // 5645841 -> "5.65M", "5.65M"
        #expect(UsageFormatter.short(tokens: 5645841) == "5.65M")
        #expect(UsageFormatter.long(tokens: 5645841) == "5.65M")

        // 1020000 -> "1.02M", "1.02M"
        #expect(UsageFormatter.short(tokens: 1020000) == "1.02M")
        #expect(UsageFormatter.long(tokens: 1020000) == "1.02M")

        // 2000000 -> "2M", "2M"
        #expect(UsageFormatter.short(tokens: 2000000) == "2M")
        #expect(UsageFormatter.long(tokens: 2000000) == "2M")

        // 999_600: short 四舍五入后满 1000k 进位为 1M，long 进位为 999.6k
        #expect(UsageFormatter.short(tokens: 999_600) == "1M")
        #expect(UsageFormatter.long(tokens: 999_600) == "999.6k")

        // 999_400: short 为 999k
        #expect(UsageFormatter.short(tokens: 999_400) == "999k")

        // 999_960: long 四舍五入后满 1000k 进位为 1M
        #expect(UsageFormatter.short(tokens: 999_960) == "1M")
        #expect(UsageFormatter.long(tokens: 999_960) == "1M")

        // 999_940: long 为 999.9k
        #expect(UsageFormatter.long(tokens: 999_940) == "999.9k")
    }

    @Test("UsageFormatter: usageLevel threshold and rounding logic")
    func testFormatterUsageLevel() {
        let now = Date()

        // 79.4% (794 / 1000) -> 79% -> normal
        let normal = SessionUsage(contextTokens: 794, contextWindow: 1000, updatedAt: now)
        #expect(UsageFormatter.usageLevel(usage: normal) == .normal)

        // 79.6% (796 / 1000) -> 80% -> warning
        let warning = SessionUsage(contextTokens: 796, contextWindow: 1000, updatedAt: now)
        #expect(UsageFormatter.usageLevel(usage: warning) == .warning)

        // 94.4% (944 / 1000) -> 94% -> warning
        let warningHigh = SessionUsage(contextTokens: 944, contextWindow: 1000, updatedAt: now)
        #expect(UsageFormatter.usageLevel(usage: warningHigh) == .warning)

        // 94.6% (946 / 1000) -> 95% -> critical
        let critical = SessionUsage(contextTokens: 946, contextWindow: 1000, updatedAt: now)
        #expect(UsageFormatter.usageLevel(usage: critical) == .critical)

        // 无 contextWindow 时按绝对数值
        let tokenNormal = SessionUsage(contextTokens: 799_999, updatedAt: now)
        #expect(UsageFormatter.usageLevel(usage: tokenNormal) == .normal)
        let tokenWarning = SessionUsage(contextTokens: 800_000, updatedAt: now)
        #expect(UsageFormatter.usageLevel(usage: tokenWarning) == .warning)
        let tokenCritical = SessionUsage(contextTokens: 1_000_000, updatedAt: now)
        #expect(UsageFormatter.usageLevel(usage: tokenCritical) == .critical)
    }

    @Test("UsageFormatter: badgeText and accessibilityLabel")
    func testBadgeAndAccessibility() {
        let now = Date()

        // 1. Both contextTokens and contextWindow -> percentage
        let usage1 = SessionUsage(
            contextTokens: 98_200,
            contextWindow: 258_400,
            updatedAt: now
        )
        let badge1 = UsageFormatter.badgeText(usage: usage1)
        #expect(badge1?.text == "38%")
        #expect(badge1?.isPercent == true)
        #expect(UsageFormatter.accessibilityLabel(usage: usage1) == "上下文 38%")

        // 2. Only contextTokens -> short abbreviated tokens
        let usage2 = SessionUsage(
            contextTokens: 459_554,
            updatedAt: now
        )
        let badge2 = UsageFormatter.badgeText(usage: usage2)
        #expect(badge2?.text == "460k")
        #expect(badge2?.isPercent == false)
        #expect(UsageFormatter.accessibilityLabel(usage: usage2) == "上下文 460k")

        // 3. Only steps -> "N 步"
        let usage3 = SessionUsage(
            steps: 86,
            updatedAt: now
        )
        let badge3 = UsageFormatter.badgeText(usage: usage3)
        #expect(badge3?.text == "86 步")
        #expect(badge3?.isPercent == false)
        #expect(UsageFormatter.accessibilityLabel(usage: usage3) == "86 步")

        // 4. Neither -> nil
        let usage4 = SessionUsage(updatedAt: now)
        #expect(UsageFormatter.badgeText(usage: usage4) == nil)
        #expect(UsageFormatter.accessibilityLabel(usage: usage4) == nil)
    }

    // MARK: - Claude Usage Tests

    @Test("Claude: message.id deduplication, sidechain inclusion in total, non-sidechain context, incremental read")
    func testClaudeUsage() throws {
        let tempDir = createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let transcriptURL = tempDir.appendingPathComponent("session.jsonl")
        let tracker = UsageTracker()

        // 1. 同一 message.id 重复 3 行，累计只算一次
        let block1 = """
        {"type":"assistant","isSidechain":false,"message":{"model":"claude-opus-5-5","id":"msg_1","usage":{"input_tokens":10,"cache_creation_input_tokens":20,"cache_read_input_tokens":30,"output_tokens":5}}}
        {"type":"assistant","isSidechain":false,"message":{"model":"claude-opus-5-5","id":"msg_1","usage":{"input_tokens":10,"cache_creation_input_tokens":20,"cache_read_input_tokens":30,"output_tokens":5}}}
        {"type":"assistant","isSidechain":false,"message":{"model":"claude-opus-5-5","id":"msg_1","usage":{"input_tokens":10,"cache_creation_input_tokens":20,"cache_read_input_tokens":30,"output_tokens":8}}}
        """ + "\n"
        try block1.data(using: .utf8)!.write(to: transcriptURL)

        var usage = tracker.claudeUsage(transcript: transcriptURL)
        #expect(usage != nil)
        #expect(usage?.requestCount == 1)
        #expect(usage?.inputTokens == 10)
        #expect(usage?.cacheWriteTokens == 20)
        #expect(usage?.cachedInputTokens == 30)
        #expect(usage?.outputTokens == 8) // 取最后一次更新的值
        #expect(usage?.contextTokens == 60) // 10 + 20 + 30
        #expect(usage?.model == "claude-opus-5-5")

        // 2. isSidechain == true 消息照常计入累计与 requestCount，但上下文 contextTokens 与模型名不受 sidechain 影响 (P1-20)
        let sidechainLine = """
        {"type":"assistant","isSidechain":true,"message":{"model":"claude-haiku-side","id":"msg_side","usage":{"input_tokens":100,"cache_creation_input_tokens":200,"cache_read_input_tokens":300,"output_tokens":400}}}
        """ + "\n"
        let handle = try FileHandle(forWritingTo: transcriptURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: sidechainLine.data(using: .utf8)!)
        try handle.close()

        usage = tracker.claudeUsage(transcript: transcriptURL)
        #expect(usage?.requestCount == 2)
        #expect(usage?.inputTokens == 110) // 10 + 100
        #expect(usage?.cacheWriteTokens == 220) // 20 + 200
        #expect(usage?.cachedInputTokens == 330) // 30 + 300
        #expect(usage?.outputTokens == 408) // 8 + 400
        #expect(usage?.contextTokens == 60) // 保持最后一条非 sidechain 的 60
        #expect(usage?.model == "claude-opus-5-5") // 模型名不被 sidechain 覆盖

        // 3. 追加新非 sidechain 消息（增量读取）
        let block2 = """
        {"type":"assistant","isSidechain":false,"message":{"model":"claude-opus-5-5","id":"msg_2","usage":{"input_tokens":15,"cache_creation_input_tokens":0,"cache_read_input_tokens":50,"output_tokens":20}}}
        """ + "\n"
        let handle2 = try FileHandle(forWritingTo: transcriptURL)
        try handle2.seekToEnd()
        try handle2.write(contentsOf: block2.data(using: .utf8)!)
        try handle2.close()

        usage = tracker.claudeUsage(transcript: transcriptURL)
        #expect(usage?.requestCount == 3)
        #expect(usage?.inputTokens == 125) // 10 + 100 + 15
        #expect(usage?.cacheWriteTokens == 220) // 20 + 200 + 0
        #expect(usage?.cachedInputTokens == 380) // 30 + 300 + 50
        #expect(usage?.outputTokens == 428) // 8 + 400 + 20
        #expect(usage?.contextTokens == 65) // 15 + 0 + 50

        // 4. 文件截断后重算
        let truncatedBlock = """
        {"type":"assistant","isSidechain":false,"message":{"model":"claude-sonnet-4","id":"msg_new","usage":{"input_tokens":5,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":2}}}
        """ + "\n"
        try truncatedBlock.data(using: .utf8)!.write(to: transcriptURL)

        usage = tracker.claudeUsage(transcript: transcriptURL)
        #expect(usage?.requestCount == 1)
        #expect(usage?.inputTokens == 5)
        #expect(usage?.cacheWriteTokens == 0)
        #expect(usage?.cachedInputTokens == 0)
        #expect(usage?.outputTokens == 2)
        #expect(usage?.contextTokens == 5)
        #expect(usage?.model == "claude-sonnet-4")
    }

    @Test("FileUtils and UsageTracker: do not split on Unicode line separators (P2-4)")
    func testUnicodeSeparatorHandling() throws {
        let tempDir = createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let testFile = tempDir.appendingPathComponent("unicode-test.jsonl")
        // \u{2028} 是 Unicode 行分隔符，在 CharacterSet.newlines 中会被切开，但在 0x0A 字节切分下应保持在同一行
        let lineWithUnicodeLS = "{\"type\":\"test\",\"content\":\"hello\u{2028}world\"}\n"
        try lineWithUnicodeLS.data(using: .utf8)!.write(to: testFile)

        let lines = FileUtils.readTailLines(fileURL: testFile, maxBytes: 4096)
        #expect(lines?.first?.contains("hello\u{2028}world") == true)
        #expect(lines?.filter { !$0.isEmpty }.count == 1)
    }

    // MARK: - Codex Usage Tests

    @Test("Codex: latest token_count, net inputTokens calculation, and unchanged cache hit")
    func testCodexUsage() throws {
        let tempDir = createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let rolloutURL = tempDir.appendingPathComponent("rollout.jsonl")
        let tracker = UsageTracker()

        let rolloutContent = """
        {"timestamp":"2026-11-02T07:48:10.586Z","type":"event_msg","payload":{"type":"thread_settings_applied","thread_settings":{"model":"gpt-6-astra"}}}
        {"timestamp":"2026-11-02T07:48:21.286Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":25000,"cached_input_tokens":14000,"output_tokens":150,"reasoning_output_tokens":40},"last_token_usage":{"input_tokens":25000},"model_context_window":258400}}}
        {"timestamp":"2026-11-02T07:48:25.000Z","type":"event_msg","payload":{"type":"token_count","info":null}}
        {"timestamp":"2026-11-02T07:48:31.643Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":663900,"cached_input_tokens":624500,"output_tokens":4600,"reasoning_output_tokens":69},"last_token_usage":{"input_tokens":98200},"model_context_window":258400}}}
        """ + "\n"
        try rolloutContent.data(using: .utf8)!.write(to: rolloutURL)

        let usage = tracker.codexUsage(rollout: rolloutURL)
        #expect(usage != nil)
        #expect(usage?.model == "gpt-6-astra")
        // P2-19: inputTokens 改为 input_tokens - cached_input_tokens = 663900 - 624500 = 39400
        #expect(usage?.inputTokens == 39400)
        #expect(usage?.cachedInputTokens == 624500)
        #expect(usage?.outputTokens == 4600)
        #expect(usage?.reasoningTokens == 69)
        #expect(usage?.contextTokens == 98200)
        #expect(usage?.contextWindow == 258400)

        // P1-21: 文件大小和 mtime 都没变时直接返回 state.lastUsage，readCount 不增加
        let countBefore = tracker.readCount
        let usage2 = tracker.codexUsage(rollout: rolloutURL)
        #expect(usage2?.inputTokens == 39400)
        #expect(tracker.readCount == countBefore)
    }

    @Test("Codex: backward stream scan finds model when beyond 64KB tail")
    func testCodexBackwardStreamModelScan() throws {
        let tempDir = createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let rolloutURL = tempDir.appendingPathComponent("rollout-large.jsonl")
        let tracker = UsageTracker()

        // 头部放置模型配置
        let headerLine = "{\"type\":\"event_msg\",\"payload\":{\"type\":\"thread_settings_applied\",\"thread_settings\":{\"model\":\"deep-reasoner-v3\"}}}\n"
        var data = headerLine.data(using: .utf8)!

        // 填充超过 70KB 的普通事件，使得头部模型被挤出尾部 64KB 窗口
        let dummyLine = "{\"type\":\"event_msg\",\"payload\":{\"type\":\"turn_comment\",\"content\":\"filler text to expand file size beyond 64KB\"}}\n"
        let dummyData = dummyLine.data(using: .utf8)!
        while data.count < 75 * 1024 {
            data.append(dummyData)
        }

        // 尾部放置 token_count（无 model）
        let tailLine = "{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":1000,\"cached_input_tokens\":200,\"output_tokens\":50},\"last_token_usage\":{\"input_tokens\":800},\"model_context_window\":128000}}}\n"
        data.append(tailLine.data(using: .utf8)!)

        try data.write(to: rolloutURL)

        // 验证反向流式扫描能够成功找到模型名 (P1-19)
        let usage = tracker.codexUsage(rollout: rolloutURL)
        #expect(usage != nil)
        #expect(usage?.model == "deep-reasoner-v3")
        #expect(usage?.inputTokens == 800) // 1000 - 200
    }

    // MARK: - Adapter showUsage Switch Tests

    @Test("Adapter showUsage switch disables usage calculation and transcript disk read")
    func testAdapterShowUsageSwitch() throws {
        let tempDir = createTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sessionsDir = tempDir.appendingPathComponent("sessions")
        let projectsDir = tempDir.appendingPathComponent("projects")
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectsDir, withIntermediateDirectories: true)

        let pid = 88888
        let sessionId = "session-usage-switch"
        let sessionJSON = """
        {
            "pid": \(pid),
            "sessionId": "\(sessionId)",
            "cwd": "\(tempDir.path)",
            "status": "idle",
            "updatedAt": \(Int64(Date().timeIntervalSince1970 * 1000))
        }
        """
        try sessionJSON.data(using: .utf8)!.write(to: sessionsDir.appendingPathComponent("\(pid).json"))

        let slug = tempDir.path.replacingOccurrences(of: "[^A-Za-z0-9]", with: "-", options: .regularExpression)
        let transcriptDir = projectsDir.appendingPathComponent(slug)
        try FileManager.default.createDirectory(at: transcriptDir, withIntermediateDirectories: true)
        let transcriptURL = transcriptDir.appendingPathComponent("\(sessionId).jsonl")
        let transcriptContent = """
        {"type":"assistant","isSidechain":false,"message":{"model":"claude-opus-5-5","id":"msg_1","usage":{"input_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":5}}}
        """ + "\n"
        try transcriptContent.data(using: .utf8)!.write(to: transcriptURL)

        let customTracker = UsageTracker()
        let adapter = ClaudeCodeAdapter(
            sessionsDirectory: sessionsDir,
            projectsDirectory: projectsDir,
            isPidAlive: { _ in true },
            maxAgeSeconds: 3600,
            showUsage: false,
            usageTracker: customTracker
        )

        // 1. 关闭 showUsage 时：不计算 usage，且没有磁盘读取 transcript
        var sessions = try adapter.scan()
        #expect(sessions.count == 1)
        #expect(sessions.first?.usage == nil)
        #expect(customTracker.readCount == 0)

        // 2. 打开 showUsage 时：计算 usage，并产生读取
        adapter.showUsage = true
        sessions = try adapter.scan()
        #expect(sessions.count == 1)
        #expect(sessions.first?.usage != nil)
        #expect(sessions.first?.usage?.inputTokens == 10)
        #expect(customTracker.readCount > 0)
    }
}
