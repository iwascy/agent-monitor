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
    private var readCompletedKeys: Set<String> = [] // "\(sessionId):\(completionTimestamp)"
    private var runningStartTimes: [String: Date] = [:]
    private var isInitialScan = true
    private let lock = NSRecursiveLock()

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

    public let pollingInterval: TimeInterval

    public init(
        adapters: [AgentAdapter],
        maxAgeSeconds: TimeInterval = 6 * 3600,
        pollingInterval: TimeInterval = 15.0
    ) {
        self.adapters = adapters
        self._maxAgeSeconds = maxAgeSeconds
        self.pollingInterval = pollingInterval

        // Set up file watcher
        let allPaths = adapters.flatMap { $0.watchPaths }
        if !allPaths.isEmpty {
            self.fileWatcher = FileWatcher(paths: allPaths, debounceInterval: 0.3, queue: workQueue) { [weak self] in
                self?.refresh()
            }
        }
    }

    deinit {
        stop()
    }

    public func start() {
        lock.lock()
        defer { lock.unlock() }

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

        // Perform initial refresh asynchronously on workQueue to avoid blocking main thread
        workQueue.async { [weak self] in
            self?.refresh()
        }
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }

        _isPanelVisible = false
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
        stopLiveTimer()
        let timer = DispatchSource.makeTimerSource(queue: workQueue)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
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
        return Array(sessionCache.values).sorted { lhs, rhs in
            // Sort order: waitingForUser first, then completed, then running, then idle
            let stateRank = { (state: SessionState) -> Int in
                switch state {
                case .waitingForUser: return 0
                case .completed: return 1
                case .running: return 2
                case .idle: return 3
                }
            }
            let rankL = stateRank(lhs.state)
            let rankR = stateRank(rhs.state)
            if rankL != rankR {
                return rankL < rankR
            }
            return lhs.lastActivity > rhs.lastActivity
        }
    }

    public func markAsRead(id: String) {
        lock.lock()
        defer { lock.unlock() }

        guard var session = sessionCache[id] else { return }
        if session.state == .completed {
            let key = "\(session.id):\(Int64(session.lastActivity.timeIntervalSince1970))"
            readCompletedKeys.insert(key)
            session.state = .idle
            sessionCache[id] = session
            let updated = currentSessions
            publishSessions(updated)
        }
    }

    public func markAllAsRead() {
        lock.lock()
        defer { lock.unlock() }

        for (id, var session) in sessionCache {
            if session.state == .completed {
                let key = "\(session.id):\(Int64(session.lastActivity.timeIntervalSince1970))"
                readCompletedKeys.insert(key)
                session.state = .idle
                sessionCache[id] = session
            }
        }
        let updated = currentSessions
        publishSessions(updated)
    }

    public func refreshAsync() {
        workQueue.async { [weak self] in
            self?.refresh()
        }
    }

    @discardableResult
    public func refresh() -> [SessionTransition] {
        lock.lock()
        defer { lock.unlock() }

        let suppressAdded = suppressAddedOnNextRefresh
        suppressAddedOnNextRefresh = false

        var scannedSessions: [String: AgentSession] = [:]
        var successfulAdapters: Set<AgentKind> = []
        let currentDisabledKinds = _disabledKinds
        let currentMaxAge = _maxAgeSeconds

        for adapter in adapters {
            if currentDisabledKinds.contains(adapter.kind) {
                continue
            }
            do {
                let list = try adapter.scan()
                for item in list {
                    scannedSessions[item.id] = item
                }
                successfulAdapters.insert(adapter.kind)
            } catch {
                NSLog("Adapter \(adapter.kind) scan failed: \(error)")
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
                    transitions.append(.removed(id: id))
                    hasContentChanges = true
                }
            } else {
                sessionCache.removeValue(forKey: id)
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
                        runningStartTimes[id] = now
                    }
                    // Clear read status if session resumes running
                    readCompletedKeys = readCompletedKeys.filter { !$0.hasPrefix("\(fresh.id):") }
                }

                // Maintain stateSince: retain old value when state hasn't changed, update to now on change
                if existing.state == fresh.state {
                    fresh.stateSince = existing.stateSince
                } else {
                    fresh.stateSince = now
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
                fresh.stateSince = fresh.lastActivity
                if fresh.state == .running {
                    runningStartTimes[id] = fresh.stateSince
                }
                sessionCache[id] = fresh
                transitions.append(.added(fresh))
                hasContentChanges = true
            }
        }

        let isInitial = isInitialScan
        isInitialScan = false
        let isVisible = _isPanelVisible

        if !transitions.isEmpty || removedFromDisabled {
            let updated = currentSessions
            publishSessions(updated)
            if !isInitial {
                for t in transitions {
                    if suppressAdded {
                        if case .added = t {
                            continue
                        }
                    }
                    onTransition?(t)
                }
            }
        } else if isInitial || (isVisible && hasContentChanges) {
            let updated = currentSessions
            publishSessions(updated)
        }

        return transitions
    }
}
