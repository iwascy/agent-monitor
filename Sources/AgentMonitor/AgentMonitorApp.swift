import SwiftUI
import AppKit
import AgentMonitorCore

@main
struct AgentMonitorApp: App {
    @StateObject private var viewModel: MonitorViewModel

    init() {
        let claudeAdapter = ClaudeCodeAdapter()
        let codexAdapter = CodexAdapter()
        let store = SessionStore(adapters: [claudeAdapter, codexAdapter])
        _viewModel = StateObject(wrappedValue: MonitorViewModel(sessionStore: store))
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView(viewModel: viewModel)
        } label: {
            MenuBarLabelView(viewModel: viewModel)
        }
        .menuBarExtraStyle(.window)
    }
}
