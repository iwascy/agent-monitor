import SwiftUI
import AppKit
import AgentMonitorCore

/// 传递面板当前是否可见，供子视图在面板收起后暂停高频动画与计时器。
private struct PanelVisibleKey: EnvironmentKey {
    static let defaultValue: Bool = true
}

extension EnvironmentValues {
    var isPanelVisible: Bool {
        get { self[PanelVisibleKey.self] }
        set { self[PanelVisibleKey.self] = newValue }
    }
}

public struct MenuView: View {
    @ObservedObject var viewModel: MonitorViewModel
    @Environment(\.colorScheme) var colorScheme
    @LocalState private var localMonitor: Any? = nil
    @LocalState private var panelWindow: NSWindow? = nil

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
        .environment(\.isPanelVisible, viewModel.isPanelVisible)
        .preferredColorScheme(forcedColorScheme)
        .background(WindowAccessor { win in
            self.panelWindow = win
        })
        .focusable()
        .focusEffectDisabled()
        .onAppear {
            viewModel.onPanelAppear()
            if localMonitor == nil {
                localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    if let window = panelWindow, event.window !== window {
                        return event
                    }
                    if viewModel.handleKeyEvent(event) {
                        return nil
                    }
                    return event
                }
            }
            if ProcessInfo.processInfo.environment["AGENT_MONITOR_OPEN_SETTINGS"] == "1" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    SettingsWindowManager.shared.openSettings()
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

private struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            onResolve(view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            onResolve(nsView.window)
        }
    }
}
