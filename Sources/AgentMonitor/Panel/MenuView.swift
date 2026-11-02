import SwiftUI
import AppKit
import AgentMonitorCore

public struct MenuView: View {
    @ObservedObject var viewModel: MonitorViewModel
    @Environment(\.colorScheme) var colorScheme
    @LocalState private var localMonitor: Any? = nil

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

            if viewModel.keyboardSelectionID != nil {
                HStack(spacing: 10) {
                    hotkeyHint(key: "↑↓", label: "选择")
                    hotkeyHint(key: "↩", label: "跳转")
                    hotkeyHint(key: "⌫", label: "已读")
                    hotkeyHint(key: "1–4", label: "筛选")
                    hotkeyHint(key: "esc", label: "关闭")
                }
                .padding(.top, 2)
                .frame(maxWidth: .infinity, alignment: .center)
                .transition(.opacity.animation(.easeInOut(duration: 0.15)))
            }
        }
        .padding(10)
        .frame(width: 384)
        .fixedSize(horizontal: false, vertical: true)
        .preferredColorScheme(forcedColorScheme)
        .focusable()
        .focusEffectDisabled()
        .onAppear {
            viewModel.onPanelAppear()
            if localMonitor == nil {
                localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    if viewModel.handleKeyEvent(event) {
                        return nil
                    }
                    return event
                }
            }
        }
        .onDisappear {
            viewModel.onPanelDisappear()
            if let monitor = localMonitor {
                NSEvent.removeMonitor(monitor)
                localMonitor = nil
            }
        }
    }

    private func hotkeyHint(key: String, label: String) -> some View {
        HStack(spacing: 3) {
            Text(key)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(Color.secondary.opacity(0.8))
        }
    }
}
