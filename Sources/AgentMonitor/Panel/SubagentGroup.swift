import SwiftUI
import AgentMonitorCore

/// 主会话行下方的子代理区：一条汇总条，展开后是带竖线的紧凑子行
struct SubagentGroup: View {
    let subagents: [AgentSession]
    var onSelectSubagent: ((AgentSession) -> Void)? = nil
    @LocalState private var userExpanded: Bool? = nil

    private var all: [AgentSession] {
        subagents.flatMap { [$0] + $0.subagents }
    }

    private var hasActive: Bool {
        all.contains { $0.state == .running || $0.state == .waitingForUser }
    }

    private var isExpanded: Bool { userExpanded ?? hasActive }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button(action: {
                withAnimation(.snappy(duration: 0.2)) { userExpanded = !isExpanded }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 10, weight: .semibold))
                    summaryContent
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(isExpanded ? .degrees(90) : .zero)
                }
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .background(.fill.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("子代理 · \(all.count) 个")

            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(subagents) { child in
                        SubagentRow(session: child, depth: 0) {
                            onSelectSubagent?(child)
                        }
                        ForEach(child.subagents) { grandchild in
                            SubagentRow(session: grandchild, depth: 1) {
                                onSelectSubagent?(grandchild)
                            }
                        }
                    }
                }
                .padding(.leading, 8)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(.separator)
                        .frame(width: 1.5)
                        .padding(.leading, 3)
                        .padding(.vertical, 4)
                }
                .transition(.opacity)
            }
        }
        .padding(.top, 6)
    }

    @ViewBuilder
    private var summaryContent: some View {
        let waiting = all.filter { $0.state == .waitingForUser }.count
        let running = all.filter { $0.state == .running }.count
        let done = all.filter { $0.state == .completed || $0.state == .idle }.count
        if waiting == 0 && running == 0 {
            Text("\(all.count) 个子代理已完成")
        } else {
            HStack(spacing: 3) {
                Text("\(all.count) 个子代理")
                if waiting > 0 {
                    Text("·").foregroundColor(.secondary)
                    Text("\(waiting) 等你").foregroundColor(.orange)
                }
                if running > 0 {
                    Text("·").foregroundColor(.secondary)
                    Text("\(running) 运行中").foregroundColor(.blue)
                }
                if done > 0 {
                    Text("·").foregroundColor(.secondary)
                    Text("\(done) 完成")
                }
            }
        }
    }
}

private struct SubagentRow: View {
    let session: AgentSession
    let depth: Int
    var onSelect: (() -> Void)? = nil
    @Environment(\.isPanelVisible) private var isPanelVisible

    var body: some View {
        Button(action: {
            onSelect?()
        }) {
            HStack(alignment: .top, spacing: 7) {
                statusMark
                    .frame(width: 10, height: 14)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(session.title)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(session.state == .completed ? .secondary : .primary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        timeText
                    }
                    if let detail = session.detail {
                        HStack(spacing: 5) {
                            if session.state == .waitingForUser {
                                Text(session.waitingLabel ?? "等待授权")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.orange)
                            }
                            Text(detail)
                                .font(session.detailIsCommand ? .system(size: 11, design: .monospaced) : .system(size: 11))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }
            .padding(.vertical, 4)
            .padding(.leading, 6 + CGFloat(depth) * 14)
            .padding(.trailing, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(session.title)
    }

    @ViewBuilder
    private var statusMark: some View {
        switch session.state {
        case .running: PulsingDotView()
        case .waitingForUser: Circle().fill(Color.orange).frame(width: 6, height: 6)
        case .completed:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 10)).foregroundColor(.green)
        case .idle: Circle().fill(Color.gray).frame(width: 6, height: 6)
        }
    }

    @ViewBuilder
    private var timeText: some View {
        switch session.state {
        case .running:
            if isPanelVisible {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    runningElapsedText(now: context.date)
                }
            } else {
                runningElapsedText(now: Date())
            }
        case .waitingForUser:
            Text(session.formattedTime).font(.system(size: 11, weight: .medium)).foregroundColor(.orange)
        default:
            Text("完成").font(.system(size: 11)).foregroundColor(.secondary)
        }
    }

    private func runningElapsedText(now: Date) -> some View {
        let elapsed = max(0, Int(now.timeIntervalSince(session.stateSince)))
        return Text(String(format: "%d:%02d", elapsed / 60, elapsed % 60))
            .font(.system(size: 11)).monospacedDigit().foregroundColor(.blue)
    }
}
