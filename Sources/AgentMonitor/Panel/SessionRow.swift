import SwiftUI
import AppKit
import AgentMonitorCore

struct SessionRow: View {
    let session: AgentSession
    @ObservedObject var viewModel: MonitorViewModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isPanelVisible) private var isPanelVisible
    @LocalState private var isHovered = false
    private static var lastScreenMouseLocation: CGPoint? = nil

    var body: some View {
        let isSelected = session.id == viewModel.keyboardSelectionID
        VStack(alignment: .leading, spacing: 0) {
            Button(action: {
                SessionJumper.shared.jump(to: session) {
                    withAnimation(.smooth) {
                        viewModel.markAsRead(id: session.id)
                    }
                }
            }) {
                HStack(alignment: session.state == .running && session.subagents.isEmpty ? .center : .top, spacing: 10) {
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
                        let isOrphanSubagent = session.parentId != nil || session.subagentDepth > 0
                        let sub = isOrphanSubagent
                            ? (cwdPart.isEmpty ? "\(session.kind.displayName) · 子代理" : "\(session.kind.displayName) · 子代理 · \(cwdPart)")
                            : (cwdPart.isEmpty ? session.kind.displayName : "\(session.kind.displayName) · \(cwdPart)")
                        HStack(spacing: 4) {
                            Text(session.paseo.map { $0.displayLabel + (cwdPart.isEmpty ? "" : " · \(cwdPart)") } ?? sub)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                            Spacer()
                            if let usage = session.usage {
                                UsageChip(usage: usage)
                            }
                        }

                        accessoryView
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !session.subagents.isEmpty {
                SubagentGroup(subagents: session.subagents) { _ in
                    SessionJumper.shared.jump(to: session) {
                        withAnimation(.smooth) {
                            viewModel.markAsRead(id: session.id)
                        }
                    }
                }
                .padding(.leading, 44)
            }
        }
        .padding(EdgeInsets(top: session.state == .running ? 7 : 8, leading: 8, bottom: session.state == .running ? 7 : 8, trailing: 8))
        .background((isHovered || isSelected) ? AnyShapeStyle(.fill.quaternary) : AnyShapeStyle(Color.clear))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.7) : Color.clear, lineWidth: 1.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityValue(isSelected ? "已选中" : "")
        .onContinuousHover { phase in
            switch phase {
            case .active(_):
                isHovered = true
                let screenLoc = NSEvent.mouseLocation
                if let last = Self.lastScreenMouseLocation, last == screenLoc {
                    return
                }
                Self.lastScreenMouseLocation = screenLoc
                if viewModel.keyboardSelectionID != nil {
                    viewModel.keyboardSelectionID = nil
                }
            case .ended:
                isHovered = false
            }
        }
        .contextMenu {
            SessionJumpMenuItem(session: session, viewModel: viewModel)

            Button {
                withAnimation(.smooth) {
                    viewModel.markAsRead(id: session.id)
                }
            } label: {
                Label("标为已读", systemImage: "checkmark")
            }
            .disabled(session.state != .completed)

            Divider()

            let hasCwd = session.cwd != nil && !(session.cwd?.isEmpty ?? true)
            let cwd = session.cwd ?? ""

            Button {
                if hasCwd {
                    let expanded = (cwd as NSString).expandingTildeInPath
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: expanded)
                }
            } label: {
                Label("在访达中显示目录", systemImage: "folder")
            }
            .disabled(!hasCwd || session.paseo?.isLocal == false)

            Button {
                if hasCwd {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(cwd, forType: .string)
                }
            } label: {
                Label("拷贝目录路径", systemImage: "doc.on.doc")
            }
            .disabled(!hasCwd)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(session.id, forType: .string)
            } label: {
                Label("拷贝会话 ID", systemImage: "doc.on.doc")
            }

            Divider()

            Menu {
                Button("所有通知") {
                    viewModel.muteSession(cwd: session.cwd, scope: .all)
                }
                Button("仅「已完成」通知") {
                    viewModel.muteSession(cwd: session.cwd, scope: .completedOnly)
                }
            } label: {
                Label("静音此项目", systemImage: "bell.slash")
            }
            .disabled(!hasCwd)

            Button {
                viewModel.hideInPanel(cwd: session.cwd)
            } label: {
                Label("在面板中隐藏此项目", systemImage: "eye.slash")
            }
            .disabled(!hasCwd)
        }
    }

    @ViewBuilder
    private var timeView: some View {
        switch session.state {
        case .waitingForUser:
            if isPanelVisible {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    waitingTimeContent(now: context.date)
                }
            } else {
                waitingTimeContent(now: Date())
            }
        case .completed:
            Text(session.formattedTime)
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundColor(.secondary)
        case .running:
            if isPanelVisible {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    runningTimeContent(now: context.date)
                }
            } else {
                runningTimeContent(now: Date())
            }
        case .idle:
            Text(session.formattedTime)
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundColor(.secondary)
        }
    }

    /// 渲染等待用户响应的计时视图（抽离以便面板隐藏时静态渲染且保持布局高度一致）。
    private func waitingTimeContent(now: Date) -> some View {
        let threshold = Double(AppSettings.shared.remindAfterMinutes * 60)
        let isOverdue = AppSettings.shared.remindEnabled && (now.timeIntervalSince(session.stateSince) >= threshold)
        let timeStr = StatusStyle.formattedTime(session: session, now: now)

        return HStack(spacing: 3) {
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

    /// 渲染运行中会话的读秒文本（面板隐藏时停用每秒定时器）。
    private func runningTimeContent(now: Date) -> some View {
        let elapsed = max(0, Int(now.timeIntervalSince(session.stateSince)))
        let m = elapsed / 60
        let s = elapsed % 60
        return Text(String(format: "%d:%02d", m, s))
            .font(.system(size: 11))
            .monospacedDigit()
            .foregroundColor(.blue)
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

private struct SessionJumpMenuItem: View {
    let session: AgentSession
    @ObservedObject var viewModel: MonitorViewModel
    @LocalState private var targetDescription: String? = nil

    var body: some View {
        Button {
            if session.state == .completed {
                withAnimation(.smooth) {
                    viewModel.markAsRead(id: session.id)
                }
            }
            SessionJumper.shared.jump(to: session)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Label("跳转到会话", systemImage: "arrow.up.forward.square")
                if let desc = targetDescription, !desc.isEmpty {
                    Text(desc)
                }
            }
        }
        .task {
            targetDescription = await SessionJumper.shared.describeTarget(for: session)
        }
    }
}
