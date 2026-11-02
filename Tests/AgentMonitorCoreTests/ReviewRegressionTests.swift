import Combine
import Foundation
import Synchronization
import Testing
@testable import AgentMonitorCore

@Suite("v2 core review regressions")
struct CoreReviewRegressionTests {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("am-review-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func permissions(at url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require(attrs[.posixPermissions] as? NSNumber).intValue
    }

    @Test("Hook install, repair and uninstall preserve private permissions and backup bytes", arguments: [0o400, 0o600, 0o640])
    func testHookFilePermissions(mode: Int) throws {
        let directory = try temporaryDirectory()
        let settings = directory.appendingPathComponent("settings.json")
        let script = directory.appendingPathComponent("hook.sh")
        let backup = directory.appendingPathComponent("settings.json.agentmonitor-backup")
        defer {
            try? FileManager.default.removeItem(at: settings)
            try? FileManager.default.removeItem(at: script)
            try? FileManager.default.removeItem(at: backup)
        }
        let original = Data("{\"env\":{\"EXAMPLE_TOKEN\":\"dummy\"}}".utf8)
        try original.write(to: settings)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: settings.path)
        let installer = ClaudeHookInstaller(settingsURL: settings, scriptURL: script)

        try installer.install()
        #expect(try permissions(at: settings) == mode)
        #expect(try permissions(at: backup) == mode)
        #expect(try Data(contentsOf: backup) == original)
        let beforeRepair = try Data(contentsOf: settings)
        try installer.repair()
        #expect(try permissions(at: settings) == mode)
        #expect(try permissions(at: backup) == mode)
        #expect(try Data(contentsOf: backup) == beforeRepair)
        try installer.uninstall()
        #expect(try permissions(at: settings) == mode)
    }

    @Test("A new hooks settings file is private by default")
    func testNewHookFilePermissions() throws {
        let directory = try temporaryDirectory()
        let settings = directory.appendingPathComponent("settings.json")
        let script = directory.appendingPathComponent("hook.sh")
        defer {
            try? FileManager.default.removeItem(at: settings)
            try? FileManager.default.removeItem(at: script)
        }
        try ClaudeHookInstaller(settingsURL: settings, scriptURL: script).install()
        #expect(try permissions(at: settings) == 0o600)
    }

    @Test("Uninstall preserves empty user hooks without rewriting the file", arguments: [
        "{\"hooks\":{\"Stop\":[]}}",
        "{\"hooks\":{\"Stop\":[{\"matcher\":\"user\",\"hooks\":[]}]}}",
        "{\"hooks\":{\"Stop\":[],\"Notification\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"echo user\"}]}]}}"
    ])
    func testUninstallEmptyUserHooks(original: String) throws {
        let directory = try temporaryDirectory()
        let settings = directory.appendingPathComponent("settings.json")
        defer { try? FileManager.default.removeItem(at: settings) }
        let bytes = Data(original.utf8)
        try bytes.write(to: settings)
        let installer = ClaudeHookInstaller(settingsURL: settings, scriptURL: directory.appendingPathComponent("hook.sh"))
        try installer.uninstall()
        #expect(try Data(contentsOf: settings) == bytes)
    }

    @Test("Empty user hooks survive repair and removal of our hooks in another event")
    func testEmptyHooksAlongsideOwnedHooks() throws {
        let directory = try temporaryDirectory()
        let settings = directory.appendingPathComponent("settings.json")
        let script = directory.appendingPathComponent("hook.sh")
        let backup = directory.appendingPathComponent("settings.json.agentmonitor-backup")
        defer {
            try? FileManager.default.removeItem(at: settings)
            try? FileManager.default.removeItem(at: script)
            try? FileManager.default.removeItem(at: backup)
        }
        let installer = ClaudeHookInstaller(settingsURL: settings, scriptURL: script)
        let root: [String: Any] = ["hooks": [
            "Stop": [],
            "CustomEvent": [["matcher": "user", "hooks": []]],
            "Notification": [installer.makeHookEntry(for: "Notification")]
        ]]
        try JSONSerialization.data(withJSONObject: root).write(to: settings)
        try installer.uninstall()
        var result = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
        var hooks = try #require(result["hooks"] as? [String: Any])
        #expect((hooks["Stop"] as? [Any])?.isEmpty == true)
        #expect((hooks["CustomEvent"] as? [Any])?.count == 1)
        #expect(hooks["Notification"] == nil)
        try installer.repair()
        result = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
        hooks = try #require(result["hooks"] as? [String: Any])
        #expect((hooks["CustomEvent"] as? [Any])?.count == 1)
    }

    @Test("Unchanged rollouts cache missing usage and resume when token_count is appended", arguments: [false, true])
    func testCodexEmptyUsageCache(hasModel: Bool) throws {
        let directory = try temporaryDirectory()
        let rollout = directory.appendingPathComponent("rollout.jsonl")
        defer { try? FileManager.default.removeItem(at: rollout) }
        let header = hasModel
            ? "{\"type\":\"turn_context\",\"payload\":{\"model\":\"test-model\"}}\n"
            : "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\"}}\n"
        try Data(header.utf8).write(to: rollout)
        let tracker = UsageTracker()
        #expect(tracker.codexUsage(rollout: rollout) == nil)
        let reads = tracker.readCount
        #expect(tracker.codexUsage(rollout: rollout) == nil)
        #expect(tracker.readCount == reads)

        let handle = try FileHandle(forWritingTo: rollout)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":100,\"cached_input_tokens\":20}}}}\n".utf8))
        #expect(tracker.codexUsage(rollout: rollout)?.inputTokens == 80)
        #expect(tracker.readCount > reads)
    }

    @Test("Session subscribers receive counts after additions and disable changes without replacing callbacks")
    func testSessionSubscriptions() {
        let adapter = ReviewAdapter()
        let store = SessionStore(adapters: [adapter])
        let counts = Mutex<[Int]>([])
        let callbackCount = Mutex(0)
        let subscription = store.sessionsPublisher.sink { sessions in
            counts.withLock { $0.append(sessions.count) }
        }
        defer { subscription.cancel() }
        store.onSessionsUpdated = { _ in callbackCount.withLock { $0 += 1 } }
        store.refresh()
        adapter.sessions = [AgentSession(id: "1", kind: .claudeCode, title: "One", state: .running)]
        store.refresh()
        adapter.sessions.append(AgentSession(id: "2", kind: .claudeCode, title: "Two", state: .running))
        store.refresh()

        let lateCounts = Mutex<[Int]>([])
        let lateSubscription = store.sessionsPublisher.sink { sessions in
            lateCounts.withLock { $0.append(sessions.count) }
        }
        defer { lateSubscription.cancel() }
        store.disabledKinds = [.claudeCode]
        store.refresh()
        #expect(counts.withLock { $0 } == [0, 0, 1, 2, 0])
        #expect(lateCounts.withLock { $0 } == [2, 0])
        #expect(callbackCount.withLock { $0 } == 4)
    }
}

private final class ReviewAdapter: AgentAdapter, @unchecked Sendable {
    let kind: AgentKind = .claudeCode
    let watchPaths: [URL] = []
    var sessions: [AgentSession] = []
    func scan() throws -> [AgentSession] { sessions }
}
