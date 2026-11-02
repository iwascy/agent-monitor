import Foundation
import Testing
@testable import AgentMonitorCore

@Suite("v2 Core Models and Store Tests")
struct V2CoreTests {

    @Test("MuteRule matching logic")
    func testMuteRuleMatching() {
        let rule1 = MuteRule(path: "/Users/test", scope: .all, hideInPanel: false)
        let rule2 = MuteRule(path: "/Users/test/proj", scope: .completedOnly, hideInPanel: true)
        let rules = [rule1, rule2]

        // Exact match
        #expect(MuteRule.matchingRule(for: "/Users/test/proj", rules: rules)?.id == rule2.id)

        // Subdirectory prefix match
        #expect(MuteRule.matchingRule(for: "/Users/test/proj/sub/folder", rules: rules)?.id == rule2.id)

        // Matches shorter rule when not under proj
        #expect(MuteRule.matchingRule(for: "/Users/test/other", rules: rules)?.id == rule1.id)

        // Must not match /Users/test/proj_other as proj
        #expect(MuteRule.matchingRule(for: "/Users/test/proj_other", rules: rules)?.id == rule1.id)

        // No match for unrelated path
        #expect(MuteRule.matchingRule(for: "/var/log", rules: rules) == nil)

        // Nil cwd
        #expect(MuteRule.matchingRule(for: nil, rules: rules) == nil)
    }

    @Test("ClaudeCodeAdapter finds transcript when cwd has underscores and dots")
    func testClaudeTranscriptSlugWithDotsAndUnderscores() throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let sessionsDir = tempDir.appendingPathComponent("sessions")
        let projectsDir = tempDir.appendingPathComponent("projects")
        try fm.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: projectsDir, withIntermediateDirectories: true)

        let cwd = "/Users/cyan/my_app.v2/src"
        // Regex [^A-Za-z0-9] -> "-" turns "/Users/cyan/my_app.v2/src" into "-Users-cyan-my-app-v2-src"
        let slug = cwd.replacingOccurrences(of: "[^A-Za-z0-9]", with: "-", options: .regularExpression)
        let transcriptDir = projectsDir.appendingPathComponent(slug)
        try fm.createDirectory(at: transcriptDir, withIntermediateDirectories: true)

        let sessionId = "session-test-123"
        let transcriptFile = transcriptDir.appendingPathComponent("\(sessionId).jsonl")
        try "{\"type\":\"assistant\",\"message\":{\"content\":\"Hello\"}}\n".write(to: transcriptFile, atomically: true, encoding: .utf8)

        let sessionMetaJSON = """
        {
            "pid": 99999,
            "sessionId": "\(sessionId)",
            "cwd": "\(cwd)",
            "status": "idle"
        }
        """
        let metaFile = sessionsDir.appendingPathComponent("99999.json")
        try sessionMetaJSON.write(to: metaFile, atomically: true, encoding: .utf8)

        let adapter = ClaudeCodeAdapter(
            sessionsDirectory: sessionsDir,
            projectsDirectory: projectsDir,
            isPidAlive: { _ in true },
            maxAgeSeconds: 3600
        )

        let sessions = try adapter.scan()
        #expect(sessions.count == 1)
        #expect(sessions.first?.pid == 99999)
        #expect(sessions.first?.transcriptPath == transcriptFile.path)
    }

    @Test("SessionStore disabledKinds skips adapter and removes existing without notification")
    func testSessionStoreDisabledKinds() {
        let session1 = AgentSession(id: "claudeCode:s1", kind: .claudeCode, title: "CC", state: .running)
        let session2 = AgentSession(id: "codex:s2", kind: .codex, title: "CX", state: .running)

        let mockCC = MockAdapter(kind: .claudeCode, sessions: [session1])
        let mockCX = MockAdapter(kind: .codex, sessions: [session2])

        let store = SessionStore(adapters: [mockCC, mockCX], maxAgeSeconds: 3600)
        _ = store.refresh()
        #expect(store.currentSessions.count == 2)

        final class TransitionCollector: @unchecked Sendable {
            var list: [SessionTransition] = []
            let lock = NSLock()
            func append(_ t: SessionTransition) {
                lock.lock()
                defer { lock.unlock() }
                list.append(t)
            }
        }
        let collector = TransitionCollector()
        store.onTransition = { t in
            collector.append(t)
        }

        // Disable claudeCode
        store.disabledKinds = [.claudeCode]
        _ = store.refresh()

        // claudeCode session should be gone
        #expect(store.currentSessions.count == 1)
        #expect(store.currentSessions.first?.id == "codex:s2")
        // SPEC requirement: remove without notifying
        #expect(collector.list.isEmpty)
    }
}

private final class MockAdapter: AgentAdapter, @unchecked Sendable {
    let kind: AgentKind
    var sessions: [AgentSession]
    var watchPaths: [URL] = []

    init(kind: AgentKind, sessions: [AgentSession]) {
        self.kind = kind
        self.sessions = sessions
    }

    func scan() throws -> [AgentSession] {
        return sessions
    }
}
