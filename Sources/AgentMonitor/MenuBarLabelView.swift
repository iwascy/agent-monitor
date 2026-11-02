import SwiftUI
import AppKit
import AgentMonitorCore

public struct MenuBarLabelView: View {
    @ObservedObject var viewModel: MonitorViewModel

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
    }
}
