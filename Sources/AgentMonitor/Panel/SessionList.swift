import SwiftUI
import AgentMonitorCore

struct SessionList: View {
    @ObservedObject var viewModel: MonitorViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                let waitingSessions = viewModel.sessions.filter { $0.state == .waitingForUser }
                let doneSessions = viewModel.sessions.filter { $0.state == .completed }
                let runningSessions = viewModel.sessions.filter { $0.state == .running }
                let idleSessions = viewModel.sessions.filter { $0.state == .idle }

                if viewModel.filterState == nil || viewModel.filterState == .waitingForUser {
                    if !waitingSessions.isEmpty {
                        sectionHeader(title: "等你回复", dotColor: .orange)
                        ForEach(waitingSessions) { session in
                            SessionRow(session: session, viewModel: viewModel)
                        }
                    }
                }

                if viewModel.filterState == nil || viewModel.filterState == .completed {
                    if !doneSessions.isEmpty {
                        sectionHeader(title: "已完成", dotColor: .green)
                        ForEach(doneSessions) { session in
                            SessionRow(session: session, viewModel: viewModel)
                        }
                    }
                }

                if viewModel.filterState == nil || viewModel.filterState == .running {
                    if !runningSessions.isEmpty {
                        sectionHeader(title: "运行中", dotColor: .blue)
                        ForEach(runningSessions) { session in
                            SessionRow(session: session, viewModel: viewModel)
                        }
                    }
                }

                if viewModel.filterState == nil || viewModel.filterState == .idle {
                    if !idleSessions.isEmpty {
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                viewModel.isIdleExpanded.toggle()
                            }
                        }) {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(Color.gray)
                                    .frame(width: 6, height: 6)
                                Text("空闲 · \(idleSessions.count) 个会话")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                                Spacer()
                                Image(systemName: viewModel.isIdleExpanded ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(.secondary)
                            }
                            .padding(8)
                            .background(Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        }
                        .buttonStyle(.plain)

                        if viewModel.isIdleExpanded || viewModel.filterState == .idle {
                            ForEach(idleSessions) { session in
                                SessionRow(session: session, viewModel: viewModel)
                            }
                        }
                    }
                }

                if viewModel.sessions.isEmpty {
                    VStack(spacing: 4) {
                        Text("暂无活跃会话")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.secondary)
                        Text("各 agent 启动后将在此处自动汇总")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary.opacity(0.8))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func sectionHeader(title: String, dotColor: Color) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
        }
        .padding(EdgeInsets(top: 6, leading: 8, bottom: 0, trailing: 8))
    }
}
