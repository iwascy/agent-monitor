import Testing
import AgentMonitorCore
@testable import AgentMonitor

@Suite("Subagent panel hierarchy")
@MainActor
struct SubagentHierarchyTests {
    @Test("Children are collapsed on open and nested expansion follows keyboard display order")
    func expansionAndNavigation() {
        let vm = MonitorViewModel(sessionStore: SessionStore(adapters: []))
        vm.updateSessionsManually(MonitorViewModel.mockSubagentSessions())
        #expect(vm.visibleSessionIDs == ["ag:parent"])
        vm.toggleSubagents(of: "ag:parent")
        #expect(vm.visibleSessionIDs == ["ag:parent", "ag:child-1", "ag:child-2", "ag:child-3"])
        vm.toggleSubagents(of: "ag:child-1")
        #expect(vm.visibleSessionIDs == ["ag:parent", "ag:child-1", "ag:grandchild", "ag:child-2", "ag:child-3"])
        vm.keyboardSelectionID = "ag:grandchild"
        vm.toggleSubagents(of: "ag:parent")
        #expect(vm.keyboardSelectionID == nil)
        vm.toggleSubagents(of: "ag:parent")
        vm.onPanelAppear()
        #expect(vm.visibleSessionIDs == ["ag:parent"])
        #expect(vm.expandedSubagentIDs.isEmpty)
    }

    @Test("Filtering a child state keeps its main session and collapsed hierarchy")
    func filterPreservesParent() {
        let vm = MonitorViewModel(sessionStore: SessionStore(adapters: []))
        vm.updateSessionsManually(MonitorViewModel.mockSubagentSessions())
        vm.filterState = .completed
        #expect(vm.roots(in: .completed).map(\.id) == ["ag:parent"])
        #expect(vm.visibleSessionIDs == ["ag:parent"])
        vm.toggleSubagents(of: "ag:parent")
        #expect(vm.visibleSessionIDs.contains("ag:child-2"))
        #expect(vm.visibleSessionIDs.filter { $0 == "ag:parent" }.count == 1)
    }

    @Test("Missing parents and cyclic metadata remain reachable")
    func brokenLinks() {
        let vm = MonitorViewModel(sessionStore: SessionStore(adapters: []))
        vm.updateSessionsManually([
            AgentSession(id: "a", kind: .antigravity, title: "A", state: .running, parentSessionID: "b"),
            AgentSession(id: "b", kind: .antigravity, title: "B", state: .running, parentSessionID: "a"),
            AgentSession(id: "orphan", kind: .antigravity, title: "Orphan", state: .running, parentSessionID: "missing")
        ])
        #expect(Set(vm.visibleSessionIDs) == ["a", "b", "orphan"])
        #expect(vm.depth(of: vm.sessions[0]) == 0)
    }
}
