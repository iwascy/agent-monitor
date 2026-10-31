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

        refresh()
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
        for adapter in adapters {
            if let list = try? adapter.scan() {
                for item in list {
                    scannedSessions[item.id] = item
                }
            }
        }

        var transitions: [SessionTransition] = []
        let now = Date()

        // 1. Detect removed sessions (or older than maxAge)
        for (id, _) in sessionCache {
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

            // Apply read status for completed sessions
            if fresh.state == .completed {
                let key = "\(fresh.id):\(Int64(fresh.lastActivity.timeIntervalSince1970))"
                if readCompletedKeys.contains(key) {
                    fresh.state = .idle
                }
            } else if fresh.state == .running {
                // Clear any read key for this session if it started running again
                readCompletedKeys = readCompletedKeys.filter { !$0.hasPrefix("\(fresh.id):") }
            }

            if let existing = sessionCache[id] {
                if existing.state != fresh.state {
                    transitions.append(.stateChanged(session: fresh, from: existing.state, to: fresh.state))
                }
                sessionCache[id] = fresh
            } else {
                sessionCache[id] = fresh
                transitions.append(.added(fresh))
            }
        }

        if !transitions.isEmpty {
            let updated = currentSessions
            onSessionsUpdated?(updated)
            for t in transitions {
                onTransition?(t)
            }
        }

        return transitions
    }
}
