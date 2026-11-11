import SwiftUI
import AppKit
import AgentMonitorCore

public struct MenuBarLabelView: View {
    @ObservedObject var viewModel: MonitorViewModel
    @Environment(\.openSettings) private var openSettings

    public init(viewModel: MonitorViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        EquatableMenuBarIcon(summary: viewModel.menuBarStateSummary)
            .equatable()
            .onAppear {
                // 菜单栏标签在启动时就存在，通知唤醒无需先打开面板。
                SettingsWindowManager.shared.installOpenSettingsAction { openSettings() }
            }
    }
}

/// 仅当菜单栏摘要状态实际变化时才重建 NSImage，避免面板内状态变更触发重复绘制。
private struct EquatableMenuBarIcon: View, Equatable {
    let summary: MenuBarStateSummary

    var body: some View {
        Image(nsImage: MenuBarIconRenderer.image(
            highestState: summary.highestState,
            waitingCount: summary.waitingCount,
            isPaused: summary.isPaused,
            isOverdue: summary.isOverdue
        ))
    }
}
