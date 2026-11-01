import SwiftUI
import AppKit
import AgentMonitorCore

public struct MenuView: View {
    @ObservedObject var viewModel: MonitorViewModel
    @Environment(\.colorScheme) var colorScheme

    public init(viewModel: MonitorViewModel) {
        self.viewModel = viewModel
    }

    /// Only set by the screenshot script; normally the panel follows the system appearance.
    private var forcedColorScheme: ColorScheme? {
        switch ProcessInfo.processInfo.environment["AGENT_MONITOR_COLOR_SCHEME"]?.lowercased() {
        case "dark": return .dark
        case "light": return .light
        default: return nil
        }
    }

    public var body: some View {
        VStack(spacing: 6) {
            PanelHeader(viewModel: viewModel)
            FilterBar(viewModel: viewModel)
            SessionList(viewModel: viewModel)
        }
        .padding(10)
        .frame(width: 384)
        .fixedSize(horizontal: false, vertical: true)
        .preferredColorScheme(forcedColorScheme)
    }
}
