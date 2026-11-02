import SwiftUI
import AppKit
import AgentMonitorCore

struct SessionRow: View {
    let session: AgentSession
    @ObservedObject var viewModel: MonitorViewModel
    @Environment(\.colorScheme) private var colorScheme
    @LocalState private var isHovered = false

    var body: some View {
        Button(action: {
            withAnimation(.smooth) {
                viewModel.markAsRead(id: session.id)
            }
            activateApp(for: session.kind, entrypoint: session.entrypoint, cwd: session.cwd)
        }) {
            HStack(alignment: session.state == .running ? .center : .top, spacing: 10) {
                Image(nsImage: IconManager.shared.icon(for: session.kind, isDark: colorScheme == .dark))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 34, height: 34)
                    .padding(-2)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(NotificationFormatter.cleanTitle(session.title))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(session.state == .idle ? .secondary : .primary)
                            .lineLimit(1)
                        Spacer()
                        timeView
                    }

                    let cwdPart = session.cwd.map { ($0 as NSString).lastPathComponent } ?? ""
                    let sub = cwdPart.isEmpty ? session.kind.displayName : "\(session.kind.displayName) · \(cwdPart)"
                    Text(sub)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)

                    accessoryView
                }
            }
            .padding(EdgeInsets(top: session.state == .running ? 7 : 8, leading: 8, bottom: session.state == .running ? 7 : 8, trailing: 8))
            .background(isHovered ? AnyShapeStyle(.fill.quaternary) : AnyShapeStyle(Color.clear))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private var timeView: some View {
        switch session.state {
        case .waitingForUser:
            TimelineView(.periodic(from: .now, by: 30)) { context in
                let now = context.date
                let threshold = Double(AppSettings.shared.remindAfterMinutes * 60)
                let isOverdue = AppSettings.shared.remindEnabled && (now.timeIntervalSince(session.stateSince) >= threshold)
                let timeStr = StatusStyle.formattedTime(session: session, now: now)

                HStack(spacing: 3) {
                    if isOverdue {
                        Image(systemName: "alarm.fill")
                            .font(.system(size: 11))
                    }
                    Text(timeStr)
                        .font(.system(size: 11, weight: isOverdue ? .semibold : .medium))
                        .monospacedDigit()
                }
                .foregroundColor(isOverdue ? .red : .orange)
            }
        case .completed:
            Text(session.formattedTime)
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundColor(.secondary)
        case .running:
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let elapsed = max(0, Int(context.date.timeIntervalSince(session.stateSince)))
                let m = elapsed / 60
                let s = elapsed % 60
                Text(String(format: "%d:%02d", m, s))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundColor(.blue)
            }
        case .idle:
            Text(session.formattedTime)
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private var accessoryView: some View {
        switch session.state {
        case .waitingForUser:
            HStack(spacing: 7) {
                Text(session.waitingLabel ?? "等待授权")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(.orange)
                    .fixedSize()
                if let detail = session.detail {
                    Text(detail)
                        .font(session.detailIsCommand ? .system(.callout, design: .monospaced) : .system(size: 11.5))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .background(.fill.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.top, 4)

        case .completed:
            if let detail = session.detail {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.green)
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                .padding(.top, 2)
            }

        case .running:
            HStack(spacing: 6) {
                PulsingDotView()
                Text(session.detail ?? "正在思考…")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .padding(.top, 2)

        case .idle:
            EmptyView()
        }
    }
}
