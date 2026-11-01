import SwiftUI
import AppKit
import ServiceManagement
import AgentMonitorCore

// MARK: - Color Palette for Light and Dark Modes
struct Palette {
    let isDark: Bool

    static func current(isDark: Bool) -> Palette {
        Palette(isDark: isDark)
    }

    // Panel background & stroke
    var panelBg: Color {
        isDark ? Color(red: 38/255.0, green: 38/255.0, blue: 42/255.0, opacity: 0.78)
               : Color(red: 248/255.0, green: 248/255.0, blue: 250/255.0, opacity: 0.80)
    }
    var panelStroke: Color {
        isDark ? Color.white.opacity(0.14) : Color.black.opacity(0.18)
    }

    // Header
    var headerTitle: Color {
        isDark ? Color(hex: "#F5F5F7") : Color(hex: "#1D1D1F")
    }
    var headerSub: Color {
        isDark ? Color(hex: "#A1A1A6") : Color(hex: "#6E6E73")
    }

    // Stat cards: Waiting
    var cardWaitingBg: Color {
        isDark ? Color(red: 255/255.0, green: 159/255.0, blue: 10/255.0, opacity: 0.18)
               : Color(red: 255/255.0, green: 149/255.0, blue: 0/255.0, opacity: 0.16)
    }
    var cardWaitingNum: Color {
        isDark ? Color(hex: "#FFB24D") : Color(hex: "#9A3C05")
    }
    var cardWaitingLabel: Color {
        isDark ? Color(hex: "#FFC27A") : Color(hex: "#8A3604")
    }

    // Stat cards: Completed
    var cardDoneBg: Color {
        isDark ? Color(red: 48/255.0, green: 209/255.0, blue: 88/255.0, opacity: 0.16)
               : Color(red: 52/255.0, green: 199/255.0, blue: 89/255.0, opacity: 0.15)
    }
    var cardDoneNum: Color {
        isDark ? Color(hex: "#5FDC7E") : Color(hex: "#1A6E30")
    }
    var cardDoneLabel: Color {
        isDark ? Color(hex: "#8DE6A2") : Color(hex: "#1A6E30")
    }

    // Stat cards: Running
    var cardRunningBg: Color {
        isDark ? Color(red: 10/255.0, green: 132/255.0, blue: 255/255.0, opacity: 0.20)
               : Color(red: 0/255.0, green: 122/255.0, blue: 255/255.0, opacity: 0.12)
    }
    var cardRunningNum: Color {
        isDark ? Color(hex: "#6CB4FF") : Color(hex: "#0052B3")
    }
    var cardRunningLabel: Color {
        isDark ? Color(hex: "#9CCBFF") : Color(hex: "#0052B3")
    }

    // Stat cards: Idle
    var cardIdleBg: Color {
        isDark ? Color.white.opacity(0.07) : Color.black.opacity(0.05)
    }
    var cardIdleNum: Color {
        isDark ? Color(hex: "#D1D1D6") : Color(hex: "#48484A")
    }
    var cardIdleLabel: Color {
        isDark ? Color(hex: "#C7C7CC") : Color(hex: "#555558")
    }

    // Section headers
    var sectionHeader: Color {
        isDark ? Color(hex: "#A1A1A6") : Color(hex: "#636366")
    }
    var dotWaiting: Color { isDark ? Color(hex: "#FF9F0A") : Color(hex: "#F0841C") }
    var dotDone: Color { isDark ? Color(hex: "#30D158") : Color(hex: "#34C759") }
    var dotRunning: Color { Color(hex: "#0A84FF") }
    var dotIdle: Color { isDark ? Color(hex: "#636366") : Color(hex: "#AEAEB2") }

    // Session Row
    var rowTitle: Color {
        isDark ? Color(hex: "#F5F5F7") : Color(hex: "#1D1D1F")
    }
    var rowSub: Color {
        isDark ? Color(hex: "#A1A1A6") : Color(hex: "#6E6E73")
    }
    var rowHoverBg: Color {
        isDark ? Color.white.opacity(0.07) : Color.black.opacity(0.05)
    }

    // Row Time
    var timeWaiting: Color { isDark ? Color(hex: "#FFB24D") : Color(hex: "#9A3C05") }
    var timeRunning: Color { isDark ? Color(hex: "#6CB4FF") : Color(hex: "#0052B3") }
    var timeDoneOrIdle: Color { isDark ? Color(hex: "#A1A1A6") : Color(hex: "#6E6E73") }

    // Waiting Box
    var waitingBoxBg: Color {
        isDark ? Color(red: 255/255.0, green: 159/255.0, blue: 10/255.0, opacity: 0.14)
               : Color(red: 255/255.0, green: 149/255.0, blue: 0/255.0, opacity: 0.12)
    }
    var waitingBoxLabel: Color { isDark ? Color(hex: "#FFB24D") : Color(hex: "#9A3C05") }
    var waitingBoxDetail: Color { isDark ? Color(hex: "#E5E5EA") : Color(hex: "#3A3A3C") }

    // Completed Row
    var doneResultText: Color { isDark ? Color(hex: "#E5E5EA") : Color(hex: "#3A3A3C") }
    var doneCheckBg: Color { isDark ? Color(hex: "#30D158") : Color(hex: "#34C759") }
    var doneCheckCheckmark: Color { isDark ? Color(hex: "#0B2E15") : Color(hex: "#FFFFFF") }

    // Bottom divider & buttons
    var bottomDivider: Color { isDark ? Color.white.opacity(0.14) : Color.black.opacity(0.12) }
    var footText: Color { isDark ? Color(hex: "#F5F5F7") : Color(hex: "#1D1D1F") }
    var footIcon: Color { isDark ? Color(hex: "#C7C7CC") : Color(hex: "#48484A") }
    var footHoverBg: Color { isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.06) }
}

extension Color {
    init(hex: String) {
        let clean = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: clean).scanHexInt64(&int)
        let r, g, b: Double
        if clean.count == 6 {
            r = Double((int >> 16) & 0xFF) / 255.0
            g = Double((int >> 8) & 0xFF) / 255.0
            b = Double(int & 0xFF) / 255.0
        } else {
            r = 0; g = 0; b = 0
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1.0)
    }
}

public struct MenuView: View {
    @ObservedObject var viewModel: MonitorViewModel
    @Environment(\.colorScheme) var colorScheme

    public init(viewModel: MonitorViewModel) {
        self.viewModel = viewModel
    }

    /// Only set by the screenshot script; normally the panel follows the system appearance.
    private var forcedColorScheme: ColorScheme? {
        switch ProcessInfo.processInfo.environment["AGENT_MONITOR_COLOR_SCHEME"]?.lowercased() {
        case "dark": return .dark
        case "light": return .light
        default: return nil
        }
    }

    private var isDark: Bool {
        (forcedColorScheme ?? colorScheme) == .dark
    }

    private var palette: Palette {
        Palette.current(isDark: isDark)
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
        // Passing nil follows the system; forcing a value here would pin the panel to its first appearance
        .preferredColorScheme(forcedColorScheme)
    }

    // MARK: - Header
    private var headerView: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Agent 会话")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(palette.headerTitle)
            Spacer()
            let activeCount = viewModel.sessions.filter { $0.state != .idle }.count
            let agentCount = Set(viewModel.sessions.map { $0.kind }).count
            Text("\(activeCount) 个活跃 · \(agentCount) 个 agent")
                .font(.system(size: 11))
                .foregroundColor(palette.headerSub)
        }
        .padding(EdgeInsets(top: 4, leading: 6, bottom: 2, trailing: 6))
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
                bg: palette.cardWaitingBg,
                numColor: palette.cardWaitingNum,
                labelColor: palette.cardWaitingLabel
            )
            statCard(
                count: doneCount,
                label: "已完成",
                state: .completed,
                bg: palette.cardDoneBg,
                numColor: palette.cardDoneNum,
                labelColor: palette.cardDoneLabel
            )
            statCard(
                count: runningCount,
                label: "运行中",
                state: .running,
                bg: palette.cardRunningBg,
                numColor: palette.cardRunningNum,
                labelColor: palette.cardRunningLabel
            )
            statCard(
                count: idleCount,
                label: "空闲",
                state: .idle,
                bg: palette.cardIdleBg,
                numColor: palette.cardIdleNum,
                labelColor: palette.cardIdleLabel
            )
        }
        .padding(.bottom, 2)
    }

    private func statCard(
        count: Int,
        label: String,
        state: SessionState,
        bg: Color,
        numColor: Color,
        labelColor: Color
    ) -> some View {
        let isSelected = viewModel.filterState == state

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
                    .foregroundColor(numColor)
                    .lineLimit(1)
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(labelColor)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 7)
            .padding(.horizontal, 9)
            .background(isSelected ? bg.opacity(1.8) : bg)
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .stroke(isSelected ? numColor : Color.clear, lineWidth: 1.2)
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
                        sectionHeader(title: "等你回复", dotColor: palette.dotWaiting)
                        ForEach(waitingSessions) { session in
                            waitingRow(session: session)
                        }
                    }
                }

                if viewModel.filterState == nil || viewModel.filterState == .completed {
                    if !doneSessions.isEmpty {
                        sectionHeader(title: "已完成", dotColor: palette.dotDone)
                        ForEach(doneSessions) { session in
                            completedRow(session: session)
                        }
                    }
                }

                if viewModel.filterState == nil || viewModel.filterState == .running {
                    if !runningSessions.isEmpty {
                        sectionHeader(title: "运行中", dotColor: palette.dotRunning)
                        ForEach(runningSessions) { session in
                            runningRow(session: session)
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
                                    .fill(palette.dotIdle)
                                    .frame(width: 6, height: 6)
                                Text("空闲 · \(idleSessions.count) 个会话")
                                    .font(.system(size: 12))
                                    .foregroundColor(palette.sectionHeader)
                                Spacer()
                                Image(systemName: viewModel.isIdleExpanded ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(palette.sectionHeader)
                            }
                            .padding(8)
                            .background(viewModel.hoveredSessionId == "idle-header" ? palette.rowHoverBg : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 9))
                        }
                        .buttonStyle(.plain)
                        .onHover { isHover in
                            viewModel.hoveredSessionId = isHover ? "idle-header" : nil
                        }

                        if viewModel.isIdleExpanded || viewModel.filterState == .idle {
                            ForEach(idleSessions) { session in
                                idleRow(session: session)
                            }
                        }
                    }
                }

                if viewModel.sessions.isEmpty {
                    VStack(spacing: 4) {
                        Text("暂无活跃会话")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(palette.headerSub)
                        Text("各 agent 启动后将在此处自动汇总")
                            .font(.system(size: 11))
                            .foregroundColor(palette.headerSub.opacity(0.8))
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
                .foregroundColor(palette.sectionHeader)
        }
        .padding(EdgeInsets(top: 6, leading: 8, bottom: 0, trailing: 8))
    }

    // MARK: - Waiting Row
    private func waitingRow(session: AgentSession) -> some View {
        let isHovered = viewModel.hoveredSessionId == session.id

        return Button(action: {
            viewModel.markAsRead(id: session.id)
            activateApp(for: session.kind, entrypoint: session.entrypoint, cwd: session.cwd)
        }) {
            HStack(alignment: .top, spacing: 10) {
                Image(nsImage: IconManager.shared.icon(for: session.kind, isDark: isDark))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 34, height: 34)
                    .padding(-2)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(NotificationFormatter.cleanTitle(session.title))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(palette.rowTitle)
                            .lineLimit(1)
                        Spacer()
                        Text(formattedTime(session: session))
                            .font(.system(size: 11, weight: .medium))
                            .monospacedDigit()
                            .foregroundColor(palette.timeWaiting)
                    }

                    let cwdPart = session.cwd.map { ($0 as NSString).lastPathComponent } ?? ""
                    let sub = cwdPart.isEmpty ? session.kind.displayName : "\(session.kind.displayName) · \(cwdPart)"
                    Text(sub)
                        .font(.system(size: 11))
                        .foregroundColor(palette.rowSub)
                        .lineLimit(1)

                    HStack(spacing: 7) {
                        Text(session.waitingLabel ?? "等待授权")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundColor(palette.waitingBoxLabel)
                            .fixedSize()
                        if let detail = session.detail {
                            Text(detail)
                                .font(session.detailIsCommand ? .system(size: 11.5, design: .monospaced) : .system(size: 11.5))
                                .foregroundColor(palette.waitingBoxDetail)
                                .lineLimit(1)
                        }
                    }
                    .padding(.vertical, 5)
                    .padding(.horizontal, 8)
                    .background(palette.waitingBoxBg)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .padding(.top, 4)
                }
            }
            .padding(8)
            .background(isHovered ? palette.rowHoverBg : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .onHover { isHover in
            viewModel.hoveredSessionId = isHover ? session.id : nil
        }
    }

    // MARK: - Completed Row
    private func completedRow(session: AgentSession) -> some View {
        let isHovered = viewModel.hoveredSessionId == session.id

        return Button(action: {
            viewModel.markAsRead(id: session.id)
            activateApp(for: session.kind, entrypoint: session.entrypoint, cwd: session.cwd)
        }) {
            HStack(alignment: .top, spacing: 10) {
                Image(nsImage: IconManager.shared.icon(for: session.kind, isDark: isDark))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 34, height: 34)
                    .padding(-2)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(NotificationFormatter.cleanTitle(session.title))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(palette.rowTitle)
                            .lineLimit(1)
                        Spacer()
                        Text(formattedTime(session: session))
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .foregroundColor(palette.timeDoneOrIdle)
                    }

                    let cwdPart = session.cwd.map { ($0 as NSString).lastPathComponent } ?? ""
                    let sub = cwdPart.isEmpty ? session.kind.displayName : "\(session.kind.displayName) · \(cwdPart)"
                    Text(sub)
                        .font(.system(size: 11))
                        .foregroundColor(palette.rowSub)
                        .lineLimit(1)

                    if let detail = session.detail {
                        HStack(spacing: 6) {
                            ZStack {
                                Circle()
                                    .fill(palette.doneCheckBg)
                                    .frame(width: 12, height: 12)
                                Image(systemName: "checkmark")
                                    .font(.system(size: 7, weight: .bold))
                                    .foregroundColor(palette.doneCheckCheckmark)
                            }
                            Text(detail)
                                .font(.system(size: 11.5))
                                .foregroundColor(palette.doneResultText)
                                .lineLimit(1)
                        }
                        .padding(.top, 2)
                    }
                }
            }
            .padding(8)
            .background(isHovered ? palette.rowHoverBg : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .onHover { isHover in
            viewModel.hoveredSessionId = isHover ? session.id : nil
        }
    }

    // MARK: - Running Row
    private func runningRow(session: AgentSession) -> some View {
        let isHovered = viewModel.hoveredSessionId == session.id

        return Button(action: {
            viewModel.markAsRead(id: session.id)
            activateApp(for: session.kind, entrypoint: session.entrypoint, cwd: session.cwd)
        }) {
            HStack(alignment: .center, spacing: 10) {
                Image(nsImage: IconManager.shared.icon(for: session.kind, isDark: isDark))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 34, height: 34)
                    .padding(-2)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(NotificationFormatter.cleanTitle(session.title))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(palette.rowTitle)
                            .lineLimit(1)
                        Spacer()
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let elapsed = max(0, Int(context.date.timeIntervalSince(session.stateSince)))
                            let m = elapsed / 60
                            let s = elapsed % 60
                            Text(String(format: "%d:%02d", m, s))
                                .font(.system(size: 11))
                                .monospacedDigit()
                                .foregroundColor(palette.timeRunning)
                        }
                    }

                    HStack(spacing: 6) {
                        PulsingDotView()
                        Text(session.detail ?? "正在思考…")
                            .font(.system(size: 11))
                            .foregroundColor(palette.rowSub)
                            .lineLimit(1)
                    }
                }
            }
            .padding(EdgeInsets(top: 7, leading: 8, bottom: 7, trailing: 8))
            .background(isHovered ? palette.rowHoverBg : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .onHover { isHover in
            viewModel.hoveredSessionId = isHover ? session.id : nil
        }
    }

    // MARK: - Idle Row
    private func idleRow(session: AgentSession) -> some View {
        let isHovered = viewModel.hoveredSessionId == session.id

        return Button(action: {
            viewModel.markAsRead(id: session.id)
            activateApp(for: session.kind, entrypoint: session.entrypoint, cwd: session.cwd)
        }) {
            HStack(alignment: .top, spacing: 10) {
                Image(nsImage: IconManager.shared.icon(for: session.kind, isDark: isDark))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 34, height: 34)
                    .padding(-2)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(NotificationFormatter.cleanTitle(session.title))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(palette.rowTitle)
                            .lineLimit(1)
                        Spacer()
                        Text(formattedTime(session: session))
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .foregroundColor(palette.timeDoneOrIdle)
                    }

                    let cwdPart = session.cwd.map { ($0 as NSString).lastPathComponent } ?? ""
                    let sub = cwdPart.isEmpty ? session.kind.displayName : "\(session.kind.displayName) · \(cwdPart)"
                    Text(sub)
                        .font(.system(size: 11))
                        .foregroundColor(palette.rowSub)
                        .lineLimit(1)
                }
            }
            .padding(8)
            .background(isHovered ? palette.rowHoverBg : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .onHover { isHover in
            viewModel.hoveredSessionId = isHover ? session.id : nil
        }
    }

    private func formattedTime(session: AgentSession) -> String {
        switch session.state {
        case .running:
            let elapsed = max(0, Int(Date().timeIntervalSince(session.stateSince)))
            let m = elapsed / 60
            let s = elapsed % 60
            return String(format: "%d:%02d", m, s)
        case .waitingForUser:
            let diff = max(0, Int(Date().timeIntervalSince(session.stateSince)))
            let m = diff / 60
            if m < 1 {
                return "刚刚"
            } else if m < 60 {
                return "\(m) 分钟"
            } else {
                let h = m / 60
                return "\(h) 小时"
            }
        case .completed, .idle:
            let diff = max(0, Int(Date().timeIntervalSince(session.lastActivity)))
            let m = diff / 60
            if m < 1 {
                return "刚刚"
            } else if m < 60 {
                return "\(m) 分钟前"
            } else {
                let h = m / 60
                return "\(h) 小时前"
            }
        }
    }

    // MARK: - Bottom Bar
    private var bottomBarView: some View {
        VStack(spacing: 2) {
            Rectangle()
                .fill(palette.bottomDivider)
                .frame(height: 0.5)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)

            HStack(spacing: 2) {
                Button("全部标为已读") {
                    viewModel.markAllAsRead()
                }
                .font(.system(size: 12))
                .foregroundColor(palette.footText)
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(viewModel.hoveredSessionId == "mark-all" ? palette.footHoverBg : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .onHover { isHover in
                    viewModel.hoveredSessionId = isHover ? "mark-all" : nil
                }

                Spacer()

                // Pause notifications toggle
                Button(action: {
                    viewModel.togglePauseNotifications()
                }) {
                    Image(systemName: viewModel.isNotificationsPaused ? "bell.slash.fill" : "bell")
                        .font(.system(size: 14))
                        .foregroundColor(viewModel.isNotificationsPaused ? Color(hex: "#F0841C") : palette.footIcon)
                        .frame(width: 30, height: 28)
                        .background(viewModel.hoveredSessionId == "bell" ? palette.footHoverBg : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
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
                        .font(.system(size: 14))
                        .foregroundColor(palette.footIcon)
                        .frame(width: 30, height: 28)
                        .background(viewModel.hoveredSessionId == "settings" ? palette.footHoverBg : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 30, height: 28)
                .onHover { isHover in
                    viewModel.hoveredSessionId = isHover ? "settings" : nil
                }
            }
        }
    }
}

// MARK: - Pulsing Dot View (1.8s pulse ring animation)
struct PulsingDotView: View {
    var body: some View {
        PhaseAnimator([false, true]) { isPulsing in
            ZStack {
                Circle()
                    .stroke(Color(hex: "#0A84FF").opacity(isPulsing ? 0 : 0.6), lineWidth: 1.5)
                    .frame(width: 6, height: 6)
                    .scaleEffect(isPulsing ? 2.6 : 1.0)
                Circle()
                    .fill(Color(hex: "#0A84FF"))
                    .frame(width: 6, height: 6)
            }
        } animation: { _ in
            .easeOut(duration: 1.8)
        }
    }
}
