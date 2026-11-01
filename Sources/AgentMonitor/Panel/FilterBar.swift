import SwiftUI
import AgentMonitorCore

struct FilterBar: View {
    @ObservedObject var viewModel: MonitorViewModel

    var body: some View {
        let waitingCount = viewModel.sessions.filter { $0.state == .waitingForUser }.count
        let doneCount = viewModel.sessions.filter { $0.state == .completed }.count
        let runningCount = viewModel.sessions.filter { $0.state == .running }.count
        let idleCount = viewModel.sessions.filter { $0.state == .idle }.count

        HStack(spacing: 6) {
            filterCard(count: waitingCount, label: "等你", state: .waitingForUser)
            filterCard(count: doneCount, label: "已完成", state: .completed)
            filterCard(count: runningCount, label: "运行中", state: .running)
            filterCard(count: idleCount, label: "空闲", state: .idle)
        }
        .padding(.bottom, 2)
    }

    private func filterCard(
        count: Int,
        label: String,
        state: SessionState
    ) -> some View {
        let isSelected = viewModel.filterState == state
        let tint = state.tint

        return Button(action: {
            if viewModel.filterState == state {
                viewModel.filterState = nil
            } else {
                viewModel.filterState = state
            }
        }) {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(count)")
                    .font(.system(size: 18, weight: .bold))
                    .monospacedDigit()
                    .foregroundColor(tint)
                    .lineLimit(1)
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(isSelected ? .primary : .secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 7)
            .padding(.horizontal, 9)
            .background(isSelected ? AnyShapeStyle(tint.opacity(0.18)) : AnyShapeStyle(.fill.quaternary))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(isSelected ? tint : Color.clear, lineWidth: 1.2)
            )
        }
        .buttonStyle(.plain)
    }
}
