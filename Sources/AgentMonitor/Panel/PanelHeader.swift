import SwiftUI
import AppKit
import AgentMonitorCore

struct PanelHeader: View {
    @ObservedObject var viewModel: MonitorViewModel

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Agent 会话")
                    .font(.headline)
                    .foregroundColor(.primary)
                let activeCount = viewModel.sessions.filter { $0.state != .idle }.count
                let agentCount = Set(viewModel.sessions.map { $0.kind }).count
                Text("\(activeCount) 个活跃 · \(agentCount) 个 agent")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    // Bell button
                    Button(action: {
                        viewModel.togglePauseNotifications()
                    }) {
                        Image(systemName: viewModel.isNotificationsPaused ? "bell.slash.fill" : "bell")
                            .foregroundColor(viewModel.isNotificationsPaused ? .orange : .primary)
                    }
                    .frame(width: 28, height: 28)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .controlSize(.regular)
                    .help(viewModel.isNotificationsPaused ? "恢复通知" : "暂停通知 1 小时")
                    .accessibilityLabel(viewModel.isNotificationsPaused ? "恢复通知" : "暂停通知 1 小时")

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
                            .foregroundColor(.primary)
                            .frame(width: 28, height: 28)
                            .glassEffect(.regular.interactive(), in: .circle)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                }
            }
        }
        .padding(EdgeInsets(top: 4, leading: 6, bottom: 2, trailing: 6))
    }
}
