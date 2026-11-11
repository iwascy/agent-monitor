import Foundation
import Testing
import AgentMonitorCore
@testable import AgentMonitor

@Suite("MonitorViewModel Tests")
@MainActor
struct MonitorViewModelTests {

    private func session(_ id: String, _ state: SessionState) -> AgentSession {
        AgentSession(id: id, kind: .claudeCode, title: id, state: state)
    }

    @Test("Filter is cleared once no session matches it")
    func testShouldClearFilter() {
        let sessions = [session("a", .running), session("b", .idle)]

        #expect(MonitorViewModel.shouldClearFilter(currentFilter: nil, sessions: sessions) == false)
        #expect(MonitorViewModel.shouldClearFilter(currentFilter: .running, sessions: sessions) == false)
        // The last completed session was marked as read, so the completed filter has nothing left to show
        #expect(MonitorViewModel.shouldClearFilter(currentFilter: .completed, sessions: sessions) == true)
        #expect(MonitorViewModel.shouldClearFilter(currentFilter: .idle, sessions: []) == true)
    }

    @Test("Mark-all-read shows only when completed sessions are visible")
    func testShouldShowMarkAllAsRead() {
        let withDone = [session("a", .completed), session("b", .waitingForUser)]
        let withoutDone = [session("b", .waitingForUser)]

        #expect(MonitorViewModel.shouldShowMarkAllAsRead(sessions: withDone, filterState: nil) == true)
        #expect(MonitorViewModel.shouldShowMarkAllAsRead(sessions: withDone, filterState: .completed) == true)
        #expect(MonitorViewModel.shouldShowMarkAllAsRead(sessions: withDone, filterState: .waitingForUser) == false)
        #expect(MonitorViewModel.shouldShowMarkAllAsRead(sessions: withoutDone, filterState: nil) == false)
    }

    @Test("Panel appear and disappear toggles SessionStore and ViewModel isPanelVisible")
    func testPanelVisibilityToggle() {
        let store = SessionStore(adapters: [])
        let vm = MonitorViewModel(sessionStore: store)

        #expect(store.isPanelVisible == false)
        #expect(vm.isPanelVisible == false)

        vm.onPanelAppear()
        #expect(store.isPanelVisible == true)
        #expect(vm.isPanelVisible == true)

        vm.onPanelDisappear()
        #expect(store.isPanelVisible == false)
        #expect(vm.isPanelVisible == false)
    }

    @Test("Mute rules filter sessions from panel and menu bar")
    func testMuteRulesPanelAndMenuBar() {
        let store = SessionStore(adapters: [])
        let vm = MonitorViewModel(sessionStore: store)

        // 清理原有规则
        AppSettings.shared.muteRules = []

        let s1 = AgentSession(id: "s1", kind: .claudeCode, title: "S1", cwd: "/code/projectA", state: .waitingForUser)
        let s2 = AgentSession(id: "s2", kind: .codex, title: "S2", cwd: "/code/projectB/sub", state: .waitingForUser)
        let s3 = AgentSession(id: "s3", kind: .dsh, title: "S3", cwd: "/code/projectC", state: .running)

        // 更新 sessions
        vm.updateSessionsManually([s1, s2, s3])

        // 1. hideInPanel 规则：隐藏 projectA
        vm.hideInPanel(cwd: "/code/projectA")
        #expect(vm.sessions.contains(where: { $0.id == "s1" }) == false)
        #expect(vm.sessions.contains(where: { $0.id == "s2" }) == true)
        #expect(vm.sessions.contains(where: { $0.id == "s3" }) == true)

        // 2. muteSession 规则（scope = .all）：静音 projectB
        vm.muteSession(cwd: "/code/projectB", scope: .all)
        // s2 仍在面板中（因为 hideInPanel = false）
        #expect(vm.sessions.contains(where: { $0.id == "s2" }) == true)
        // 但 s2 命中 scope == .all，不计入 waitingCount
        #expect(vm.waitingCount == 0)
        // highestState 也不再是 waitingForUser，而是 running（由 s3 贡献）
        #expect(vm.highestState == .running)
    }

    @Test("Tree projection preserves usage and applies mute filters before nesting")
    func testTreeWithMuteAndUsage() {
        let previous = AppSettings.shared.muteRules
        defer { AppSettings.shared.muteRules = previous }
        AppSettings.shared.muteRules = []
        let vm = MonitorViewModel(sessionStore: SessionStore(adapters: []))
        let parent = AgentSession(id: "parent", kind: .dsh, title: "Parent", cwd: "/parent",
                                  state: .idle, usage: SessionUsage(inputTokens: 42))
        let child = AgentSession(id: "child", kind: .dsh, title: "Child", cwd: "/child",
                                 state: .waitingForUser, parentId: "parent")
        vm.updateSessionsManually([parent, child])
        #expect(vm.sessions.count == 1)
        #expect(vm.sessions.first?.state == .waitingForUser)
        #expect(vm.sessions.first?.usage?.inputTokens == 42)
        #expect(vm.sessions.first?.subagents.map(\.id) == ["child"])
        vm.hideInPanel(cwd: "/child")
        #expect(vm.sessions.first?.state == .idle)
        #expect(vm.sessions.first?.subagents.isEmpty == true)
    }

    @Test("Reading a child clears the completed family without losing the tree")
    func testMarkChildFamilyRead() {
        let previous = AppSettings.shared.muteRules
        defer { AppSettings.shared.muteRules = previous }
        AppSettings.shared.muteRules = []
        let vm = MonitorViewModel(sessionStore: SessionStore(adapters: []))
        let parent = AgentSession(id: "parent", kind: .dsh, title: "Parent", state: .completed)
        let child = AgentSession(id: "child", kind: .dsh, title: "Child", state: .completed, parentId: "parent")
        let grandchild = AgentSession(id: "grandchild", kind: .dsh, title: "Grandchild", state: .completed, parentId: "child")
        vm.updateSessionsManually([parent, child, grandchild])
        vm.markAsRead(id: "child")
        #expect(vm.sessions.count == 1)
        #expect(vm.sessions.first?.state == .idle)
        #expect(vm.sessions.first?.subagents.first?.state == .idle)
        #expect(vm.sessions.first?.subagents.first?.subagents.first?.state == .idle)
    }

    @Test("Precomputed hierarchy index handles counts, menuBarStateSummary, and cyclic parent links")
    func testHierarchyIndexAndMenuSummary() {
        let previous = AppSettings.shared.muteRules
        defer { AppSettings.shared.muteRules = previous }
        AppSettings.shared.muteRules = []

        let vm = MonitorViewModel(sessionStore: SessionStore(adapters: []))
        let rootRun = AgentSession(id: "root-run", kind: .claudeCode, title: "Root", state: .running)
        let childWait = AgentSession(id: "child-wait", kind: .claudeCode, title: "Child", state: .waitingForUser, parentSessionID: "root-run")
        // 构造互相指向的异常环形 parentSessionID，验证不会死循环且降级作为根节点展示
        let cycleA = AgentSession(id: "cycle-a", kind: .codex, title: "Cycle A", state: .completed, parentSessionID: "cycle-b")
        let cycleB = AgentSession(id: "cycle-b", kind: .codex, title: "Cycle B", state: .idle, parentSessionID: "cycle-a")

        vm.updateSessionsManually([rootRun, childWait, cycleA, cycleB])

        #expect(vm.sessionCount(for: .running) == 1)
        #expect(vm.sessionCount(for: .waitingForUser) == 1)
        #expect(vm.sessionCount(for: .completed) == 1)
        #expect(vm.sessionCount(for: .idle) == 1)
        #expect(vm.depth(of: rootRun) == 0)
        #expect(vm.depth(of: childWait) == 1)
        #expect(vm.depth(of: cycleA) == 0)
        #expect(vm.depth(of: cycleB) == 0)

        // 筛选 waitingForUser 时，子树包含 waitingForUser 的 rootRun 应被返回
        vm.filterState = .waitingForUser
        #expect(vm.roots(in: .waitingForUser).map(\.id) == ["root-run"])

        let summary = vm.menuBarStateSummary
        #expect(summary.highestState == .waitingForUser)
        #expect(summary.waitingCount == (AppSettings.shared.showWaitingCountInMenuBar ? 1 : 0))
    }

    @Test("Native sysctl process listing includes current process")
    func testNativeProcessListingIncludesSelf() throws {
        let listing = try #require(TerminalSessionNavigator.nativeProcessListing())
        let selfPID = Foundation.ProcessInfo.processInfo.processIdentifier
        let hasSelf = listing.split(separator: "\n").contains { line in
            line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" }).first == Substring(String(selfPID))
        }
        #expect(hasSelf == true)
    }
}
