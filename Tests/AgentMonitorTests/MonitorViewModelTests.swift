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

    @Test("Panel appear and disappear toggles SessionStore isPanelVisible")
    func testPanelVisibilityToggle() {
        let store = SessionStore(adapters: [])
        let vm = MonitorViewModel(sessionStore: store)

        #expect(store.isPanelVisible == false)

        vm.onPanelAppear()
        #expect(store.isPanelVisible == true)

        vm.onPanelDisappear()
        #expect(store.isPanelVisible == false)
    }
}
