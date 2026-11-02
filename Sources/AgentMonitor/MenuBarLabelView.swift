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
        let state = viewModel.effectiveMenuState
        Image(nsImage: MenuBarIconRenderer.image(
            highestState: state.highestState,
            waitingCount: state.waitingCount,
            isPaused: state.isPaused,
            isOverdue: state.isOverdue
        ))
        .onAppear {
            // 菜单栏标签在启动时就存在，通知唤醒无需先打开面板。
            SettingsWindowManager.shared.installOpenSettingsAction { openSettings() }
        }
    }
}
