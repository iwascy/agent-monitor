import Foundation
import Combine

public enum SessionTransition: Sendable, Equatable {
    case added(AgentSession)
    case stateChanged(session: AgentSession, from: SessionState, to: SessionState)
    case removed(id: String)
}

public final class SessionStore: @unchecked Sendable {
    public let adapters: [AgentAdapter]

    private var suppressAddedOnNextRefresh: Bool = false

    private var _maxAgeSeconds: TimeInterval
    public var maxAgeSeconds: TimeInterval {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _maxAgeSeconds
        }
        set {
            lock.lock()
            if _maxAgeSeconds != newValue {
                _maxAgeSeconds = newValue
                suppressAddedOnNextRefresh = true
            }
            lock.unlock()
        }
    }

    private var _disabledKinds: Set<AgentKind> = []
    public var disabledKinds: Set<AgentKind> {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _disabledKinds
        }
        set {
            lock.lock()
            if _disabledKinds != newValue {
                for kind in newValue {
                    lastAdapterResults.removeValue(forKey: kind)
                }
                _disabledKinds = newValue
                suppressAddedOnNextRefresh = true
            }
            lock.unlock()
        }
    }

    private var _showUsage: Bool = true
    public var showUsage: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _showUsage
        }
        set {
            lock.lock()
            _showUsage = newValue
            for adapter in adapters {
                if let c = adapter as? ClaudeCodeAdapter { c.showUsage = newValue }
                if let c = adapter as? CodexAdapter { c.showUsage = newValue }
                if let a = adapter as? AntigravityAdapter { a.showUsage = newValue }
            }
            lock.unlock()
        }
    }

    public var claudeHookReader: ClaudeHookEventReader? {
        adapters.compactMap { $0 as? ClaudeCodeAdapter }.first?.hookReader
    }

    private var sessionCache: [String: AgentSession] = [:]
    private var lastAdapterResults: [AgentKind: [AgentSession]] = [:]
    private var readCompletedKeys: Set<String> = [] // "\(sessionId):\(completionTimestamp)"
    private var runningStartTimes: [String: Date] = [:]
    private var isInitialScan = true
    private let lock = NSRecursiveLock()
    private let scanLock = NSLock()

    private var _isPanelVisible: Bool = false
    public var isPanelVisible: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _isPanelVisible
        }
        set {
            lock.lock()
            let changed = (_isPanelVisible != newValue)
            _isPanelVisible = newValue
            for adapter in adapters {
                if let paseo = adapter as? PaseoAdapter {
                    paseo.isPanelVisible = newValue
                }
            }
            lock.unlock()

            if changed {
                workQueue.async { [weak self] in
                    self?.handlePanelVisibilityChanged(newValue)
                }
            }
        }
    }

    public var onTransition: (@Sendable (SessionTransition) -> Void)?
    public var onSessionsUpdated: (@Sendable ([AgentSession]) -> Void)?
    private let sessionSubject = CurrentValueSubject<[AgentSession], Never>([])

    /// 独立订阅者共享扫描结果，不替换现有回调；包含面板中隐藏的会话。
    public var sessionsPublisher: AnyPublisher<[AgentSession], Never> {
        sessionSubject.eraseToAnyPublisher()
    }

    private func publishSessions(_ sessions: [AgentSession]) {
        sessionSubject.send(sessions)
        onSessionsUpdated?(sessions)
    }

    private var fileWatcher: FileWatcher?
    private var pollingTimer: DispatchSourceTimer?
    private var liveTimer: DispatchSourceTimer?
    private let workQueue = DispatchQueue(label: "com.agentmonitor.sessionstore", qos: .utility)

    /// 预规范化各 Adapter 的监听路径，兼容 macOS `/var` -> `/private/var` 等符号链接前缀
    private let normalizedWatchPathsByKind: [AgentKind: [String]]

    public let pollingInterval: TimeInterval
    /// 面板打开期间的兜底轮询周期（文件变更已由 0.3s FileWatcher 实时驱动，读秒由 UI TimelineView 本地渲染）
    private let liveRefreshInterval: TimeInterval = 3.0

    public init(
        adapters: [AgentAdapter],
        maxAgeSeconds: TimeInterval = 6 * 3600,
        pollingInterval: TimeInterval = 15.0
    ) {
        self.adapters = adapters
        self._maxAgeSeconds = maxAgeSeconds
        self.pollingInterval = pollingInterval

        var watchMap: [AgentKind: [String]] = [:]
        for adapter in adapters {
            let normPaths = adapter.watchPaths.flatMap { url -> [String] in
                let raw = Self.canonicalPath(url.path)
                let resolved = Self.canonicalPath(url.resolvingSymlinksInPath().path)
                return raw == resolved ? [raw] : [raw, resolved]
            }
            watchMap[adapter.kind, default: []].append(contentsOf: normPaths)
        }
        self.normalizedWatchPathsByKind = watchMap

        // Set up file watcher（按变更路径定向刷新受影响的 Adapter）
        let allPaths = adapters.flatMap { $0.watchPaths }
        if !allPaths.isEmpty {
            self.fileWatcher = FileWatcher(paths: allPaths, debounceInterval: 0.3, queue: workQueue) { [weak self] changedPaths in
                self?.refresh(changedPaths: changedPaths)
            }
        }
    }

    deinit {
        stop()
    }

    public func start() {
        lock.lock()
        for adapter in adapters {
            if let paseo = adapter as? PaseoAdapter {
                paseo.onSnapshotUpdated = { [weak self] in
                    guard let self else { return }
                    self.workQueue.async { [weak self] in
                        _ = self?.refresh(targetKinds: [.paseo])
                    }
                }
            }
        }
        fileWatcher?.start()

        if pollingTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: workQueue)
            timer.schedule(deadline: .now() + pollingInterval, repeating: pollingInterval)
            timer.setEventHandler { [weak self] in
                self?.refresh()
            }
            timer.resume()
            self.pollingTimer = timer
        }
        lock.unlock()

        // Perform initial refresh asynchronously on workQueue to avoid blocking main thread
        workQueue.async { [weak self] in
            self?.refresh()
        }
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }

        _isPanelVisible = false
        for adapter in adapters {
            if let paseo = adapter as? PaseoAdapter {
                paseo.isPanelVisible = false
                paseo.onSnapshotUpdated = nil
            }
        }
        fileWatcher?.stop()
        if let timer = pollingTimer {
            timer.cancel()
            pollingTimer = nil
        }
        stopLiveTimer()
    }

    private func handlePanelVisibilityChanged(_ visible: Bool) {
        if visible {
            refresh()
            let updated = currentSessions
            publishSessions(updated)
            startLiveTimer()
        } else {
            stopLiveTimer()
        }
    }

    private func startLiveTimer() {
        lock.lock()
        stopLiveTimer()
        let timer = DispatchSource.makeTimerSource(queue: workQueue)
        timer.schedule(deadline: .now() + liveRefreshInterval, repeating: liveRefreshInterval)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            let isVisible: Bool = {
                self.lock.lock()
                defer { self.lock.unlock() }
                return self._isPanelVisible
            }()
            if isVisible {
                self.refresh()
            }
        }
        timer.resume()
        self.liveTimer = timer
        lock.unlock()
    }

    private func stopLiveTimer() {
        if let timer = liveTimer {
            timer.cancel()
            liveTimer = nil
        }
    }

    public var currentSessions: [AgentSession] {
        lock.lock()
        defer { lock.unlock() }
        return Self.sortedSessions(sessionCache.values)
    }

    private static func sortedSessions<S: Sequence>(_ values: S) -> [AgentSession] where S.Element == AgentSession {
        values.sorted { lhs, rhs in
            // Sort order: waitingForUser first, then completed, then running, then idle
            let rankL = stateRank(lhs.state)
            let rankR = stateRank(rhs.state)
            if rankL != rankR {
                return rankL < rankR
            }
            return lhs.lastActivity > rhs.lastActivity
        }
    }

    @inline(__always)
    private static func stateRank(_ state: SessionState) -> Int {
        switch state {
        case .waitingForUser: return 0
        case .completed: return 1
        case .running: return 2
        case .idle: return 3
        }
    }

    public func markAsRead(id: String) {
        lock.lock()
        guard var session = sessionCache[id], session.state == .completed else {
            lock.unlock()
            return
        }
        let key = "\(session.id):\(Int64(session.lastActivity.timeIntervalSince1970))"
        readCompletedKeys.insert(key)
        session.state = .idle
        sessionCache[id] = session
        let updated = Self.sortedSessions(sessionCache.values)
        lock.unlock()

        publishSessions(updated)
    }

    public func markAllAsRead() {
        lock.lock()
        for (id, var session) in sessionCache {
            if session.state == .completed {
                let key = "\(session.id):\(Int64(session.lastActivity.timeIntervalSince1970))"
                readCompletedKeys.insert(key)
                session.state = .idle
                sessionCache[id] = session
            }
        }
        let updated = Self.sortedSessions(sessionCache.values)
        lock.unlock()

        publishSessions(updated)
    }

    public func refreshAsync() {
        workQueue.async { [weak self] in
            self?.refresh()
        }
    }

    /// 规范化文件路径，统一消除 macOS `/var`、`/tmp`、`/etc` 符号链接前缀与末尾斜杠差异。
    internal static func canonicalPath(_ rawPath: String) -> String {
        var p = (rawPath as NSString).standardizingPath
        if p.count > 1 && p.hasSuffix("/") {
            p.removeLast()
        }
        if p == "/var" || p.hasPrefix("/var/") {
            p = "/private" + p
        } else if p == "/tmp" || p.hasPrefix("/tmp/") {
            p = "/private" + p
        } else if p == "/etc" || p.hasPrefix("/etc/") {
            p = "/private" + p
        }
        return p
    }

    /// 判断事件路径是否命中某个监听路径（支持子文件、父目录变动以及 SQLite `-wal`/`-shm` 伴生文件）。
    internal static func pathMatches(_ eventPath: String, watchPath: String) -> Bool {
        if eventPath == watchPath { return true }
        if eventPath.hasPrefix(watchPath + "/") { return true }
        if watchPath.hasPrefix(eventPath + "/") { return true }
        // SQLite WAL/SHM/Journal 文件与主库同目录且以 `<dbPath>-wal` / `<dbPath>-shm` 命名
        if eventPath.hasPrefix(watchPath + "-") { return true }
        return false
    }

    /// 根据文件系统变更路径集合计算受影响的 Adapter 类型；若无法归属到任何已知 Adapter 则返回 `nil`（回退全量扫描）。
    internal func resolveAffectedKinds(for changedPaths: Set<String>) -> Set<AgentKind>? {
        guard !changedPaths.isEmpty else { return nil }
        let normalizedEvents = changedPaths.map(Self.canonicalPath)
        var matched = Set<AgentKind>()
        for (kind, watchList) in normalizedWatchPathsByKind {
            let hit = normalizedEvents.contains { ev in
                watchList.contains { wp in Self.pathMatches(ev, watchPath: wp) }
            }
            if hit {
                matched.insert(kind)
            }
        }
        return matched.isEmpty ? nil : matched
    }

    @discardableResult
    public func refresh() -> [SessionTransition] {
        refresh(targetKinds: nil)
    }

    /// 根据变更路径集合执行定向刷新：仅重新扫描匹配的未禁用 Adapter，其余直接复用缓存结果。
    @discardableResult
    public func refresh(changedPaths: Set<String>?) -> [SessionTransition] {
        guard let changedPaths, !changedPaths.isEmpty else {
            return refresh(targetKinds: nil)
        }
        guard let matchedKinds = resolveAffectedKinds(for: changedPaths) else {
            return refresh(targetKinds: nil)
        }
        return refresh(targetKinds: matchedKinds)
    }

    @discardableResult
    public func refresh(targetKinds: Set<AgentKind>?) -> [SessionTransition] {
        scanLock.lock()
        defer { scanLock.unlock() }

        // 1. 短暂加锁读取当前配置快照，随后立即释放锁，保证耗时的磁盘/SQLite I/O 不阻塞主线程
        lock.lock()
        let initialSuppressAdded = suppressAddedOnNextRefresh
        suppressAddedOnNextRefresh = false
        let snapshotDisabled = _disabledKinds
        let isInitial = isInitialScan
        let cachedResultsSnapshot = lastAdapterResults
        lock.unlock()

        // 确定本轮实际需要调用 scan() 的 Adapter 集合
        let kindsToScan: Set<AgentKind>
        if let targetKinds, !isInitial {
            var needed = targetKinds.subtracting(snapshotDisabled)
            // 任何尚未建立基线缓存的未禁用 Adapter 仍需补扫一次
            for adapter in adapters where !snapshotDisabled.contains(adapter.kind) {
                if cachedResultsSnapshot[adapter.kind] == nil {
                    needed.insert(adapter.kind)
                }
            }
            if needed.isEmpty {
                // 变更全部落在已禁用的 Adapter 上，且无待补扫项，直接跳过本轮 I/O
                return []
            }
            kindsToScan = needed
        } else {
            kindsToScan = Set(adapters.map(\.kind)).subtracting(snapshotDisabled)
        }

        // 2. 在锁外执行受影响 Adapter 的磁盘与数据库扫描
        var freshlyScannedByKind: [AgentKind: [AgentSession]] = [:]
        var failedKinds = Set<AgentKind>()

        for adapter in adapters {
            if snapshotDisabled.contains(adapter.kind) || !kindsToScan.contains(adapter.kind) {
                continue
            }
            do {
                let list = try adapter.scan()
                freshlyScannedByKind[adapter.kind] = list
            } catch {
                failedKinds.insert(adapter.kind)
                NSLog("Adapter \(adapter.kind) scan failed: \(error)")
            }
        }

        // 3. 重新加锁，结合最新配置合并结果并推进会话状态机
        lock.lock()
        let suppressAdded = initialSuppressAdded || suppressAddedOnNextRefresh
        suppressAddedOnNextRefresh = false
        let currentDisabledKinds = _disabledKinds
        let currentMaxAge = _maxAgeSeconds

        for (kind, list) in freshlyScannedByKind where !currentDisabledKinds.contains(kind) {
            lastAdapterResults[kind] = list
        }
        for disabled in currentDisabledKinds {
            lastAdapterResults.removeValue(forKey: disabled)
        }

        var scannedSessions: [String: AgentSession] = [:]
        var successfulAdapters: Set<AgentKind> = []

        for adapter in adapters {
            let kind = adapter.kind
            if currentDisabledKinds.contains(kind) {
                continue
            }
            if failedKinds.contains(kind) {
                continue
            }
            if let list = freshlyScannedByKind[kind] ?? lastAdapterResults[kind] {
                for item in list {
                    scannedSessions[item.id] = item
                }
                successfulAdapters.insert(kind)
            }
        }

        scannedSessions = Dictionary(uniqueKeysWithValues: PaseoAdapter.merging(Array(scannedSessions.values)).map { ($0.id, $0) })

        var transitions: [SessionTransition] = []
        var hasContentChanges = false
        var removedFromDisabled = false
        let now = Date()
        var retainedAncestors = Set<String>()
        for session in scannedSessions.values where now.timeIntervalSince(session.lastActivity) <= currentMaxAge {
            var parentID = session.parentSessionID
            var visited: Set<String> = [session.id]
            while let id = parentID, let parent = scannedSessions[id], visited.insert(id).inserted {
                retainedAncestors.insert(id)
                parentID = parent.parentSessionID
            }
        }

        // 0. Remove sessions from disabled adapters (without notifying)
        for (id, existing) in sessionCache {
            if currentDisabledKinds.contains(existing.kind) {
                sessionCache.removeValue(forKey: id)
                runningStartTimes.removeValue(forKey: id)
                hasContentChanges = true
                removedFromDisabled = true
            }
        }

        // 1. Detect removed sessions (or older than maxAge)
        for (id, existing) in sessionCache {
            // Retain existing sessions if their adapter failed to scan in this round
            if !successfulAdapters.contains(existing.kind) {
                continue
            }

            if let fresh = scannedSessions[id] {
                if now.timeIntervalSince(fresh.lastActivity) > currentMaxAge && !retainedAncestors.contains(id) {
                    sessionCache.removeValue(forKey: id)
                    runningStartTimes.removeValue(forKey: id)
                    transitions.append(.removed(id: id))
                    hasContentChanges = true
                }
            } else {
                sessionCache.removeValue(forKey: id)
                runningStartTimes.removeValue(forKey: id)
                transitions.append(.removed(id: id))
                hasContentChanges = true
            }
        }

        // 2. Detect added or modified sessions
        for (id, var fresh) in scannedSessions {
            if now.timeIntervalSince(fresh.lastActivity) > currentMaxAge && !retainedAncestors.contains(id) {
                continue
            }

            if let existing = sessionCache[id] {
                // Upgrade rule: running or waitingForUser -> idle transitions to completed
                if fresh.state == .idle {
                    let readKey = "\(fresh.id):\(Int64(fresh.lastActivity.timeIntervalSince1970))"
                    if existing.state == .running || existing.state == .waitingForUser {
                        if fresh.suppressCompletion {
                            runningStartTimes.removeValue(forKey: id)
                        } else if !readCompletedKeys.contains(readKey) {
                            fresh.state = .completed
                            let startTime = runningStartTimes[id] ?? existing.stateSince
                            let duration = max(1.0, now.timeIntervalSince(startTime))
                            fresh.completedDuration = duration
                            runningStartTimes.removeValue(forKey: id)
                        }
                    } else if existing.state == .completed && !fresh.suppressCompletion {
                        // Maintain completed state until marked as read
                        if !readCompletedKeys.contains(readKey) {
                            fresh.state = .completed
                            fresh.completedDuration = existing.completedDuration
                        }
                    }
                } else if fresh.state == .running {
                    // Record running start time if freshly transitioning into running
                    if existing.state != .running {
                        runningStartTimes[id] = min(now, fresh.stateSince)
                    }
                    // Clear read status if session resumes running
                    readCompletedKeys = readCompletedKeys.filter { !$0.hasPrefix("\(fresh.id):") }
                }

                // Maintain stateSince: retain old value when state hasn't changed, update to now on change
                if existing.state == fresh.state {
                    fresh.stateSince = existing.stateSince
                } else {
                    fresh.stateSince = (fresh.state == .running || fresh.state == .waitingForUser)
                        ? min(now, fresh.stateSince)
                        : now
                    transitions.append(.stateChanged(session: fresh, from: existing.state, to: fresh.state))
                }
                if existing != fresh {
                    hasContentChanges = true
                }
                sessionCache[id] = fresh
            } else {
                // First discovery: idle stays idle
                if fresh.state == .completed {
                    fresh.state = .idle
                }
                if fresh.state != .running && fresh.state != .waitingForUser {
                    fresh.stateSince = fresh.lastActivity
                }
                if fresh.state == .running {
                    runningStartTimes[id] = fresh.stateSince
                }
                sessionCache[id] = fresh
                transitions.append(.added(fresh))
                hasContentChanges = true
            }
        }

        // 惰性淘汰已不再存在于缓存会话中的旧已读标记，防止长驻无限累积
        if readCompletedKeys.count > 512 {
            let activePrefixes = Set(sessionCache.keys)
            readCompletedKeys = readCompletedKeys.filter { key in
                guard let colon = key.lastIndex(of: ":") else { return false }
                return activePrefixes.contains(String(key[..<colon]))
            }
        }

        let wasInitial = isInitialScan
        isInitialScan = false
        let isVisible = _isPanelVisible

        let shouldPublishForTransitions = !transitions.isEmpty || removedFromDisabled
        let shouldPublishForContent = wasInitial || (isVisible && hasContentChanges)
        let updatedSnapshot: [AgentSession]? = (shouldPublishForTransitions || shouldPublishForContent)
            ? Self.sortedSessions(sessionCache.values)
            : nil
        let transitionCallback = onTransition
        lock.unlock()

        if let updated = updatedSnapshot {
            publishSessions(updated)
            if shouldPublishForTransitions && !wasInitial {
                for t in transitions {
                    if suppressAdded {
                        if case .added = t {
                            continue
                        }
                    }
                    transitionCallback?(t)
                }
            }
        }

        return transitions
    }
}
