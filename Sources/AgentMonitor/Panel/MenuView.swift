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
            bottomBarView
        }
        .padding(10)
        .frame(width: 384)
        .preferredColorScheme(forcedColorScheme)
    }

    // MARK: - Bottom Bar (to be refactored in #5)
    private var bottomBarView: some View {
        VStack(spacing: 2) {
            Rectangle()
                .fill(Color.secondary.opacity(0.2))
                .frame(height: 0.5)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)

            HStack(spacing: 2) {
                Button("全部标为已读") {
                    viewModel.markAllAsRead()
                }
                .font(.system(size: 12))
                .foregroundColor(.primary)
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)

                Spacer()

                // Pause notifications toggle
                Button(action: {
                    viewModel.togglePauseNotifications()
                }) {
                    Image(systemName: viewModel.isNotificationsPaused ? "bell.slash.fill" : "bell")
                        .font(.system(size: 14))
                        .foregroundColor(viewModel.isNotificationsPaused ? .orange : .secondary)
                        .frame(width: 30, height: 28)
                }
                .buttonStyle(.plain)
                .help(viewModel.isNotificationsPaused ? "恢复通知" : "暂停通知 1 小时")

                // Settings Menu
                Menu {
                    Toggle("开机启动", isOn: Binding(
                        get: { viewModel.isLaunchAtLogin },
                        set: { viewModel.setLaunchAtLogin($0) }
                    ))
                    Divider()
                    Button("退出 Agent Monitor") {
                        NSApplication.shared.terminate(nil)
                    }
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                        .frame(width: 30, height: 28)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 30, height: 28)
            }
        }
    }
}
