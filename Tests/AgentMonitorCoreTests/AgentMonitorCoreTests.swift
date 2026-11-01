import Foundation
import Testing
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
            maxAgeSeconds: 100 * 365 * 86400
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

        init(kind: AgentKind) {
            self.kind = kind
        }

        func scan() throws -> [AgentSession] {
            mockSessions
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
        #expect(t2.first == .stateChanged(session: s1Waiting, from: .running, to: .waitingForUser))

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
}
