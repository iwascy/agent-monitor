import Foundation
import SwiftUI
import Combine
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
    @Published public var filterState: SessionState? = nil {
        didSet {
            if let sel = keyboardSelectionID, !visibleSessionIDs.contains(sel) {
                keyboardSelectionID = nil
            }
        }
    }
    @Published public var keyboardSelectionID: String? = nil
    @Published public var hasOverdue: Bool = false

    @Published public private(set) var expandedSubagentIDs: Set<String> = []

    // Ignore broken/cyclic links so malformed metadata cannot hide sessions or recurse forever.
    private func parentID(of session: AgentSession) -> String? {
        let byID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        var visited: Set<String> = [session.id]
        var parent = session.parentSessionID
        while let id = parent, let ancestor = byID[id] {
            guard visited.insert(id).inserted else { return nil }
            parent = ancestor.parentSessionID
        }
        return session.parentSessionID.flatMap { byID[$0] == nil ? nil : $0 }
    }

    public var rootSessions: [AgentSession] {
        sessions.filter { parentID(of: $0) == nil }
    }

    public func childSessions(of id: String) -> [AgentSession] {
        sessions.filter { parentID(of: $0) == id }
    }

    public func subtree(of session: AgentSession, expandedOnly: Bool = true) -> [AgentSession] {
        guard !expandedOnly || expandedSubagentIDs.contains(session.id) else { return [session] }
        return [session] + childSessions(of: session.id).flatMap { subtree(of: $0, expandedOnly: expandedOnly) }
    }

    public func roots(in state: SessionState) -> [AgentSession] {
        rootSessions.filter { root in
            if filterState == state {
                return subtree(of: root, expandedOnly: false).contains { $0.state == state }
            }
            return root.state == state
        }
    }

    public func depth(of session: AgentSession) -> Int {
        guard let id = parentID(of: session), let parent = sessions.first(where: { $0.id == id }) else { return 0 }
        return 1 + depth(of: parent)
    }

    public func toggleSubagents(of id: String) {
        if !expandedSubagentIDs.insert(id).inserted { expandedSubagentIDs.remove(id) }
        if let selected = keyboardSelectionID, !visibleSessionIDs.contains(selected) {
            keyboardSelectionID = nil
        }
    }

    /// Keyboard navigation uses the same expanded hierarchy and order as the panel.
    public var visibleSessions: [AgentSession] {
        [.waitingForUser, .completed, .running, .idle].flatMap { (state: SessionState) -> [AgentSession] in
            guard filterState == nil || filterState == state else { return [] }
            guard state != .idle || isIdleExpanded || filterState == .idle else { return [] }
            return roots(in: state).flatMap { subtree(of: $0) }
        }
    }

    /// Returns the session IDs currently visible in the panel.
    public var visibleSessionIDs: [String] {
        visibleSessions.map(\.id)
    }

    /// Returns true if the active filter has 0 matching sessions and should be cleared.
    public static func shouldClearFilter(currentFilter: SessionState?, sessions: [AgentSession]) -> Bool {
        guard let filter = currentFilter else { return false }
        return !sessions.contains(where: { $0.state == filter })
    }

    /// Returns true if the "Mark all as read" button should be displayed given current sessions and filter.
    public static func shouldShowMarkAllAsRead(sessions: [AgentSession], filterState: SessionState?) -> Bool {
        sessions.contains(where: { $0.state == .completed }) &&
        (filterState == nil || filterState == .completed)
    }

    public var showBottomButton: Bool {
        Self.shouldShowMarkAllAsRead(sessions: sessions, filterState: filterState)
    }

    public func autoClearEmptyFilter() {
        if Self.shouldClearFilter(currentFilter: filterState, sessions: sessions) {
            withAnimation(.bouncy) {
                filterState = nil
            }
        }
    }

    public let sessionStore: SessionStore
    public let reminderScheduler: ReminderScheduler = ReminderScheduler()
    private let notifier = Notifier.shared
    private var rawSessions: [AgentSession] = []
    private var pauseExpiryTimer: DispatchSourceTimer?
    private var reminderTimer: DispatchSourceTimer?
    private var cancellables = Set<AnyCancellable>()

    public var highestState: SessionState? {
        let active = sessions
        let waitingActive = active.filter { s in
            if let rule = MuteRule.matchingRule(for: s.cwd, rules: AppSettings.shared.muteRules), rule.scope == .all {
                return false
            }
            return true
        }
        if waitingActive.contains(where: { $0.state == .waitingForUser }) {
            return .waitingForUser
        }
        if active.contains(where: { $0.state == .completed }) {
            return .completed
        }
        if active.contains(where: { $0.state == .running }) {
            return .running
        }
        return nil
    }

    public var waitingCount: Int {
        sessions.filter { s in
            guard s.state == .waitingForUser else { return false }
            if let rule = MuteRule.matchingRule(for: s.cwd, rules: AppSettings.shared.muteRules), rule.scope == .all {
                return false
            }
            return true
        }.count
    }

    public func recalculateOverdue(now: Date = Date()) {
        let settings = AppSettings.shared
        guard settings.remindEnabled else {
            if hasOverdue { hasOverdue = false }
            return
        }
        let threshold = Double(settings.remindAfterMinutes * 60)
        let isOverdue = sessions.contains { session in
            guard session.state == .waitingForUser else { return false }
            if let rule = MuteRule.matchingRule(for: session.cwd, rules: settings.muteRules), rule.scope == .all {
                return false
            }
            return now.timeIntervalSince(session.stateSince) >= threshold
        }
        if hasOverdue != isOverdue {
            hasOverdue = isOverdue
        }
    }

    public var hasOverdueWaitingSessions: Bool {
        hasOverdue
    }

    public var effectiveMenuState: (highestState: SessionState?, waitingCount: Int, isPaused: Bool, isOverdue: Bool) {
        let settings = AppSettings.shared
        let overdue = settings.overdueBadgeRed && hasOverdue
        let count = settings.showWaitingCountInMenuBar ? waitingCount : 0

        if let env = ProcessInfo.processInfo.environment["AGENT_MONITOR_MENU_STATE"]?.lowercased() {
            switch env {
            case "idle":
                return (highestState: nil, waitingCount: 0, isPaused: false, isOverdue: false)
            case "running":
                return (highestState: .running, waitingCount: 0, isPaused: false, isOverdue: false)
            case "completed":
                return (highestState: .completed, waitingCount: 0, isPaused: false, isOverdue: false)
            case "waiting":
                return (highestState: .waitingForUser, waitingCount: 2, isPaused: false, isOverdue: false)
            case "paused":
                return (highestState: .waitingForUser, waitingCount: 0, isPaused: true, isOverdue: false)
            case "overdue":
                return (highestState: .waitingForUser, waitingCount: 2, isPaused: false, isOverdue: true)
            default:
                break
            }
        }
        return (highestState: highestState, waitingCount: count, isPaused: isNotificationsPaused, isOverdue: overdue)
    }

    public static weak var shared: MonitorViewModel?

    public init(sessionStore: SessionStore) {
        self.sessionStore = sessionStore
        self.isLaunchAtLogin = SMAppService.mainApp.status == .enabled
        Self.shared = self

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
            if mock.lowercased() == "navigation",
               let sessionID = env["AGENT_MONITOR_NAVIGATION_SESSION"],
               let rawKind = sessionID.split(separator: ":", maxSplits: 1).first,
               let kind = AgentKind(rawValue: String(rawKind)) {
                // Explicit opt-in fixture for end-to-end navigation checks. Uses
                // real IDs supplied by the probe without changing agent files.
                self.rawSessions = [AgentSession(id: sessionID, kind: kind, title: "会话跳转验证", state: .idle,
                                              entrypoint: env["AGENT_MONITOR_NAVIGATION_ENTRYPOINT"])]
                self.isIdleExpanded = true
            } else if mock.lowercased() == "paseo" {
                self.rawSessions = MonitorViewModel.mockPaseoSessions()
                self.isIdleExpanded = true
            } else if mock.lowercased() == "empty" {
                self.rawSessions = []
            } else if mock.lowercased() == "subagents" {
                self.rawSessions = MonitorViewModel.mockSessionsSubagentsFlat()
            } else if mock.lowercased() == "large" {
                self.rawSessions = MonitorViewModel.mockSessionsLarge()
            } else {
                self.rawSessions = MonitorViewModel.mockSessions()
            }
            applyMuteFilters()
            updatePauseState()
            return
        }

        sessionStore.maxAgeSeconds = TimeInterval(AppSettings.shared.activityWindowHours * 3600)
        sessionStore.disabledKinds = AppSettings.shared.disabledAgents
        sessionStore.showUsage = AppSettings.shared.showUsage

        AppSettings.shared.$showUsage
            .dropFirst()
            .sink { [weak self] show in
                self?.sessionStore.showUsage = show
                self?.sessionStore.refreshAsync()
            }
            .store(in: &cancellables)

        AppSettings.shared.$activityWindowHours
            .dropFirst()
            .sink { [weak self] hours in
                self?.sessionStore.maxAgeSeconds = TimeInterval(hours * 3600)
                self?.sessionStore.refreshAsync()
            }
            .store(in: &cancellables)

        AppSettings.shared.$disabledAgents
            .dropFirst()
            .sink { [weak self] disabled in
                self?.sessionStore.disabledKinds = disabled
                self?.sessionStore.refreshAsync()
            }
            .store(in: &cancellables)

        AppSettings.shared.$muteRules
            .dropFirst()
            .sink { [weak self] rules in
                self?.applyMuteFilters(rules: rules)
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        reminderScheduler.remindAfterMinutes = AppSettings.shared.remindAfterMinutes
        reminderScheduler.remindMaxCount = AppSettings.shared.remindMaxCount

        AppSettings.shared.$remindAfterMinutes
            .dropFirst()
            .sink { [weak self] m in
                self?.reminderScheduler.remindAfterMinutes = m
            }
            .store(in: &cancellables)

        AppSettings.shared.$remindMaxCount
            .dropFirst()
            .sink { [weak self] c in
                self?.reminderScheduler.remindMaxCount = c
            }
            .store(in: &cancellables)

        sessionStore.onSessionsUpdated = { [weak self] updated in
            Task { @MainActor in
                self?.updateSessionsManually(updated)
            }
        }

        notifier.parentTitle = { [weak self] parentId in
            self?.sessionStore.currentSessions.first(where: { $0.id == parentId })?.title
        }

        sessionStore.onTransition = { [weak self] transition in
            Task { @MainActor in
                guard let self = self else { return }
                self.notifier.notify(transition: transition, isPanelVisible: self.sessionStore.isPanelVisible)
                self.checkReminders()
            }
        }

        notifier.sessionProvider = { [weak self] id in
            guard let self else { return nil }
            let flat = self.sessionStore.currentSessions
            var session = flat.first { $0.id == id }
            var visited = Set<String>()
            while let parentID = session?.parentId, visited.insert(parentID).inserted,
                  let parent = flat.first(where: { $0.id == parentID }) {
                session = parent
            }
            return session
        }

        notifier.onNotificationClicked = { [weak self] sessionId in
            Task { @MainActor in
                self?.markAsRead(id: sessionId)
            }
        }

        updatePauseState()
        startReminderTimer()
        sessionStore.start()

        HotkeyCenter.shared.setup { [weak self] in
            self?.sessions ?? []
        }
    }

    private func startReminderTimer() {
        reminderTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 30.0, repeating: 30.0)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.recalculateOverdue()
            self.checkReminders()
        }
        timer.resume()
        self.reminderTimer = timer
    }

    public func checkReminders(now: Date = Date()) {
        let settings = AppSettings.shared
        let snapshot = NotificationPolicy.SettingsSnapshot(
            notifyWaiting: settings.notifyWaiting,
            notifyCompleted: settings.notifyCompleted,
            minRunSecondsForCompletion: settings.minRunSecondsForCompletion,
            silenceWhilePanelOpen: settings.silenceWhilePanelOpen,
            remindEnabled: settings.remindEnabled
        )

        let waitingSessions = rawSessions.filter { $0.state == .waitingForUser }
        let dueList = reminderScheduler.evaluate(sessions: waitingSessions, now: now)

        for (session, index) in dueList {
            if NotificationPolicy.shouldSendReminder(
                session: session,
                settings: snapshot,
                muteRules: settings.muteRules,
                isPanelVisible: sessionStore.isPanelVisible,
                isNotificationsPaused: isNotificationsPaused
            ) {
                notifier.sendReminder(for: session, index: index)
            }
        }
    }

    public static func mockSubagentSessions() -> [AgentSession] {
        [
            AgentSession(id: "ag:parent", kind: .antigravity, title: "主会话：整理监控面板", state: .running),
            AgentSession(id: "ag:child-1", kind: .antigravity, title: "界面检查", state: .running, parentSessionID: "ag:parent"),
            AgentSession(id: "ag:child-2", kind: .antigravity, title: "采集检查", state: .completed, parentSessionID: "ag:parent"),
            AgentSession(id: "ag:child-3", kind: .antigravity, title: "已结束的子代理", state: .idle, suppressCompletion: true, parentSessionID: "ag:parent"),
            AgentSession(id: "ag:grandchild", kind: .antigravity, title: "布局检查", state: .running, parentSessionID: "ag:child-1")
        ]
    }

    public static func mockSessionsSubagentsFlat() -> [AgentSession] {
        let now = Date()
        return [
            // 场景 1：子代理等你（Codex 父）
            AgentSession(
                id: "cx:sub-parent", kind: .codex, title: "迁移设置页到新存储",
                cwd: "/Users/cy/code/settings-kit", state: .idle,
                stateSince: now.addingTimeInterval(-240), lastActivity: now.addingTimeInterval(-90),
                detail: "等待子代理…", parentId: nil
            ),
            AgentSession(
                id: "cx:s1", kind: .codex, title: "清理旧缓存",
                cwd: "/Users/cy/code/settings-kit", state: .waitingForUser,
                stateSince: now.addingTimeInterval(-215), lastActivity: now.addingTimeInterval(-90),
                detail: "rm -rf ./legacy-cache", detailIsCommand: true, waitingLabel: "等待授权",
                parentId: "cx:sub-parent", subagentDepth: 1
            ),
            AgentSession(
                id: "cx:s2", kind: .codex, title: "补齐迁移测试",
                cwd: "/Users/cy/code/settings-kit", state: .running,
                stateSince: now.addingTimeInterval(-90), lastActivity: now.addingTimeInterval(-90),
                detail: "swift test --filter Migration",
                parentId: "cx:sub-parent", subagentDepth: 1
            ),

            // 场景 2：子代理运行中含孙代理（dsh 父）
            AgentSession(
                id: "ds:sub-parent", kind: .dsh, title: "梳理插件加载流程",
                cwd: "/Users/cy/code/plugin-host", state: .idle,
                stateSince: now.addingTimeInterval(-252), lastActivity: now,
                detail: "汇总子代理结果…", parentId: nil
            ),
            AgentSession(
                id: "ds:a", kind: .dsh, title: "扫描入口与注册表",
                cwd: "/Users/cy/code/plugin-host", state: .running,
                stateSince: now.addingTimeInterval(-121), lastActivity: now.addingTimeInterval(-121),
                detail: "读取 Sources/Loader/Registry.swift",
                parentId: "ds:sub-parent", subagentDepth: 1
            ),
            AgentSession(
                id: "ds:b", kind: .dsh, title: "整理依赖关系图",
                cwd: "/Users/cy/code/plugin-host", state: .running,
                stateSince: now.addingTimeInterval(-107), lastActivity: now.addingTimeInterval(-107),
                detail: "正在思考…",
                parentId: "ds:sub-parent", subagentDepth: 1
            ),
            AgentSession(
                id: "ds:b1", kind: .dsh, title: "列出动态库依赖",
                cwd: "/Users/cy/code/plugin-host", state: .running,
                stateSince: now.addingTimeInterval(-33), lastActivity: now.addingTimeInterval(-33),
                detail: "otool -L PluginHost",
                parentId: "ds:b", subagentDepth: 2
            ),
            AgentSession(
                id: "ds:c", kind: .dsh, title: "检查沙盒权限声明",
                cwd: "/Users/cy/code/plugin-host", state: .completed,
                stateSince: now.addingTimeInterval(-60), lastActivity: now.addingTimeInterval(-60),
                detail: "共 4 项 entitlement，无异常",
                parentId: "ds:sub-parent", subagentDepth: 1
            ),

            // 场景 3：全部完成（Claude Code 父）
            AgentSession(
                id: "cc:sub-parent", kind: .claudeCode, title: "子代理识别方案",
                cwd: "/Users/cy/code/agent-monitor", state: .completed,
                stateSince: now.addingTimeInterval(-300), lastActivity: now.addingTimeInterval(-300),
                detail: "方案已整理，三种状态的效果图已生成",
                completedDuration: 412, parentId: nil
            ),
            AgentSession(
                id: "cc:s1", kind: .claudeCode, title: "调研 dsh 数据格式",
                cwd: "/Users/cy/code/agent-monitor", state: .completed,
                stateSince: now.addingTimeInterval(-420), lastActivity: now.addingTimeInterval(-420),
                detail: "找到 parentSession 字段",
                parentId: "cc:sub-parent", subagentDepth: 1
            ),
            AgentSession(
                id: "cc:s2", kind: .claudeCode, title: "调研 Codex rollout",
                cwd: "/Users/cy/code/agent-monitor", state: .completed,
                stateSince: now.addingTimeInterval(-400), lastActivity: now.addingTimeInterval(-400),
                detail: "本机暂无子代理样本",
                parentId: "cc:sub-parent", subagentDepth: 1
            ),
            AgentSession(
                id: "cc:s3", kind: .claudeCode, title: "核对面板布局",
                cwd: "/Users/cy/code/agent-monitor", state: .completed,
                stateSince: now.addingTimeInterval(-380), lastActivity: now.addingTimeInterval(-380),
                detail: "fixedSize 需保留",
                parentId: "cc:sub-parent", subagentDepth: 1
            ),

            // 对照：无子代理普通会话（Antigravity）
            AgentSession(
                id: "ag:plain", kind: .antigravity, title: "更新 README 截图",
                cwd: "/Users/cy/code/agent-monitor", state: .running,
                stateSince: now.addingTimeInterval(-48), lastActivity: now.addingTimeInterval(-48),
                detail: "正在生成截图…", parentId: nil
            )
        ]
    }

    public static func mockSessionsSubagents() -> [AgentSession] {
        SessionTree.build(mockSessionsSubagentsFlat())
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
                waitingLabel: "等待授权",
                usage: SessionUsage(
                    model: "gpt-6-astra",
                    inputTokens: 663_900,
                    cachedInputTokens: 624_500,
                    outputTokens: 4_600,
                    reasoningTokens: 69,
                    contextTokens: 98_200,
                    contextWindow: 258_400,
                    updatedAt: now.addingTimeInterval(-3)
                )
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
                waitingLabel: "在问你",
                usage: SessionUsage(
                    model: "claude-opus-5-5",
                    inputTokens: 26,
                    cachedInputTokens: 5_650_000,
                    cacheWriteTokens: 62_800,
                    outputTokens: 5_100,
                    requestCount: 13,
                    contextTokens: 459_554,
                    contextWindow: nil,
                    updatedAt: now
                )
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
                completedDuration: 372,
                usage: SessionUsage(
                    model: nil,
                    steps: 86,
                    updatedAt: now.addingTimeInterval(-720)
                )
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
                detail: "正在思考…",
                usage: SessionUsage(
                    model: "claude-opus-5-5",
                    inputTokens: 100_000,
                    cachedInputTokens: 800_000,
                    outputTokens: 120_000,
                    contextTokens: 1_020_000,
                    updatedAt: now.addingTimeInterval(-48)
                )
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

    static func mockPaseoSessions() -> [AgentSession] {
        let now = Date()
        return [
            AgentSession(id: "paseo:local:68660d06-0ce7-42f3-b8a1-7b17a91fbae4", kind: .paseo,
                         title: "本机 Paseo 会话", cwd: "/Users/cy/code/agent-monitor", state: .running,
                         stateSince: now.addingTimeInterval(-30), lastActivity: now,
                         paseo: PaseoOrigin(serverID: "local", agentID: "68660d06-0ce7-42f3-b8a1-7b17a91fbae4",
                                             hostName: "Mac", isLocal: true, provider: "codex")),
            AgentSession(id: "paseo:remote:01a188df-cf09-7763-8796-5609ef455ca1", kind: .paseo,
                         title: "远程 Paseo 会话", cwd: "/srv/backend", state: .waitingForUser,
                         stateSince: now.addingTimeInterval(-60), lastActivity: now,
                         detail: "等待 Paseo 授权或回复", waitingLabel: "等待授权或回复",
                         paseo: PaseoOrigin(serverID: "remote", agentID: "01a188df-cf09-7763-8796-5609ef455ca1",
                                             hostName: "开发服务器", isLocal: false, provider: "claude")),
            AgentSession(id: "paseo:offline:bf7c14ea-f041-4ac1-98a0-0e90d03e0af6", kind: .paseo,
                         title: "离线 Paseo 会话", cwd: "/srv/work", state: .idle,
                         stateSince: now.addingTimeInterval(-120), lastActivity: now,
                         detail: "连接断开 · 状态待同步", suppressCompletion: true,
                         paseo: PaseoOrigin(serverID: "offline", agentID: "bf7c14ea-f041-4ac1-98a0-0e90d03e0af6",
                                             hostName: "备用服务器", isLocal: false, provider: "dsh-pi", connected: false))
        ]
    }

    public func updateSessionsManually(_ sessions: [AgentSession]) {
        self.rawSessions = sessions
        self.applyMuteFilters()
        self.checkPauseExpiry()
        self.checkReminders()
    }

    private func applyMuteFilters(rules: [MuteRule] = AppSettings.shared.muteRules) {
        let filtered = rawSessions.filter { s in
            if let rule = MuteRule.matchingRule(for: s.cwd, rules: rules), rule.hideInPanel {
                return false
            }
            return true
        }
        // Antigravity keeps the existing flat hierarchy used by SessionGroup.
        // Preserve its child order while building nested DSH display rows.
        let tree = SessionTree.build(filtered.filter { $0.parentSessionID == nil })
            + filtered.filter { $0.parentSessionID != nil }
        if self.sessions != tree {
            self.sessions = tree
        }
        recalculateOverdue()
    }

    public func markAsRead(id: String) {
        let current = rawSessions
        var idsToMark = Set<String>()
        idsToMark.insert(id)

        // 向上追溯到根会话
        var rootId = id
        var visited = Set<String>()
        while let currentSession = current.first(where: { $0.id == rootId && !visited.contains($0.id) }),
              let pid = currentSession.parentId {
            visited.insert(rootId)
            rootId = pid
        }
        idsToMark.insert(rootId)

        // 递归向下收集 rootId 的所有后代
        var traversed = Set<String>()
        func collectDescendants(parent: String) {
            guard traversed.insert(parent).inserted else { return }
            for s in current where s.parentId == parent {
                idsToMark.insert(s.id)
                collectDescendants(parent: s.id)
            }
        }
        collectDescendants(parent: rootId)

        for sid in idsToMark {
            sessionStore.markAsRead(id: sid)
        }
        let storeSessions = sessionStore.currentSessions
        if !storeSessions.isEmpty {
            rawSessions = storeSessions
        } else {
            for idx in rawSessions.indices where idsToMark.contains(rawSessions[idx].id) && rawSessions[idx].state == .completed {
                rawSessions[idx].state = .idle
            }
        }
        applyMuteFilters()
    }

    public func markAllAsRead() {
        sessionStore.markAllAsRead()
        let storeSessions = sessionStore.currentSessions
        if !storeSessions.isEmpty {
            rawSessions = storeSessions
        } else {
            for idx in rawSessions.indices {
                if rawSessions[idx].state == .completed {
                    rawSessions[idx].state = .idle
                }
            }
        }
        applyMuteFilters()
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

    public func onPanelAppear() {
        expandedSubagentIDs = []
        sessionStore.isPanelVisible = true
        if ProcessInfo.processInfo.environment["AGENT_MONITOR_IDLE_EXPANDED"] == nil {
            isIdleExpanded = AppSettings.shared.idleExpandedByDefault
        }
    }

    public func onPanelDisappear() {
        sessionStore.isPanelVisible = false
        keyboardSelectionID = nil
    }

    // MARK: - Keyboard Navigation

    public func selectNextSession() {
        let ids = visibleSessionIDs
        guard !ids.isEmpty else { return }
        guard let current = keyboardSelectionID, let idx = ids.firstIndex(of: current) else {
            keyboardSelectionID = ids.first
            return
        }
        if idx + 1 < ids.count {
            keyboardSelectionID = ids[idx + 1]
        }
    }

    public func selectPreviousSession() {
        let ids = visibleSessionIDs
        guard !ids.isEmpty else { return }
        guard let current = keyboardSelectionID, let idx = ids.firstIndex(of: current) else {
            keyboardSelectionID = ids.last
            return
        }
        if idx > 0 {
            keyboardSelectionID = ids[idx - 1]
        }
    }

    public func activateCurrentSelection() {
        guard let id = keyboardSelectionID,
              let session = sessions.first(where: { $0.id == id }) else { return }
        if session.state == .completed {
            withAnimation(.smooth) {
                markAsRead(id: session.id)
            }
        }
        SessionJumper.shared.jump(to: session)
    }

    public func markCurrentSelectionAsReadAndAdvance() {
        guard let id = keyboardSelectionID,
              let session = sessions.first(where: { $0.id == id }),
              session.state == .completed else { return }

        let currentIDs = visibleSessionIDs
        let currentIdx = currentIDs.firstIndex(of: id)

        withAnimation(.smooth) {
            markAsRead(id: id)
        }

        let newIDs = visibleSessionIDs
        guard !newIDs.isEmpty else {
            keyboardSelectionID = nil
            return
        }

        if let idx = currentIdx {
            if idx < newIDs.count {
                keyboardSelectionID = newIDs[idx]
            } else {
                keyboardSelectionID = newIDs.last
            }
        } else {
            keyboardSelectionID = newIDs.first
        }
    }

    public func handleDigitFilter(_ digit: Int) {
        let target: SessionState
        switch digit {
        case 1: target = .waitingForUser
        case 2: target = .completed
        case 3: target = .running
        case 4: target = .idle
        default: return
        }

        let count = sessions.filter { $0.state == target }.count
        guard count > 0 else { return }

        withAnimation(.snappy(duration: 0.2)) {
            if filterState == target {
                filterState = nil
            } else {
                filterState = target
            }
            keyboardSelectionID = nil
        }
    }

    public func handleEscape() -> Bool {
        if filterState != nil {
            withAnimation(.snappy(duration: 0.2)) {
                filterState = nil
                keyboardSelectionID = nil
            }
            return true
        }
        keyboardSelectionID = nil
        return false
    }

    public func handleKeyEvent(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])

        // ⌘, : 打开设置
        if flags == .command && (event.keyCode == 43 || event.charactersIgnoringModifiers == ",") {
            SettingsWindowManager.shared.openSettings()
            return true
        }

        // ⌘⌫ : 全部标为已读
        if flags == .command && (event.keyCode == 51 || event.keyCode == 117) {
            withAnimation(.smooth) {
                markAllAsRead()
            }
            return true
        }

        // ⌫ 或 ⌦ (无修饰键) : 标为已读并移到下一项
        if flags.isEmpty && (event.keyCode == 51 || event.keyCode == 117) {
            markCurrentSelectionAsReadAndAdvance()
            return true
        }

        // ↓ (DownArrow, keyCode 125)
        if event.keyCode == 125 {
            selectNextSession()
            return true
        }

        // ↑ (UpArrow, keyCode 126)
        if event.keyCode == 126 {
            selectPreviousSession()
            return true
        }

        // ↩ (Return, keyCode 36 / Keypad Enter, keyCode 76)
        if event.keyCode == 36 || event.keyCode == 76 {
            activateCurrentSelection()
            return true
        }

        // esc (Escape, keyCode 53)
        if event.keyCode == 53 {
            let handled = handleEscape()
            if !handled {
                if let keyWindow = NSApp.keyWindow {
                    keyWindow.close()
                } else {
                    MenuBarExtraToggler.toggle()
                }
            }
            return true
        }

        // 1-4 数字键
        if flags.isEmpty {
            switch Int(event.keyCode) {
            case 18, 83: // '1' or Keypad 1
                handleDigitFilter(1)
                return true
            case 19, 84: // '2' or Keypad 2
                handleDigitFilter(2)
                return true
            case 20, 85: // '3' or Keypad 3
                handleDigitFilter(3)
                return true
            case 21, 86: // '4' or Keypad 4
                handleDigitFilter(4)
                return true
            default:
                if let chars = event.charactersIgnoringModifiers, let first = chars.first, let digit = Int(String(first)), digit >= 1 && digit <= 4 {
                    handleDigitFilter(digit)
                    return true
                }
            }
        }

        return false
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

    public func muteSession(cwd: String?, scope: MuteRule.Scope) {
        guard let path = cwd, !path.isEmpty else { return }
        let expanded = (path as NSString).expandingTildeInPath
        let cleanPath = expanded.hasSuffix("/") && expanded.count > 1 ? String(expanded.dropLast()) : expanded

        var rules = AppSettings.shared.muteRules
        if let idx = rules.firstIndex(where: { $0.path == cleanPath }) {
            rules[idx].scope = scope
        } else {
            rules.append(MuteRule(path: cleanPath, scope: scope, hideInPanel: false))
        }
        AppSettings.shared.muteRules = rules
        applyMuteFilters()
    }

    public func hideInPanel(cwd: String?) {
        guard let path = cwd, !path.isEmpty else { return }
        let expanded = (path as NSString).expandingTildeInPath
        let cleanPath = expanded.hasSuffix("/") && expanded.count > 1 ? String(expanded.dropLast()) : expanded

        var rules = AppSettings.shared.muteRules
        if let idx = rules.firstIndex(where: { $0.path == cleanPath }) {
            rules[idx].hideInPanel = true
        } else {
            rules.append(MuteRule(path: cleanPath, scope: .all, hideInPanel: true))
        }
        AppSettings.shared.muteRules = rules
        applyMuteFilters()
    }
}
