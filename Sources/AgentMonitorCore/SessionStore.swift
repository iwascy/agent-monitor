import Foundation

public enum SessionTransition: Sendable, Equatable {
    case added(AgentSession)
    case stateChanged(session: AgentSession, from: SessionState, to: SessionState)
    case removed(id: String)
}

public final class SessionStore: @unchecked Sendable {
    public let adapters: [AgentAdapter]
    public let maxAgeSeconds: TimeInterval

    private var sessionCache: [String: AgentSession] = [:]
    private var readCompletedKeys: Set<String> = [] // "\(sessionId):\(completionTimestamp)"
    private var runningStartTimes: [String: Date] = [:]
    private var isInitialScan = true
    private let lock = NSRecursiveLock()

    public var onTransition: (@Sendable (SessionTransition) -> Void)?
    public var onSessionsUpdated: (@Sendable ([AgentSession]) -> Void)?

    private var fileWatcher: FileWatcher?
    private var pollingTimer: DispatchSourceTimer?
    private let workQueue = DispatchQueue(label: "com.agentmonitor.sessionstore", qos: .utility)

    public let pollingInterval: TimeInterval

    public init(
        adapters: [AgentAdapter],
        maxAgeSeconds: TimeInterval = 6 * 3600,
        pollingInterval: TimeInterval = 15.0
    ) {
        self.adapters = adapters
        self.maxAgeSeconds = maxAgeSeconds
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

        fileWatcher?.stop()
        if let timer = pollingTimer {
            timer.cancel()
            pollingTimer = nil
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
            onSessionsUpdated?(updated)
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
        onSessionsUpdated?(updated)
    }

    @discardableResult
    public func refresh() -> [SessionTransition] {
        lock.lock()
        defer { lock.unlock() }

        var scannedSessions: [String: AgentSession] = [:]
        var successfulAdapters: Set<AgentKind> = []
        for adapter in adapters {
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

        var transitions: [SessionTransition] = []
        let now = Date()

        // 1. Detect removed sessions (or older than maxAge)
        for (id, existing) in sessionCache {
            // Retain existing sessions if their adapter failed to scan in this round
            if !successfulAdapters.contains(existing.kind) {
                continue
            }

            if let fresh = scannedSessions[id] {
                if now.timeIntervalSince(fresh.lastActivity) > maxAgeSeconds {
                    sessionCache.removeValue(forKey: id)
                    transitions.append(.removed(id: id))
                }
            } else {
                sessionCache.removeValue(forKey: id)
                transitions.append(.removed(id: id))
            }
        }

        // 2. Detect added or modified sessions
        for (id, var fresh) in scannedSessions {
            if now.timeIntervalSince(fresh.lastActivity) > maxAgeSeconds {
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
                    } else if existing.state == .completed {
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
            }
        }

        let isInitial = isInitialScan
        isInitialScan = false

        if !transitions.isEmpty {
            let updated = currentSessions
            onSessionsUpdated?(updated)
            if !isInitial {
                for t in transitions {
                    onTransition?(t)
                }
            }
        } else if isInitial {
            let updated = currentSessions
            onSessionsUpdated?(updated)
        }

        return transitions
    }
}
