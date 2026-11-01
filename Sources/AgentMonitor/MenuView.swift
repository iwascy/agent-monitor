import SwiftUI
import AppKit
import ServiceManagement
import AgentMonitorCore

public struct MenuView: View {
    @ObservedObject var viewModel: MonitorViewModel
    @Environment(\.colorScheme) var colorScheme

    public init(viewModel: MonitorViewModel) {
        self.viewModel = viewModel
    }

    private var isDark: Bool {
        colorScheme == .dark
    }

    public var body: some View {
        VStack(spacing: 6) {
            headerView
            statCardsView
            sessionListView
            bottomBarView
        }
        .padding(10)
        .frame(width: 384)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.12), lineWidth: 0.5)
        )
    }

    // MARK: - Header
    private var headerView: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Agent 会话")
                .font(.system(size: 14, weight: .bold))
            Spacer()
            let activeCount = viewModel.sessions.filter { $0.state != .idle }.count
            let agentCount = Set(viewModel.sessions.map { $0.kind }).count
            Text("\(activeCount) 个活跃 · \(agentCount) 个 agent")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 6)
        .padding(.top, 4)
    }

    // MARK: - Stat Cards
    private var statCardsView: some View {
        let waitingCount = viewModel.sessions.filter { $0.state == .waitingForUser }.count
        let doneCount = viewModel.sessions.filter { $0.state == .completed }.count
        let runningCount = viewModel.sessions.filter { $0.state == .running }.count
        let idleCount = viewModel.sessions.filter { $0.state == .idle }.count

        return HStack(spacing: 6) {
            statCard(
                count: waitingCount,
                label: "等你",
                state: .waitingForUser,
                lightBg: Color(red: 1.0, green: 0.58, blue: 0.0, opacity: 0.14),
                darkBg: Color(red: 1.0, green: 0.62, blue: 0.04, opacity: 0.20),
                lightText: Color(red: 0.60, green: 0.24, blue: 0.02),
                darkText: Color(red: 1.0, green: 0.70, blue: 0.30)
            )
            statCard(
                count: doneCount,
                label: "已完成",
                state: .completed,
                lightBg: Color(red: 0.20, green: 0.78, blue: 0.35, opacity: 0.14),
                darkBg: Color(red: 0.19, green: 0.82, blue: 0.35, opacity: 0.18),
                lightText: Color(red: 0.14, green: 0.54, blue: 0.24),
                darkText: Color(red: 0.37, green: 0.86, blue: 0.49)
            )
            statCard(
                count: runningCount,
                label: "运行中",
                state: .running,
                lightBg: Color(red: 0.04, green: 0.52, blue: 1.0, opacity: 0.14),
                darkBg: Color(red: 0.04, green: 0.52, blue: 1.0, opacity: 0.20),
                lightText: Color(red: 0.0, green: 0.32, blue: 0.70),
                darkText: Color(red: 0.44, green: 0.71, blue: 1.0)
            )
            statCard(
                count: idleCount,
                label: "空闲",
                state: .idle,
                lightBg: Color(white: 0.55, opacity: 0.14),
                darkBg: Color(white: 0.60, opacity: 0.18),
                lightText: Color(white: 0.30),
                darkText: Color(white: 0.78)
            )
        }
        .padding(.bottom, 2)
    }

    private func statCard(
        count: Int,
        label: String,
        state: SessionState,
        lightBg: Color,
        darkBg: Color,
        lightText: Color,
        darkText: Color
    ) -> some View {
        let isSelected = viewModel.filterState == state
        let bg = isDark ? darkBg : lightBg
        let text = isDark ? darkText : lightText

        return Button(action: {
            if viewModel.filterState == state {
                viewModel.filterState = nil
            } else {
                viewModel.filterState = state
            }
        }) {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(count)")
                    .font(.system(size: 18, weight: .bold, design: .default))
                    .monospacedDigit()
                    .foregroundColor(text)
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(text.opacity(0.85))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 7)
            .padding(.horizontal, 9)
            .background(isSelected ? bg.opacity(1.8) : bg)
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .stroke(isSelected ? text : Color.clear, lineWidth: 1.2)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Session List
    private var sessionListView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                let waitingSessions = viewModel.sessions.filter { $0.state == .waitingForUser }
                let doneSessions = viewModel.sessions.filter { $0.state == .completed }
                let runningSessions = viewModel.sessions.filter { $0.state == .running }
                let idleSessions = viewModel.sessions.filter { $0.state == .idle }

                if viewModel.filterState == nil || viewModel.filterState == .waitingForUser {
                    if !waitingSessions.isEmpty {
                        sectionHeader(title: "等你回复", color: Color(red: 0.94, green: 0.52, blue: 0.11))
                        ForEach(waitingSessions) { session in
                            sessionRow(session: session)
                        }
                    }
                }

                if viewModel.filterState == nil || viewModel.filterState == .completed {
                    if !doneSessions.isEmpty {
                        sectionHeader(title: "已完成", color: Color(red: 0.20, green: 0.78, blue: 0.35))
                        ForEach(doneSessions) { session in
                            sessionRow(session: session)
                        }
                    }
                }

                if viewModel.filterState == nil || viewModel.filterState == .running {
                    if !runningSessions.isEmpty {
                        sectionHeader(title: "运行中", color: Color(red: 0.04, green: 0.52, blue: 1.0))
                        ForEach(runningSessions) { session in
                            sessionRow(session: session)
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
                                    .fill(Color(white: 0.68))
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
                            .background(viewModel.hoveredSessionId == "idle-header" ? Color.primary.opacity(0.05) : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 9))
                        }
                        .buttonStyle(.plain)
                        .onHover { isHover in
                            viewModel.hoveredSessionId = isHover ? "idle-header" : nil
                        }

                        if viewModel.isIdleExpanded || viewModel.filterState == .idle {
                            ForEach(idleSessions) { session in
                                sessionRow(session: session)
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
        }
        .frame(maxHeight: 460)
    }

    private func sectionHeader(title: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
    }

    // MARK: - Session Row
    private func sessionRow(session: AgentSession) -> some View {
        let isHovered = viewModel.hoveredSessionId == session.id

        return Button(action: {
            viewModel.markAsRead(id: session.id)
            activateApp(for: session.kind, cwd: session.cwd)
        }) {
            HStack(alignment: .top, spacing: 10) {
                // Agent icon (30pt)
                Image(nsImage: IconManager.shared.icon(for: session.kind, isDark: isDark))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 2) {
                    // Title and time
                    HStack(alignment: .firstTextBaseline) {
                        Text(session.title)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Spacer()
                        if session.state == .running {
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                let elapsed = max(0, Int(context.date.timeIntervalSince(session.stateSince)))
                                let m = elapsed / 60
                                let s = elapsed % 60
                                Text(String(format: "%d:%02d", m, s))
                                    .font(.system(size: 11))
                                    .monospacedDigit()
                                    .foregroundColor(Color(red: 0.04, green: 0.52, blue: 1.0))
                            }
                        } else {
                            Text(formattedTime(since: session.lastActivity, state: session.state))
                                .font(.system(size: 11))
                                .monospacedDigit()
                                .foregroundColor(timeColor(for: session.state))
                        }
                    }

                    // Agent name · cwd
                    let cwdPart = session.cwd.map { ($0 as NSString).lastPathComponent } ?? ""
                    let subtitle = cwdPart.isEmpty ? session.kind.displayName : "\(session.kind.displayName) · \(cwdPart)"

                    if session.state == .running {
                        HStack(spacing: 6) {
                            PulsingDotView()
                            Text(session.detail ?? "正在思考…")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    } else {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }

                    // State details
                    if session.state == .waitingForUser {
                        HStack(spacing: 7) {
                            Text(session.waitingLabel ?? "等待授权")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundColor(Color(red: 0.60, green: 0.24, blue: 0.02))
                            if let detail = session.detail {
                                Text(detail)
                                    .font(session.detailIsCommand ? .system(size: 11, design: .monospaced) : .system(size: 11.5))
                                    .foregroundColor(Color.primary.opacity(0.85))
                                    .lineLimit(1)
                            }
                        }
                        .padding(.vertical, 5)
                        .padding(.horizontal, 8)
                        .background(Color(red: 1.0, green: 0.58, blue: 0.0, opacity: 0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .padding(.top, 2)
                    } else if session.state == .completed {
                        if let detail = session.detail {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(Color(red: 0.20, green: 0.78, blue: 0.35))
                                    .font(.system(size: 12))
                                Text(detail)
                                    .font(.system(size: 11.5))
                                    .foregroundColor(.primary.opacity(0.85))
                                    .lineLimit(1)
                            }
                            .padding(.top, 2)
                        }
                    }
                }
            }
            .padding(8)
            .background(isHovered ? Color.primary.opacity(0.05) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .onHover { isHover in
            viewModel.hoveredSessionId = isHover ? session.id : nil
        }
    }

    private func timeColor(for state: SessionState) -> Color {
        switch state {
        case .waitingForUser:
            return Color(red: 0.94, green: 0.52, blue: 0.11)
        case .running:
            return Color(red: 0.04, green: 0.52, blue: 1.0)
        case .completed, .idle:
            return .secondary
        }
    }

    private func formattedTime(since: Date, state: SessionState) -> String {
        let diff = max(0, Int(Date().timeIntervalSince(since)))
        if state == .running {
            let m = diff / 60
            let s = diff % 60
            return String(format: "%d:%02d", m, s)
        } else {
            let m = diff / 60
            if m < 1 {
                return "刚刚"
            } else if m < 60 {
                return "\(m) 分钟"
            } else {
                let h = m / 60
                return "\(h) 小时"
            }
        }
    }

    // MARK: - Bottom Bar
    private var bottomBarView: some View {
        VStack(spacing: 4) {
            Divider()
                .opacity(0.5)

            HStack {
                Button("全部标为已读") {
                    viewModel.markAllAsRead()
                }
                .font(.system(size: 12))
                .buttonStyle(.plain)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(viewModel.hoveredSessionId == "mark-all" ? Color.primary.opacity(0.06) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .onHover { isHover in
                    viewModel.hoveredSessionId = isHover ? "mark-all" : nil
                }

                Spacer()

                // Pause notifications toggle
                Button(action: {
                    viewModel.togglePauseNotifications()
                }) {
                    Image(systemName: viewModel.isNotificationsPaused ? "bell.slash.fill" : "bell")
                        .font(.system(size: 13))
                        .foregroundColor(viewModel.isNotificationsPaused ? .orange : .secondary)
                        .frame(width: 28, height: 26)
                        .background(viewModel.hoveredSessionId == "bell" ? Color.primary.opacity(0.06) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help(viewModel.isNotificationsPaused ? "恢复通知" : "暂停通知 1 小时")
                .onHover { isHover in
                    viewModel.hoveredSessionId = isHover ? "bell" : nil
                }

                // Settings Menu
                Menu {
                    Toggle("开机启动", isOn: Binding(
                        get: { viewModel.isLaunchAtLogin },
                        set: { viewModel.setLaunchAtLogin($0) }
                    ))
                    Divider()
                    Button("退出 Agent Monitor") {
                        NSApplication.shared.terminate(nil)
                    }
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .frame(width: 28, height: 26)
                        .background(viewModel.hoveredSessionId == "settings" ? Color.primary.opacity(0.06) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 28, height: 26)
                .onHover { isHover in
                    viewModel.hoveredSessionId = isHover ? "settings" : nil
                }
            }
        }
        .padding(.horizontal, 2)
    }
}

// MARK: - Pulsing Dot View
struct PulsingDotView: View {
    var body: some View {
        PhaseAnimator([false, true]) { isPulsing in
            ZStack {
                Circle()
                    .fill(Color(red: 0.04, green: 0.52, blue: 1.0).opacity(0.4))
                    .frame(width: 10, height: 10)
                    .scaleEffect(isPulsing ? 1.4 : 0.8)
                    .opacity(isPulsing ? 0 : 0.6)
                Circle()
                    .fill(Color(red: 0.04, green: 0.52, blue: 1.0))
                    .frame(width: 6, height: 6)
            }
        } animation: { _ in
            .easeInOut(duration: 1.2)
        }
    }
}
