import SwiftUI
import AgentMonitorCore

struct PanelHeader: View {
    @ObservedObject var viewModel: MonitorViewModel

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Agent 会话")
                .font(.headline)
                .foregroundColor(.primary)
            Spacer()
            let activeCount = viewModel.sessions.filter { $0.state != .idle }.count
            let agentCount = Set(viewModel.sessions.map { $0.kind }).count
            Text("\(activeCount) 个活跃 · \(agentCount) 个 agent")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(EdgeInsets(top: 4, leading: 6, bottom: 2, trailing: 6))
    }
}
