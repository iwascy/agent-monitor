import Foundation
import Testing
import SQLite3
@testable import AgentMonitorCore

@Suite("AgentMonitorCore Tests")
struct AgentMonitorCoreTests {

    private func fixtureURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
    }

    // MARK: - Claude Code Tests

    @Test("Claude Code: Active running session")
    func testClaudeRunning() throws {
        let fixtures = fixtureURL().appendingPathComponent("Claude")
        let sessionsDir = fixtures.appendingPathComponent("sessions")
        let projectsDir = fixtures.appendingPathComponent("projects")

        let adapter = ClaudeCodeAdapter(
            sessionsDirectory: sessionsDir,
            projectsDirectory: projectsDir,
            isPidAlive: { pid in pid == 99901 },
            maxAgeSeconds: 100 * 365 * 86400,
            waitingThreshold: 0.1
        )

        let sessions = try adapter.scan()
        #expect(sessions.count == 1)
        let s = try #require(sessions.first)
        #expect(s.id == "claudeCode:cc-session-running-1")
        #expect(s.kind == .claudeCode)
        #expect(s.state == .running)
        #expect(s.title == "Project A Work")
    }

    @Test("Claude Code: Waiting for user authorization")
    func testClaudeWaiting() throws {
        let fixtures = fixtureURL().appendingPathComponent("Claude")
        let sessionsDir = fixtures.appendingPathComponent("sessions")
        let projectsDir = fixtures.appendingPathComponent("projects")

        let adapter = ClaudeCodeAdapter(
            sessionsDirectory: sessionsDir,
            projectsDirectory: projectsDir,
            isPidAlive: { pid in pid == 99902 },
            maxAgeSeconds: 100 * 365 * 86400,
            waitingThreshold: 0.0 // instant wait for test
        )

        let sessions = try adapter.scan()
        #expect(sessions.count == 1)
        let s = try #require(sessions.first)
        #expect(s.id == "claudeCode:cc-session-waiting-2")
        #expect(s.state == .waitingForUser)
        #expect(s.waitingLabel == "等待授权")
        #expect(s.detail == "git push --force origin main")
        #expect(s.detailIsCommand == true)
    }

    @Test("Claude Code: Completed round")
    func testClaudeCompleted() throws {
        let fixtures = fixtureURL().appendingPathComponent("Claude")
        let sessionsDir = fixtures.appendingPathComponent("sessions")
        let projectsDir = fixtures.appendingPathComponent("projects")

        let adapter = ClaudeCodeAdapter(
            sessionsDirectory: sessionsDir,
            projectsDirectory: projectsDir,
            isPidAlive: { pid in pid == 99903 },
            maxAgeSeconds: 100 * 365 * 86400
        )

        let sessions = try adapter.scan()
        #expect(sessions.count == 1)
        let s = try #require(sessions.first)
        #expect(s.id == "claudeCode:cc-session-completed-3")
        #expect(s.state == .idle)
        #expect(s.detail?.contains("测试全部通过") == true)
    }

    @Test("Claude Code: Dead process is skipped")
    func testClaudeDeadProcess() throws {
        let fixtures = fixtureURL().appendingPathComponent("Claude")
        let sessionsDir = fixtures.appendingPathComponent("sessions")
        let projectsDir = fixtures.appendingPathComponent("projects")

        let adapter = ClaudeCodeAdapter(
            sessionsDirectory: sessionsDir,
            projectsDirectory: projectsDir,
            isPidAlive: { _ in false },
            maxAgeSeconds: 100 * 365 * 86400
        )

        let sessions = try adapter.scan()
        #expect(sessions.isEmpty)
    }

    // MARK: - Codex Tests

    private func setupCodexTestDir() throws -> (tempSessionsDir: URL, indexURL: URL) {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let calendar = Calendar(identifier: .gregorian)
        let now = Date()
        let year = String(format: "%04d", calendar.component(.year, from: now))
        let month = String(format: "%02d", calendar.component(.month, from: now))
        let day = String(format: "%02d", calendar.component(.day, from: now))

        let targetDir = tempDir.appendingPathComponent("sessions").appendingPathComponent(year).appendingPathComponent(month).appendingPathComponent(day)
        try fm.createDirectory(at: targetDir, withIntermediateDirectories: true)

        let fixturesCodex = fixtureURL().appendingPathComponent("Codex")
        let indexSrc = fixturesCodex.appendingPathComponent("session_index.jsonl")
        let indexDst = tempDir.appendingPathComponent("session_index.jsonl")
        try fm.copyItem(at: indexSrc, to: indexDst)

        for name in ["rollout-waiting-exec.jsonl", "rollout-waiting-input.jsonl", "rollout-running.jsonl", "rollout-completed.jsonl"] {
            let src = fixturesCodex.appendingPathComponent(name)
            let dst = targetDir.appendingPathComponent("rollout-2026-11-01T00-00-00-\(name)")
            try fm.copyItem(at: src, to: dst)
        }

        return (tempDir.appendingPathComponent("sessions"), indexDst)
    }

    @Test("Codex: All 4 states scanned and mapped")
    func testCodexStates() throws {
        let (sessionsDir, indexURL) = try setupCodexTestDir()
        defer {
            try? FileManager.default.removeItem(at: sessionsDir.deletingLastPathComponent())
        }

        let adapter = CodexAdapter(
            sessionsDirectory: sessionsDir,
            sessionIndexURL: indexURL,
            isCodexRunning: { true },
            maxAgeSeconds: 100 * 365 * 86400,
            activeThreshold: 100 * 365 * 86400
        )

        let sessions = try adapter.scan()
        #expect(sessions.count == 4)

        let waitingExec = try #require(sessions.first(where: { $0.id == "codex:cx-uuid-waiting-exec" }))
        #expect(waitingExec.state == .waitingForUser)
        #expect(waitingExec.waitingLabel == "等待授权")
        #expect(waitingExec.detail == "systemctl restart nas")
        #expect(waitingExec.detailIsCommand == true)
        #expect(waitingExec.title == "修复 NAS 启动")

        let waitingInput = try #require(sessions.first(where: { $0.id == "codex:cx-uuid-waiting-input" }))
        #expect(waitingInput.state == .idle)
        #expect(waitingInput.detail == "已中止")
        #expect(waitingInput.title == "重构 Cookie 逻辑")

        let running = try #require(sessions.first(where: { $0.id == "codex:cx-uuid-running" }))
        #expect(running.state == .running)
        #expect(running.title == "正在巡检服务器")

        let completed = try #require(sessions.first(where: { $0.id == "codex:cx-uuid-completed" }))
        #expect(completed.state == .idle)
        #expect(completed.title == "排查 HDMI 信号")
        #expect(completed.detail?.contains("HDMI EDID") == true)
    }

    // MARK: - DSH Tests

    @Test("DSH: Scanning waiting, running, and completed states")
    func testDshStates() throws {
        let fixtures = fixtureURL().appendingPathComponent("Dsh")
        let sessionsDir = fixtures.appendingPathComponent("sessions")

        let adapter = DshAdapter(
            sessionsDirectory: sessionsDir,
            zstdExecutablePath: "/opt/homebrew/bin/zstd",
            isLockHeld: { path in
                path.contains("dsh-uuid-waiting") || path.contains("dsh-uuid-running")
            },
            maxAgeSeconds: 100 * 365 * 86400
        )

        let sessions = try adapter.scan()
        #expect(sessions.count == 3)

        let waiting = try #require(sessions.first(where: { $0.id == "dsh:dsh-uuid-waiting" }))
        #expect(waiting.state == .waitingForUser)
        #expect(waiting.waitingLabel == "在问你")
        #expect(waiting.detail == "是否确认执行部署？")
        #expect(waiting.detailIsCommand == false)
        #expect(waiting.title == "DSH 等待用户交互测试")

        let running = try #require(sessions.first(where: { $0.id == "dsh:dsh-uuid-running" }))
        #expect(running.state == .running)
        #expect(running.detail == "正在运行 bash · pnpm build")
        #expect(running.title == "DSH 正在运行测试")

        let completed = try #require(sessions.first(where: { $0.id == "dsh:dsh-uuid-completed" }))
        #expect(completed.state == .idle)
        #expect(completed.detail == "构建顺利完成，产物已打包。")
        #expect(completed.title == "DSH 已完成测试")
    }

    // MARK: - Antigravity Tests

    @Test("Antigravity: Scanning running, waiting, and completed states")
    func testAntigravityStates() throws {
        let fixtures = fixtureURL().appendingPathComponent("Antigravity")

        let adapter = AntigravityAdapter(
            baseDirectory: fixtures,
            isLockHeld: { path in
                path.contains("ag-uuid-running") || path.contains("ag-uuid-waiting")
            },
            maxAgeSeconds: 100 * 365 * 86400
        )

        let sessions = try adapter.scan()
        #expect(sessions.count == 3)

        let waiting = try #require(sessions.first(where: { $0.id == "antigravity:ag-uuid-waiting" }))
        #expect(waiting.state == .waitingForUser)
        #expect(waiting.waitingLabel == "在问你")
        #expect(waiting.detail == "请选择需要重构的模块")
        #expect(waiting.title == "Antigravity 等待用户回复")

        let running = try #require(sessions.first(where: { $0.id == "antigravity:ag-uuid-running" }))
        #expect(running.state == .running)
        #expect(running.detail == "正在思考…")
        #expect(running.title == "Antigravity 运行中会话")

        let completed = try #require(sessions.first(where: { $0.id == "antigravity:ag-uuid-completed" }))
        #expect(completed.state == .idle)
        #expect(completed.detail == "已生成 5 个组件并更新文档")
        #expect(completed.title == "Antigravity 已完成任务")
    }

    // MARK: - SessionStore Tests

    private final class MockAdapter: AgentAdapter, @unchecked Sendable {
        let kind: AgentKind
        let watchPaths: [URL] = []
        var mockSessions: [AgentSession] = []
        var shouldThrow: Bool = false

        init(kind: AgentKind) {
            self.kind = kind
        }

        func scan() throws -> [AgentSession] {
            if shouldThrow {
                struct MockScanError: Error {}
                throw MockScanError()
            }
            return mockSessions
        }
    }

    final class TransitionBox: @unchecked Sendable {
        var list: [SessionTransition] = []
        let lock = NSLock()
        func append(_ t: SessionTransition) {
            lock.lock()
            defer { lock.unlock() }
            list.append(t)
        }
        var current: [SessionTransition] {
            lock.lock()
            defer { lock.unlock() }
            return list
        }
    }

    @Test("SessionStore: Diffing transitions and sorting")
    func testSessionStoreTransitionsAndSorting() throws {
        let mock = MockAdapter(kind: .claudeCode)
        let store = SessionStore(adapters: [mock], maxAgeSeconds: 3600, pollingInterval: 60)

        let box = TransitionBox()
        store.onTransition = { t in
            box.append(t)
        }

        // 1. Initial scan: 1 running session
        let s1 = AgentSession(id: "claudeCode:s1", kind: .claudeCode, title: "Session 1", state: .running)
        mock.mockSessions = [s1]
        let t1 = store.refresh()
        #expect(t1.count == 1)
        #expect(t1.first == .added(s1))

        // 2. State change: running -> waitingForUser
        let s1Waiting = AgentSession(id: "claudeCode:s1", kind: .claudeCode, title: "Session 1", state: .waitingForUser)
        mock.mockSessions = [s1Waiting]
        let t2 = store.refresh()
        #expect(t2.count == 1)
        if case .stateChanged(let session, let from, let to) = t2.first {
            #expect(session.id == "claudeCode:s1")
            #expect(from == .running)
            #expect(to == .waitingForUser)
        } else {
            Issue.record("Expected stateChanged transition")
        }

        // 3. Add session that is reported as idle on first scan -> stays idle
        let s2 = AgentSession(id: "claudeCode:s2", kind: .claudeCode, title: "Session 2", state: .idle)
        mock.mockSessions = [s1Waiting, s2]
        _ = store.refresh()

        // 4. Upgrade: s1Waiting transitions to idle -> promoted to completed!
        let s1Idle = AgentSession(id: "claudeCode:s1", kind: .claudeCode, title: "Session 1", state: .idle)
        mock.mockSessions = [s1Idle, s2]
        _ = store.refresh()

        let sorted = store.currentSessions
        #expect(sorted.count == 2)
        #expect(sorted[0].id == "claudeCode:s1") // completed is rank 1
        #expect(sorted[0].state == .completed)
        #expect(sorted[1].id == "claudeCode:s2") // idle is rank 3
        #expect(sorted[1].state == .idle)

        // 5. Mark s1 as read
        store.markAsRead(id: "claudeCode:s1")
        let afterRead = store.currentSessions
        let s1After = try #require(afterRead.first(where: { $0.id == "claudeCode:s1" }))
        #expect(s1After.state == .idle)
    }

    @Test("SessionStore: Initial scan does not promote idle sessions to completed")
    func testSessionStoreInitialScanDoesNotPromoteToCompleted() throws {
        let mock = MockAdapter(kind: .claudeCode)
        // Session reported as idle on first scan
        let s1 = AgentSession(id: "claudeCode:s1", kind: .claudeCode, title: "Session 1", state: .idle)
        mock.mockSessions = [s1]

        let store = SessionStore(adapters: [mock])
        let box = TransitionBox()
        store.onTransition = { box.append($0) }

        _ = store.refresh()

        // Verify session remains idle
        let sessions = store.currentSessions
        #expect(sessions.count == 1)
        #expect(sessions.first?.state == .idle)
        // Verify initial scan does not dispatch transitions to notifications
        #expect(box.current.isEmpty)
    }

    @Test("SessionStore: Running transitions to idle promoted to completed with duration")
    func testSessionStoreRunningToIdlePromotion() throws {
        let mock = MockAdapter(kind: .antigravity)
        let store = SessionStore(adapters: [mock])

        let startTime = Date().addingTimeInterval(-25) // started 25 seconds ago
        let runningSession = AgentSession(
            id: "antigravity:ag-1",
            kind: .antigravity,
            title: "Task 1",
            state: .running,
            stateSince: startTime,
            lastActivity: startTime
        )
        mock.mockSessions = [runningSession]
        _ = store.refresh()

        #expect(store.currentSessions.first?.state == .running)

        // Second scan: agent becomes idle
        let idleSession = AgentSession(
            id: "antigravity:ag-1",
            kind: .antigravity,
            title: "Task 1",
            state: .idle,
            stateSince: Date(),
            lastActivity: Date()
        )
        mock.mockSessions = [idleSession]
        let transitions = store.refresh()

        let updated = try #require(store.currentSessions.first)
        #expect(updated.state == .completed)
        #expect(updated.completedDuration != nil)
        #expect((updated.completedDuration ?? 0) >= 20.0)

        // Verify stateChanged transition generated
        let change = try #require(transitions.first)
        if case .stateChanged(let s, let from, let to) = change {
            #expect(s.id == "antigravity:ag-1")
            #expect(from == .running)
            #expect(to == .completed)
        } else {
            Issue.record("Expected stateChanged transition")
        }
    }

    @Test("SessionStore: Marked as read session does not revert to completed on lastActivity change")
    func testSessionStoreMarkedAsReadDoesNotRevertOnActivityChange() throws {
        let mock = MockAdapter(kind: .dsh)
        let store = SessionStore(adapters: [mock])

        // 1. Initial running
        let s = AgentSession(id: "dsh:d1", kind: .dsh, title: "DSH Work", state: .running)
        mock.mockSessions = [s]
        _ = store.refresh()

        // 2. Becomes idle -> promoted to completed
        let sIdle = AgentSession(id: "dsh:d1", kind: .dsh, title: "DSH Work", state: .idle)
        mock.mockSessions = [sIdle]
        _ = store.refresh()
        #expect(store.currentSessions.first?.state == .completed)

        // 3. Mark as read -> becomes idle
        store.markAsRead(id: "dsh:d1")
        #expect(store.currentSessions.first?.state == .idle)

        // 4. Subsequent scan where file mtime/lastActivity is updated, but still reported idle
        let updatedTime = Date().addingTimeInterval(30)
        let sStillIdle = AgentSession(
            id: "dsh:d1",
            kind: .dsh,
            title: "DSH Work",
            state: .idle,
            stateSince: updatedTime,
            lastActivity: updatedTime
        )
        mock.mockSessions = [sStillIdle]
        _ = store.refresh()

        // MUST stay idle!
        let finalSessions = store.currentSessions
        #expect(finalSessions.first?.state == .idle)
    }

    @Test("SessionStore: Retains sessions when adapter scan throws error")
    func testSessionStoreRetainsSessionsWhenAdapterFails() throws {
        let mock = MockAdapter(kind: .codex)
        let store = SessionStore(adapters: [mock])

        let s = AgentSession(id: "codex:cx-1", kind: .codex, title: "Codex Thread", state: .running)
        mock.mockSessions = [s]
        _ = store.refresh()
        #expect(store.currentSessions.count == 1)

        // Subsequent scan fails
        mock.shouldThrow = true
        _ = store.refresh()

        // Session must be retained!
        #expect(store.currentSessions.count == 1)
        #expect(store.currentSessions.first?.id == "codex:cx-1")
    }

    // MARK: - Review #2 regressions

    /// Copies the Antigravity fixture to a temp dir and converts the DB to WAL mode.
    /// Closing the only connection checkpoints and deletes `-wal`/`-shm`, which is exactly
    /// the on-disk state of a real Antigravity install while it is idle.
    private func makeIdleWalAntigravityDir() throws -> URL {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.copyItem(at: fixtureURL().appendingPathComponent("Antigravity"), to: tempDir)

        let dbPath = tempDir.appendingPathComponent("conversation_summaries.db").path
        var db: OpaquePointer?
        #expect(sqlite3_open(dbPath, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)

        #expect(!fm.fileExists(atPath: dbPath + "-wal"))
        #expect(!fm.fileExists(atPath: dbPath + "-shm"))
        let header = try FileHandle(forReadingFrom: URL(fileURLWithPath: dbPath))
        try header.seek(toOffset: 18)
        #expect(header.readData(ofLength: 2) == Data([2, 2]))
        try header.close()
        return tempDir
    }

    @Test("Antigravity: WAL database without -wal/-shm is still readable")
    func testAntigravityIdleWalDatabase() throws {
        let baseDir = try makeIdleWalAntigravityDir()
        let adapter = AntigravityAdapter(baseDirectory: baseDir, isLockHeld: { _ in false }, maxAgeSeconds: 100 * 365 * 86400)

        let sessions = try adapter.scan()
        #expect(sessions.count == 3)
    }

    @Test("Antigravity: unreadable database throws so the store keeps previous sessions")
    func testAntigravityUnreadableDatabaseThrows() throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try Data("not a sqlite database".utf8).write(to: tempDir.appendingPathComponent("conversation_summaries.db"))

        let adapter = AntigravityAdapter(baseDirectory: tempDir, isLockHeld: { _ in false })
        #expect(throws: (any Error).self) { try adapter.scan() }
    }

    private func writeCodexRollout(lines: [String], paddingBytes: Int = 0) throws -> URL {
        let fm = FileManager.default
        let sessionsDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("sessions/2026/10/30")
        try fm.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        var body = lines[0] + "\n"
        if paddingBytes > 0 {
            let filler = #"{"type":"response_item","payload":{"type":"reasoning","summary":[]}}"#
            body += String(repeating: filler + "\n", count: paddingBytes / filler.count + 1)
        }
        body += lines.dropFirst().joined(separator: "\n") + "\n"
        let file = sessionsDir.appendingPathComponent("rollout-2026-10-30T02-15-31-01a188df-cf09-7763-8796-5609ef455ca1.jsonl")
        try body.write(to: file, atomically: true, encoding: .utf8)
        return sessionsDir.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    @Test("Codex: heartbeat turn suppresses completion; session_meta read from file head")
    func testCodexHeartbeatAndHeadMeta() throws {
        let sessionsDir = try writeCodexRollout(lines: [
            #"{"type":"session_meta","payload":{"session_id":"01a188df-cf09-7763-8796-5609ef455ca1","cwd":"/Users/cy/Documents/Codex/new-chat"}}"#,
            #"{"type":"event_msg","payload":{"type":"task_started"}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"<heartbeat>\n  <automation_id>automation</automation_id>\n  <decision>DONT_NOTIFY</decision>\n</heartbeat>"}]}}"#,
            #"{"type":"event_msg","payload":{"type":"task_complete"}}"#
        ], paddingBytes: 100_000)

        let adapter = CodexAdapter(sessionsDirectory: sessionsDir, sessionIndexURL: sessionsDir.appendingPathComponent("none.jsonl"))
        let session = try #require(try adapter.scan().first)
        #expect(session.id == "codex:01a188df-cf09-7763-8796-5609ef455ca1")
        #expect(session.cwd == "/Users/cy/Documents/Codex/new-chat")
        #expect(session.state == .idle)
        #expect(session.suppressCompletion)
        #expect(session.detail == nil)
    }

    @Test("Codex: ordinary completed turn is not suppressed")
    func testCodexNormalTurnNotSuppressed() throws {
        let sessionsDir = try writeCodexRollout(lines: [
            #"{"type":"session_meta","payload":{"session_id":"01a188df-cf09-7763-8796-5609ef455ca1","cwd":"/tmp/x"}}"#,
            #"{"type":"event_msg","payload":{"type":"task_started"}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"已修复并部署。"}]}}"#,
            #"{"type":"event_msg","payload":{"type":"task_complete"}}"#
        ])

        let adapter = CodexAdapter(sessionsDirectory: sessionsDir, sessionIndexURL: sessionsDir.appendingPathComponent("none.jsonl"))
        let session = try #require(try adapter.scan().first)
        #expect(!session.suppressCompletion)
        #expect(session.detail == "已修复并部署。")
    }

    @Test("DSH: aborted turn suppresses completion and refreshes detail")
    func testDshAbortedTurn() throws {
        let fm = FileManager.default
        let sessionDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("--Users-cy-code-x--/session-abc")
        try fm.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let lines = [
            #"{"type":"session","id":"session-abc","cwd":"/Users/cy/code/x"}"#,
            #"{"type":"turn/start","seq":1,"data":{"turn":1}}"#,
            #"{"type":"assistant/message","seq":2,"data":{"message":{"role":"assistant","content":[{"type":"text","text":"先看一下目录结构。"}]}}}"#,
            #"{"type":"tool/call","seq":3,"data":{"callId":"c1","name":"bash","arguments":"{\"command\":\"ls\"}"}}"#,
            #"{"type":"turn/end","seq":4,"data":{"turn":1,"reason":{"kind":"aborted"}}}"#
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: sessionDir.appendingPathComponent("session.v4.jsonl"), atomically: true, encoding: .utf8)

        let adapter = DshAdapter(sessionsDirectory: sessionDir.deletingLastPathComponent().deletingLastPathComponent(), isLockHeld: { _ in true })
        let session = try #require(try adapter.scan().first)
        #expect(session.state == .idle)
        #expect(session.suppressCompletion)
        #expect(session.detail == "先看一下目录结构。")
    }

    @Test("SessionStore: running -> idle with suppressCompletion stays idle")
    func testSessionStoreSuppressCompletion() throws {
        let mock = MockAdapter(kind: .codex)
        let store = SessionStore(adapters: [mock])

        mock.mockSessions = [AgentSession(id: "codex:hb", kind: .codex, title: "巡检", state: .running)]
        _ = store.refresh()

        mock.mockSessions = [AgentSession(id: "codex:hb", kind: .codex, title: "巡检", state: .idle, suppressCompletion: true)]
        let transitions = store.refresh()

        #expect(store.currentSessions.first?.state == .idle)
        if case .stateChanged(_, let from, let to)? = transitions.first {
            #expect(from == .running)
            #expect(to == .idle)
        } else {
            Issue.record("Expected running -> idle transition")
        }
    }
}
