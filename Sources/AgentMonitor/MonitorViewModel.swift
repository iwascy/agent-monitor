import Foundation
import SwiftUI
import ServiceManagement
import AgentMonitorCore

@MainActor
public final class MonitorViewModel: ObservableObject {
    @Published public private(set) var sessions: [AgentSession] = [] {
        didSet {
            autoClearEmptyFilter()
        }
    }
    @Published public private(set) var isNotificationsPaused: Bool = false
    @Published public private(set) var isLaunchAtLogin: Bool = false

    @Published public var isIdleExpanded: Bool = false
    @Published public var filterState: SessionState? = nil

    /// Returns true if the active filter has 0 matching sessions and should be cleared.
    public static func shouldClearFilter(currentFilter: SessionState?, sessions: [AgentSession]) -> Bool {
        guard let filter = currentFilter else { return false }
        return !sessions.contains(where: { $0.state == filter })
    }

    public func autoClearEmptyFilter() {
        if Self.shouldClearFilter(currentFilter: filterState, sessions: sessions) {
            withAnimation(.bouncy) {
                filterState = nil
            }
        }
    }

    private let sessionStore: SessionStore
    private let notifier = Notifier.shared
    private var pauseExpiryTimer: DispatchSourceTimer?

    public var highestState: SessionState? {
        if sessions.contains(where: { $0.state == .waitingForUser }) {
            return .waitingForUser
        }
        if sessions.contains(where: { $0.state == .completed }) {
            return .completed
        }
        if sessions.contains(where: { $0.state == .running }) {
            return .running
        }
        return nil
    }

    public var waitingCount: Int {
        sessions.filter { $0.state == .waitingForUser }.count
    }

    public var effectiveMenuState: (highestState: SessionState?, waitingCount: Int, isPaused: Bool) {
        if let env = ProcessInfo.processInfo.environment["AGENT_MONITOR_MENU_STATE"]?.lowercased() {
            switch env {
            case "idle":
                return (highestState: nil, waitingCount: 0, isPaused: false)
            case "running":
                return (highestState: .running, waitingCount: 0, isPaused: false)
            case "completed":
                return (highestState: .completed, waitingCount: 0, isPaused: false)
            case "waiting":
                return (highestState: .waitingForUser, waitingCount: 2, isPaused: false)
            case "paused":
                return (highestState: .waitingForUser, waitingCount: 0, isPaused: true)
            default:
                break
            }
        }
        return (highestState: highestState, waitingCount: waitingCount, isPaused: isNotificationsPaused)
    }

    public init(sessionStore: SessionStore) {
        self.sessionStore = sessionStore
        self.isLaunchAtLogin = SMAppService.mainApp.status == .enabled

        let env = ProcessInfo.processInfo.environment
        if let filter = env["AGENT_MONITOR_FILTER"]?.lowercased() {
            switch filter {
            case "waiting":
                self.filterState = .waitingForUser
            case "completed":
                self.filterState = .completed
            case "running":
                self.filterState = .running
            case "idle":
                self.filterState = .idle
            default:
                break
            }
        }

        if env["AGENT_MONITOR_IDLE_EXPANDED"] == "1" {
            self.isIdleExpanded = true
        }

        if let mock = env["AGENT_MONITOR_MOCK_DATA"] {
            if mock.lowercased() == "empty" {
                self.sessions = []
            } else if mock.lowercased() == "large" {
                self.sessions = MonitorViewModel.mockSessionsLarge()
            } else {
                self.sessions = MonitorViewModel.mockSessions()
            }
            updatePauseState()
            return
        }

        sessionStore.onSessionsUpdated = { [weak self] updated in
            Task { @MainActor in
                self?.sessions = updated
                self?.checkPauseExpiry()
            }
        }

        sessionStore.onTransition = { [weak self] transition in
            Task { @MainActor in
                self?.notifier.notify(transition: transition)
            }
        }

        notifier.onNotificationClicked = { [weak self] sessionId in
            Task { @MainActor in
                self?.markAsRead(id: sessionId)
            }
        }

        updatePauseState()
        sessionStore.start()
    }

    public static func mockSessions() -> [AgentSession] {
        let now = Date()
        return [
            AgentSession(
                id: "cx:mock-1",
                kind: .codex,
                title: "重构 Cookie 同步逻辑",
                cwd: "/Users/cy/code/115-cookie",
                state: .waitingForUser,
                stateSince: now.addingTimeInterval(-240),
                lastActivity: now.addingTimeInterval(-240),
                detail: "git push --force origin main",
                detailIsCommand: true,
                waitingLabel: "等待授权"
            ),
            AgentSession(
                id: "cc:mock-2",
                kind: .claudeCode,
                title: "多 agent 会话监控面板",
                cwd: "/Users/cy/code/agent-monitor",
                state: .waitingForUser,
                stateSince: now.addingTimeInterval(-60),
                lastActivity: now.addingTimeInterval(-60),
                detail: "第一版做成哪种形态？",
                detailIsCommand: false,
                waitingLabel: "在问你"
            ),
            AgentSession(
                id: "ag:mock-3",
                kind: .antigravity,
                title: "Loon 规则整理",
                cwd: "/Users/cy/code/loon-rea",
                state: .completed,
                stateSince: now.addingTimeInterval(-720),
                lastActivity: now.addingTimeInterval(-720),
                detail: "已生成 3 个文件，测试全部通过",
                completedDuration: 372
            ),
            AgentSession(
                id: "ds:mock-4",
                kind: .dsh,
                title: "iStat Menus 显示模块分析",
                cwd: "/Users/cy/code/istat-menus-rea",
                state: .running,
                stateSince: now.addingTimeInterval(-151),
                lastActivity: now.addingTimeInterval(-151),
                detail: "正在运行 Bash · pnpm test"
            ),
            AgentSession(
                id: "cc:mock-5",
                kind: .claudeCode,
                title: "Hyperknow 学习要点",
                cwd: "/Users/cy/code/ai-plan-pilot",
                state: .running,
                stateSince: now.addingTimeInterval(-48),
                lastActivity: now.addingTimeInterval(-48),
                detail: "正在思考…"
            ),
            AgentSession(
                id: "cx:mock-6",
                kind: .codex,
                title: "历史归档",
                cwd: "/Users/cy/code/archive",
                state: .idle,
                lastActivity: now.addingTimeInterval(-7200),
                detail: "已归档"
            ),
            AgentSession(
                id: "ag:mock-7",
                kind: .antigravity,
                title: "环境探测",
                cwd: "/Users/cy/code/probe",
                state: .idle,
                lastActivity: now.addingTimeInterval(-10800),
                detail: "探测完成"
            )
        ]
    }

    public static func mockSessionsLarge() -> [AgentSession] {
        var list = mockSessions()
        let now = Date()
        let extra: [AgentSession] = [
            AgentSession(
                id: "cx:mock-8",
                kind: .codex,
                title: "修复 SQL 注入漏洞",
                cwd: "/Users/cy/code/backend-api",
                state: .waitingForUser,
                stateSince: now.addingTimeInterval(-180),
                lastActivity: now.addingTimeInterval(-180),
                detail: "cargo test --release",
                detailIsCommand: true,
                waitingLabel: "等待授权"
            ),
            AgentSession(
                id: "cc:mock-9",
                kind: .claudeCode,
                title: "编写用户注册流程文档",
                cwd: "/Users/cy/code/docs-site",
                state: .completed,
                stateSince: now.addingTimeInterval(-1200),
                lastActivity: now.addingTimeInterval(-1200),
                detail: "已更新 docs/auth.md 并校对完成",
                completedDuration: 184
            ),
            AgentSession(
                id: "ds:mock-10",
                kind: .dsh,
                title: "分析内核崩溃转储",
                cwd: "/Users/cy/code/kernel-debug",
                state: .running,
                stateSince: now.addingTimeInterval(-310),
                lastActivity: now.addingTimeInterval(-310),
                detail: "正在反编译 mach_kernel"
            ),
            AgentSession(
                id: "ag:mock-11",
                kind: .antigravity,
                title: "重构样式与微调动效",
                cwd: "/Users/cy/code/agent-monitor",
                state: .running,
                stateSince: now.addingTimeInterval(-15),
                lastActivity: now.addingTimeInterval(-15),
                detail: "正在运行 swift test…"
            ),
            AgentSession(
                id: "cx:mock-12",
                kind: .codex,
                title: "迁移 Redis 缓存集群",
                cwd: "/Users/cy/code/infra-tools",
                state: .waitingForUser,
                stateSince: now.addingTimeInterval(-600),
                lastActivity: now.addingTimeInterval(-600),
                detail: "确认切换生产流量至主节点？",
                detailIsCommand: false,
                waitingLabel: "在问你"
            ),
            AgentSession(
                id: "cc:mock-13",
                kind: .claudeCode,
                title: "优化 Webpack 打包耗时",
                cwd: "/Users/cy/code/web-dashboard",
                state: .completed,
                stateSince: now.addingTimeInterval(-1800),
                lastActivity: now.addingTimeInterval(-1800),
                detail: "构建时间由 48s 降低至 14s",
                completedDuration: 520
            ),
            AgentSession(
                id: "ds:mock-14",
                kind: .dsh,
                title: "LLM 输出评测脚本",
                cwd: "/Users/cy/code/eval-tools",
                state: .idle,
                lastActivity: now.addingTimeInterval(-14400),
                detail: "评测完成"
            ),
            AgentSession(
                id: "ag:mock-15",
                kind: .antigravity,
                title: "配置 CI 自动化任务",
                cwd: "/Users/cy/code/ci-scripts",
                state: .idle,
                lastActivity: now.addingTimeInterval(-21600),
                detail: "流水线配置成功"
            )
        ]
        list.append(contentsOf: extra)
        return list
    }

    public func markAsRead(id: String) {
        sessionStore.markAsRead(id: id)
        sessions = sessionStore.currentSessions
    }

    public func markAllAsRead() {
        sessionStore.markAllAsRead()
        sessions = sessionStore.currentSessions
    }

    public func togglePauseNotifications() {
        notifier.togglePause(hours: 1.0)
        updatePauseState()
    }

    private func checkPauseExpiry() {
        if isNotificationsPaused && !notifier.isPaused {
            updatePauseState()
        }
    }

    private func updatePauseState() {
        isNotificationsPaused = notifier.isPaused
        pauseExpiryTimer?.cancel()
        pauseExpiryTimer = nil

        if let until = notifier.pauseUntil {
            let delay = max(0.1, until.timeIntervalSinceNow)
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + delay)
            timer.setEventHandler { [weak self] in
                self?.isNotificationsPaused = self?.notifier.isPaused ?? false
                self?.pauseExpiryTimer?.cancel()
                self?.pauseExpiryTimer = nil
            }
            timer.resume()
            self.pauseExpiryTimer = timer
        }
    }

    public func setLaunchAtLogin(_ enable: Bool) {
        do {
            if enable {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            isLaunchAtLogin = SMAppService.mainApp.status == .enabled
        } catch {
            NSLog("Failed to update launch at login: %@", error.localizedDescription)
            isLaunchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
