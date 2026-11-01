import SwiftUI
import AgentMonitorCore

struct SessionList: View {
    @ObservedObject var viewModel: MonitorViewModel
    @LocalState private var isIdleHovered = false

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
                        let isExpanded = viewModel.isIdleExpanded || viewModel.filterState == .idle
                        Button(action: {
                            withAnimation(.smooth) {
                                viewModel.isIdleExpanded.toggle()
                            }
                        }) {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(Color.gray)
                                    .frame(width: 6, height: 6)
                                Text("空闲 · \(idleSessions.count) 个会话")
                                    .font(.caption.weight(.semibold))
                                    .foregroundColor(.secondary)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(.secondary)
                                    .rotationEffect(isExpanded ? .degrees(90) : .zero)
                            }
                            .padding(8)
                            .background(isIdleHovered ? AnyShapeStyle(.fill.quaternary) : AnyShapeStyle(Color.clear))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .onHover { isIdleHovered = $0 }

                        if isExpanded {
                            ForEach(idleSessions) { session in
                                SessionRow(session: session, viewModel: viewModel)
                                    .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                        }
                    }
                }

                if viewModel.sessions.isEmpty {
                    ContentUnavailableView {
                        Label("暂无活跃会话", systemImage: "rectangle.stack")
                    } description: {
                        Text("各 agent 启动后将在此处自动汇总")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 1)
        }
        .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
        .safeAreaInset(edge: .bottom) {
            if viewModel.sessions.contains(where: { $0.state == .completed }) {
                Button(action: {
                    withAnimation(.smooth) {
                        viewModel.markAllAsRead()
                    }
                }) {
                    Label("全部标为已读", systemImage: "checkmark")
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                .glassEffectTransition(.materialize)
                .padding(.top, 4)
                .padding(.bottom, 2)
                .frame(maxWidth: .infinity)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxHeight: 520)
    }

    private func sectionHeader(title: String, dotColor: Color) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
        }
        .padding(EdgeInsets(top: 6, leading: 8, bottom: 0, trailing: 8))
    }
}
