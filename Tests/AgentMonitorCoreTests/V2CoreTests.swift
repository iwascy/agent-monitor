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

        // Root path "/" match (P2-2)
        let rootRule = MuteRule(path: "/", scope: .all)
        #expect(MuteRule.matchingRule(for: "/Users/test/proj", rules: [rootRule])?.id == rootRule.id)
        #expect(MuteRule.matchingRule(for: "/any/path", rules: [rootRule])?.id == rootRule.id)
        #expect(MuteRule.matchingRule(for: "/", rules: [rootRule])?.id == rootRule.id)
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

    @Test("NotificationPolicy table-driven test")
    func testNotificationPolicy() {
        struct TestCase {
            let name: String
            let session: AgentSession
            let transition: SessionTransition
            let settings: NotificationPolicy.SettingsSnapshot
            let muteRules: [MuteRule]
            let isPanelVisible: Bool
            let isNotificationsPaused: Bool
            let expected: Bool
        }

        let defaultWaiting = AgentSession(id: "s1", kind: .claudeCode, title: "T1", cwd: "/code/app", state: .waitingForUser)
        let defaultCompleted = AgentSession(id: "s2", kind: .claudeCode, title: "T2", cwd: "/code/app", state: .completed, completedDuration: 15)
        let shortCompleted = AgentSession(id: "s3", kind: .claudeCode, title: "T3", cwd: "/code/app", state: .completed, completedDuration: 5)

        let cases: [TestCase] = [
            TestCase(
                name: "Normal waiting notifies",
                session: defaultWaiting,
                transition: .stateChanged(session: defaultWaiting, from: .running, to: .waitingForUser),
                settings: .init(),
                muteRules: [],
                isPanelVisible: false,
                isNotificationsPaused: false,
                expected: true
            ),
            TestCase(
                name: "Normal completed notifies when duration >= minRunSeconds",
                session: defaultCompleted,
                transition: .stateChanged(session: defaultCompleted, from: .running, to: .completed),
                settings: .init(minRunSecondsForCompletion: 10),
                muteRules: [],
                isPanelVisible: false,
                isNotificationsPaused: false,
                expected: true
            ),
            TestCase(
                name: "Completed skipped when duration < minRunSeconds",
                session: shortCompleted,
                transition: .stateChanged(session: shortCompleted, from: .running, to: .completed),
                settings: .init(minRunSecondsForCompletion: 10),
                muteRules: [],
                isPanelVisible: false,
                isNotificationsPaused: false,
                expected: false
            ),
            TestCase(
                name: "Completed notified when minRunSeconds is 0",
                session: shortCompleted,
                transition: .stateChanged(session: shortCompleted, from: .running, to: .completed),
                settings: .init(minRunSecondsForCompletion: 0),
                muteRules: [],
                isPanelVisible: false,
                isNotificationsPaused: false,
                expected: true
            ),
            TestCase(
                name: "Notifications paused suppresses all",
                session: defaultWaiting,
                transition: .stateChanged(session: defaultWaiting, from: .running, to: .waitingForUser),
                settings: .init(),
                muteRules: [],
                isPanelVisible: false,
                isNotificationsPaused: true,
                expected: false
            ),
            TestCase(
                name: "Panel open suppresses when silenceWhilePanelOpen is true",
                session: defaultWaiting,
                transition: .stateChanged(session: defaultWaiting, from: .running, to: .waitingForUser),
                settings: .init(silenceWhilePanelOpen: true),
                muteRules: [],
                isPanelVisible: true,
                isNotificationsPaused: false,
                expected: false
            ),
            TestCase(
                name: "Panel open notifies when silenceWhilePanelOpen is false",
                session: defaultWaiting,
                transition: .stateChanged(session: defaultWaiting, from: .running, to: .waitingForUser),
                settings: .init(silenceWhilePanelOpen: false),
                muteRules: [],
                isPanelVisible: true,
                isNotificationsPaused: false,
                expected: true
            ),
            TestCase(
                name: "Mute all suppresses waiting and completed",
                session: defaultWaiting,
                transition: .stateChanged(session: defaultWaiting, from: .running, to: .waitingForUser),
                settings: .init(),
                muteRules: [MuteRule(path: "/code/app", scope: .all)],
                isPanelVisible: false,
                isNotificationsPaused: false,
                expected: false
            ),
            TestCase(
                name: "Mute completedOnly allows waiting",
                session: defaultWaiting,
                transition: .stateChanged(session: defaultWaiting, from: .running, to: .waitingForUser),
                settings: .init(),
                muteRules: [MuteRule(path: "/code/app", scope: .completedOnly)],
                isPanelVisible: false,
                isNotificationsPaused: false,
                expected: true
            ),
            TestCase(
                name: "Mute completedOnly suppresses completed",
                session: defaultCompleted,
                transition: .stateChanged(session: defaultCompleted, from: .running, to: .completed),
                settings: .init(),
                muteRules: [MuteRule(path: "/code/app", scope: .completedOnly)],
                isPanelVisible: false,
                isNotificationsPaused: false,
                expected: false
            ),
            TestCase(
                name: "notifyWaiting disabled suppresses waiting",
                session: defaultWaiting,
                transition: .stateChanged(session: defaultWaiting, from: .running, to: .waitingForUser),
                settings: .init(notifyWaiting: false),
                muteRules: [],
                isPanelVisible: false,
                isNotificationsPaused: false,
                expected: false
            ),
            TestCase(
                name: "notifyCompleted disabled suppresses completed",
                session: defaultCompleted,
                transition: .stateChanged(session: defaultCompleted, from: .running, to: .completed),
                settings: .init(notifyCompleted: false),
                muteRules: [],
                isPanelVisible: false,
                isNotificationsPaused: false,
                expected: false
            )
        ]

        for tc in cases {
            let actual = NotificationPolicy.shouldNotify(
                session: tc.session,
                transition: tc.transition,
                settings: tc.settings,
                muteRules: tc.muteRules,
                isPanelVisible: tc.isPanelVisible,
                isNotificationsPaused: tc.isNotificationsPaused
            )
            #expect(actual == tc.expected, "Failed test case: \(tc.name)")
        }
    }

    @Test("MenuBarIconRenderer: isOverdue does not change size, only changes badge color")
    func testMenuBarIconRendererOverdue() {
        let sizeNormal = MenuBarIconRenderer.size(highestState: .waitingForUser, waitingCount: 2, isPaused: false, isOverdue: false)
        let sizeOverdue = MenuBarIconRenderer.size(highestState: .waitingForUser, waitingCount: 2, isPaused: false, isOverdue: true)
        #expect(sizeNormal == sizeOverdue)

        let imgNormal = MenuBarIconRenderer.image(highestState: .waitingForUser, waitingCount: 2, isPaused: false, isOverdue: false)
        let imgOverdue = MenuBarIconRenderer.image(highestState: .waitingForUser, waitingCount: 2, isPaused: false, isOverdue: true)
        #expect(imgNormal.size == imgOverdue.size)
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
