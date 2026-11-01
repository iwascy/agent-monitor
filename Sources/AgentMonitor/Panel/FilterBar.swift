import SwiftUI
import AgentMonitorCore

struct FilterBar: View {
    @ObservedObject var viewModel: MonitorViewModel
    @Namespace private var ns

    var body: some View {
        let waitingCount = viewModel.sessions.filter { $0.state == .waitingForUser }.count
        let doneCount = viewModel.sessions.filter { $0.state == .completed }.count
        let runningCount = viewModel.sessions.filter { $0.state == .running }.count
        let idleCount = viewModel.sessions.filter { $0.state == .idle }.count

        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 6) {
                capsuleButton(state: .waitingForUser, count: waitingCount)
                capsuleButton(state: .completed, count: doneCount)
                capsuleButton(state: .running, count: runningCount)
                capsuleButton(state: .idle, count: idleCount)
            }
        }
        .padding(.horizontal, 2)
        .padding(.bottom, 2)
    }

    private func capsuleButton(state: SessionState, count: Int) -> some View {
        let isSelected = viewModel.filterState == state
        let tint = state.tint
        let isDisabled = count == 0

        return Button(action: {
            withAnimation(.bouncy) {
                if viewModel.filterState == state {
                    viewModel.filterState = nil
                } else {
                    viewModel.filterState = state
                }
            }
        }) {
            HStack(spacing: 4) {
                Circle()
                    .fill(isDisabled ? AnyShapeStyle(.tertiary) : AnyShapeStyle(tint))
                    .frame(width: 6, height: 6)
                Text("\(count)")
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(isDisabled ? AnyShapeStyle(.tertiary) : AnyShapeStyle(tint))
                Text(state.shortTitle)
                    .font(.caption)
                    .foregroundStyle(isDisabled ? AnyShapeStyle(.tertiary) : (isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)))
                    .fontWeight(isSelected ? .semibold : .regular)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .padding(.horizontal, 4)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .glassEffect(
            isSelected ? .regular.tint(tint.opacity(0.18)).interactive() : (isDisabled ? .regular : .regular.interactive()),
            in: .capsule
        )
        .glassEffectID(state, in: ns)
    }
}
