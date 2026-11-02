import AppKit
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

    final class SessionsUpdatedBox: @unchecked Sendable {
        var callCount = 0
        var latest: [AgentSession] = []
        let lock = NSLock()
        func record(_ sessions: [AgentSession]) {
            lock.lock()
            defer { lock.unlock() }
            callCount += 1
            latest = sessions
        }
        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return callCount
        }
        var sessions: [AgentSession] {
            lock.lock()
            defer { lock.unlock() }
            return latest
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
        // Same timestamp for both: the store sets stateSince = lastActivity on first discovery
        let seenAt = Date()
        let s1 = AgentSession(id: "claudeCode:s1", kind: .claudeCode, title: "Session 1", state: .running, stateSince: seenAt, lastActivity: seenAt)
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

    @Test("DSH: approval request waits until its tool result or turn end")
    func testDshApprovalLifecycle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("project/session")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("session.v4.jsonl")
        let prefix = [
            #"{"type":"session","id":"approval"}"#,
            #"{"type":"turn/start"}"#,
            #"{"type":"tool/call","data":{"callId":"c1","name":"bash"}}"#,
            #"{"type":"approval/asked","data":{"id":"a1","callId":"c1","toolName":"bash","reason":"需要扩大沙箱权限"}}"#
        ]
        let adapter = DshAdapter(sessionsDirectory: root, isLockHeld: { _ in true })
        for (suffix, expected) in [
            ("", SessionState.waitingForUser),
            (#"{"type":"tool/result","data":{"callId":"other"}}"#, .waitingForUser),
            (#"{"type":"tool/result","data":{"message":{"source":{"callId":"c1"}}}}"#, .running),
            (#"{"type":"turn/end","data":{"reason":{"kind":"aborted"}}}"#, .idle)
        ] {
            try (prefix.joined(separator: "\n") + "\n" + suffix + "\n").write(to: file, atomically: true, encoding: .utf8)
            let session = try #require(try adapter.scan().first)
            #expect(session.state == expected)
            if expected == .waitingForUser {
                #expect(session.waitingLabel == "等待授权")
                #expect(session.detail == "需要扩大沙箱权限")
            }
        }
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

    @Test("SessionStore: Panel visibility controls session content updates without state transition")
    func testSessionStorePanelVisibilityControlsContentUpdates() throws {
        let mock = MockAdapter(kind: .antigravity)
        let store = SessionStore(adapters: [mock])

        let sessionBox = SessionsUpdatedBox()
        let transBox = TransitionBox()
        store.onSessionsUpdated = { updated in
            sessionBox.record(updated)
        }
        store.onTransition = { t in
            transBox.append(t)
        }

        // 1. Initial scan: session in running state
        let initialTime = Date()
        mock.mockSessions = [
            AgentSession(
                id: "antigravity:test-1",
                kind: .antigravity,
                title: "Task 1",
                state: .running,
                stateSince: initialTime,
                lastActivity: initialTime,
                detail: "正在运行 run_command…"
            )
        ]
        _ = store.refresh()
        #expect(sessionBox.count == 1) // Initial scan calls onSessionsUpdated
        #expect(sessionBox.sessions.first?.detail == "正在运行 run_command…")

        // 2. While panel is hidden (isPanelVisible = false): detail updates should NOT trigger onSessionsUpdated
        store.isPanelVisible = false
        mock.mockSessions = [
            AgentSession(
                id: "antigravity:test-1",
                kind: .antigravity,
                title: "Task 1",
                state: .running,
                stateSince: initialTime,
                lastActivity: initialTime.addingTimeInterval(5),
                detail: "正在运行 swift test…"
            )
        ]
        let tHidden = store.refresh()
        #expect(tHidden.isEmpty) // No state transition
        #expect(sessionBox.count == 1) // count remains 1, NOT updated in background!
        #expect(transBox.current.isEmpty)

        // 3. When panel becomes visible (isPanelVisible = true): detail updates DO trigger onSessionsUpdated
        store.isPanelVisible = true
        mock.mockSessions = [
            AgentSession(
                id: "antigravity:test-1",
                kind: .antigravity,
                title: "Task 1",
                state: .running,
                stateSince: initialTime,
                lastActivity: initialTime.addingTimeInterval(10),
                detail: "正在运行 git commit…"
            )
        ]
        let tVisible = store.refresh()
        #expect(tVisible.isEmpty) // No state transition
        #expect(sessionBox.count > 1) // onSessionsUpdated WAS called because panel is visible!
        #expect(sessionBox.sessions.first?.detail == "正在运行 git commit…")
        #expect(transBox.current.isEmpty) // Still no system notification generated

        // 4. When panel is hidden again, state transition (running -> completed) STILL notifies
        store.isPanelVisible = false
        let countBeforeStateChange = sessionBox.count
        mock.mockSessions = [
            AgentSession(
                id: "antigravity:test-1",
                kind: .antigravity,
                title: "Task 1",
                state: .idle,
                stateSince: initialTime.addingTimeInterval(15),
                lastActivity: initialTime.addingTimeInterval(15),
                detail: "全部完成"
            )
        ]
        let tStateChange = store.refresh()
        #expect(tStateChange.count == 1)
        #expect(sessionBox.count > countBeforeStateChange) // onSessionsUpdated called for state change!
        #expect(sessionBox.sessions.first?.state == .completed)
        #expect(transBox.current.count == 1) // Notification transition posted!
    }

    // MARK: - MenuBarIconRenderer Tests

    @Test("MenuBarIconRenderer: sizes and isTemplate across states")
    func testMenuBarIconRendererStates() {
        // 1. Idle (no dot, no badge, unpaused)
        let idleSize = MenuBarIconRenderer.size(highestState: nil, waitingCount: 0, isPaused: false)
        #expect(idleSize == NSSize(width: 16, height: 16))
        #expect(MenuBarIconRenderer.isTemplate(highestState: nil, waitingCount: 0) == true)
        let idleImg = MenuBarIconRenderer.image(highestState: nil, waitingCount: 0, isPaused: false)
        #expect(idleImg.size == NSSize(width: 16, height: 16))
        #expect(idleImg.isTemplate == true)

        // 2. Running (blue dot, isTemplate false)
        let runningSize = MenuBarIconRenderer.size(highestState: .running, waitingCount: 0, isPaused: false)
        #expect(runningSize == NSSize(width: 16, height: 16))
        #expect(MenuBarIconRenderer.isTemplate(highestState: .running, waitingCount: 0) == false)
        let runningImg = MenuBarIconRenderer.image(highestState: .running, waitingCount: 0, isPaused: false)
        #expect(runningImg.size == NSSize(width: 16, height: 16))
        #expect(runningImg.isTemplate == false)

        // 3. Completed (green dot, isTemplate false)
        let doneSize = MenuBarIconRenderer.size(highestState: .completed, waitingCount: 0, isPaused: false)
        #expect(doneSize == NSSize(width: 16, height: 16))
        #expect(MenuBarIconRenderer.isTemplate(highestState: .completed, waitingCount: 0) == false)
        let doneImg = MenuBarIconRenderer.image(highestState: .completed, waitingCount: 0, isPaused: false)
        #expect(doneImg.size == NSSize(width: 16, height: 16))
        #expect(doneImg.isTemplate == false)

        // 4. Waiting for user (orange dot, badge 2: 16 + 5 + 16 = 37)
        let waitSize = MenuBarIconRenderer.size(highestState: .waitingForUser, waitingCount: 2, isPaused: false)
        #expect(waitSize == NSSize(width: 37, height: 16))
        #expect(MenuBarIconRenderer.isTemplate(highestState: .waitingForUser, waitingCount: 2) == false)
        let waitImg = MenuBarIconRenderer.image(highestState: .waitingForUser, waitingCount: 2, isPaused: false)
        #expect(waitImg.size == NSSize(width: 37, height: 16))
        #expect(waitImg.isTemplate == false)

        // 5. Waiting for user with two digits (badge 10: badge width 21, 16 + 5 + 21 = 42)
        let wait10Size = MenuBarIconRenderer.size(highestState: .waitingForUser, waitingCount: 10, isPaused: false)
        #expect(wait10Size == NSSize(width: 42, height: 16))
        #expect(MenuBarIconRenderer.isTemplate(highestState: .waitingForUser, waitingCount: 10) == false)

        // 6. Notifications paused with active waiting state (dot, no badge, bell: 16 + 5 + 13 = 34)
        let pausedSize = MenuBarIconRenderer.size(highestState: .waitingForUser, waitingCount: 0, isPaused: true)
        #expect(pausedSize == NSSize(width: 34, height: 16))
        #expect(MenuBarIconRenderer.isTemplate(highestState: .waitingForUser, waitingCount: 0) == false)
        let pausedImg = MenuBarIconRenderer.image(highestState: .waitingForUser, waitingCount: 0, isPaused: true)
        #expect(pausedImg.size == NSSize(width: 34, height: 16))
        #expect(pausedImg.isTemplate == false)

        // 7. Notifications paused with idle state (no dot, no badge: isTemplate true)
        let pausedIdleSize = MenuBarIconRenderer.size(highestState: nil, waitingCount: 0, isPaused: true)
        #expect(pausedIdleSize == NSSize(width: 34, height: 16))
        #expect(MenuBarIconRenderer.isTemplate(highestState: nil, waitingCount: 0) == true)
        let pausedIdleImg = MenuBarIconRenderer.image(highestState: nil, waitingCount: 0, isPaused: true)
        #expect(pausedIdleImg.size == NSSize(width: 34, height: 16))
        #expect(pausedIdleImg.isTemplate == true)

        // 8. Waiting + Paused (16 + 5 + 16 + 5 + 13 = 55)
        let waitAndPausedSize = MenuBarIconRenderer.size(highestState: .waitingForUser, waitingCount: 2, isPaused: true)
        #expect(waitAndPausedSize == NSSize(width: 55, height: 16))
        let waitAndPausedImg = MenuBarIconRenderer.image(highestState: .waitingForUser, waitingCount: 2, isPaused: true)
        #expect(waitAndPausedImg.size == NSSize(width: 55, height: 16))
        #expect(waitAndPausedImg.isTemplate == false)
    }

    // MARK: - NotificationFormatter Tests

    @Test("NotificationFormatter: title cleaning and truncation")
    func testNotificationTitleCleaning() {
        let raw = "  你是 macOS 原生逆向分析员。\n任务目标是分析一个叫 BetterDisplay 的应用。  "
        let cleaned = NotificationFormatter.cleanTitle(raw, maxLength: 40)
        #expect(!cleaned.contains("\n"))
        #expect(!cleaned.contains("\r"))
        #expect(cleaned.count <= 40)
        #expect(cleaned.hasSuffix("…"))

        let session = AgentSession(
            id: "dsh:1",
            kind: .dsh,
            title: raw,
            state: .running
        )
        let formatted = NotificationFormatter.formatTitle(for: session)
        #expect(formatted.hasPrefix("DeepSeek Harness · "))
        #expect(formatted.count <= "DeepSeek Harness · ".count + 40)
    }

    @Test("NotificationFormatter: subtitle for waiting and completed")
    func testNotificationSubtitle() {
        let waitAuth = AgentSession(
            id: "cx:1",
            kind: .codex,
            title: "Cookie 同步",
            state: .waitingForUser,
            waitingLabel: "等待授权"
        )
        #expect(NotificationFormatter.formatSubtitle(for: waitAuth) == "等待授权")

        let waitQuestion = AgentSession(
            id: "cc:1",
            kind: .claudeCode,
            title: "讨论",
            state: .waitingForUser,
            waitingLabel: "在问你"
        )
        #expect(NotificationFormatter.formatSubtitle(for: waitQuestion) == "在问你")

        let completed = AgentSession(
            id: "ag:1",
            kind: .antigravity,
            title: "Loon",
            state: .completed,
            completedDuration: 372
        )
        #expect(NotificationFormatter.formatSubtitle(for: completed) == "已完成 · 用时 6 分 12 秒")
    }

    @Test("NotificationFormatter: body markdown stripping and truncation")
    func testNotificationBodyCleaning() {
        let raw = """
        # 执行结果

        Review 做完了，结论是**现在还不能用**。程序能编译，8 个测试也全过。

        详情请见 `README.md` 与 [docs/REVIEW-1.md](file:///path/to/docs)。
        """
        let cleaned = NotificationFormatter.cleanBody(raw, maxLength: 120)
        #expect(!cleaned.contains("**"))
        #expect(!cleaned.contains("`"))
        #expect(!cleaned.contains("#"))
        #expect(!cleaned.contains("file:///path/to/docs"))
        #expect(cleaned.contains("docs/REVIEW-1.md"))
        #expect(cleaned.contains("现在还不能用"))
        #expect(cleaned.count <= 120)
    }

    // MARK: - UI review #2 regressions

    /// Renders the menu bar image at 2x under `appearance` and returns the brightness and alpha
    /// of a pixel on the left edge of the rounded rectangle (x = 1.5pt, y = 8.2pt from the top).
    private func glyphPixel(appearanceName: NSAppearance.Name) throws -> (brightness: CGFloat, alpha: CGFloat) {
        // A fresh image per appearance: NSImage may cache the rendering of a drawing handler
        let image = MenuBarIconRenderer.image(highestState: .running, waitingCount: 0, isPaused: false)
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        rep.size = NSSize(width: 16, height: 16)

        let appearance = try #require(NSAppearance(named: appearanceName))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        appearance.performAsCurrentDrawingAppearance {
            image.draw(in: NSRect(x: 0, y: 0, width: 16, height: 16))
        }
        NSGraphicsContext.restoreGraphicsState()

        // colorAt(x:y:) uses a top-left origin
        let color = try #require(rep.colorAt(x: 3, y: 16)?.usingColorSpace(.deviceRGB))
        return (color.brightnessComponent, color.alphaComponent)
    }

    @Test("MenuBarIconRenderer: glyph is dark on a light menu bar and light on a dark one")
    func testMenuBarIconGlyphFollowsAppearance() throws {
        let light = try glyphPixel(appearanceName: .aqua)
        #expect(light.alpha > 0.5)
        #expect(light.brightness < 0.3)

        let dark = try glyphPixel(appearanceName: .darkAqua)
        #expect(dark.alpha > 0.5)
        #expect(dark.brightness > 0.7)
    }

    @Test("NotificationFormatter: commands are kept verbatim")
    func testNotificationBodyKeepsCommands() {
        let session = AgentSession(
            id: "codex:x", kind: .codex, title: "清理", state: .waitingForUser,
            detail: "rm *.log && ls *.txt   __init__.py `pwd`", detailIsCommand: true, waitingLabel: "等待授权"
        )
        #expect(NotificationFormatter.formatBody(for: session) == "rm *.log && ls *.txt __init__.py `pwd`")

        let prose = AgentSession(id: "cc:x", kind: .claudeCode, title: "t", state: .completed, detail: "**完成**了")
        #expect(NotificationFormatter.formatBody(for: prose) == "完成了")
    }

    @Test("NotificationFormatter: link cut off by truncation keeps only its text")
    func testNotificationBodyTruncatedLink() {
        let raw = "已创建 [docs/agents.md](file:///Users/cy/code/mac-r"
        #expect(NotificationFormatter.cleanBody(raw) == "已创建 docs/agents.md")
    }
}
