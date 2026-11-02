import SwiftUI
import AppKit
import AgentMonitorCore

@main
struct AgentMonitorApp: App {
    @StateObject private var viewModel: MonitorViewModel

    init() {
        let claudeAdapter = ClaudeCodeAdapter()
        let codexAdapter = CodexAdapter()
        let dshAdapter = DshAdapter()
        let antigravityAdapter = AntigravityAdapter()
        let store = SessionStore(adapters: [claudeAdapter, codexAdapter, dshAdapter, antigravityAdapter])
        _viewModel = StateObject(wrappedValue: MonitorViewModel(sessionStore: store))
    }

    var body: some Scene {
        MenuBarExtra {
            MenuView(viewModel: viewModel)
        } label: {
            MenuBarLabelView(viewModel: viewModel)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(sessionStore: viewModel.sessionStore)
        }
    }
}
