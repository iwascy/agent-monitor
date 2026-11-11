import Foundation

/// A Paseo conversation retains its host and agent identity even when its provider
/// is also discovered by a native local adapter.
public struct PaseoOrigin: Equatable, Sendable {
    public var serverID: String
    public var agentID: String
    public var hostName: String
    public var isLocal: Bool
    public var provider: String
    public var nativeSessionID: String?
    public var connected: Bool

    public init(serverID: String, agentID: String, hostName: String, isLocal: Bool,
                provider: String, nativeSessionID: String? = nil, connected: Bool = true) {
        self.serverID = serverID; self.agentID = agentID; self.hostName = hostName
        self.isLocal = isLocal; self.provider = provider; self.nativeSessionID = nativeSessionID
        self.connected = connected
    }

    public var locationLabel: String { isLocal ? "本机" : hostName }
    public var displayLabel: String {
        let name: String
        switch provider {
        case "codex": name = "Codex"
        case "claude", "claude-code", "claudeCode": name = "Claude Code"
        case "dsh", "dsh-pi": name = "DSH"
        default: name = provider
        }
        return "Paseo · \(name) · \(locationLabel)" + (connected ? "" : " · 离线")
    }
    public var deepLink: URL? {
        guard !serverID.isEmpty, UUID(uuidString: agentID) != nil,
              let host = serverID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return nil }
        return URL(string: "paseo://h/\(host)/agent/\(agentID)")
    }
    public var localIdentity: String? {
        guard isLocal, let nativeSessionID else { return nil }
        let kind: AgentKind
        switch provider {
        case "codex": kind = .codex
        case "claude", "claude-code", "claudeCode": kind = .claudeCode
        case "dsh", "dsh-pi": kind = .dsh
        default: return nil
        }
        return "\(kind.rawValue):\(nativeSessionID)"
    }
}

public final class PaseoAdapter: AgentAdapter, @unchecked Sendable {
    public let kind: AgentKind = .paseo
    public let home: URL
    public let application: URL
    public var watchPaths: [URL] {
        [home.appendingPathComponent(".paseo/agents"), home.appendingPathComponent(".paseo/server-id"),
         home.appendingPathComponent("Library/Application Support/Paseo/Local Storage/leveldb")]
    }
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.agentmonitor.paseo", qos: .utility)
    private var hosts: [PaseoHostSnapshot] = []
    private var cached: [AgentSession] = []
    private var refreshing = false
    private var lastRefresh = Date.distantPast
    private var hasSnapshot = false
    private var _isPanelVisible = false
    private var lastLevelDBStamp: FileStamp?
    private var localDirCache: [String: (stamp: FileStamp, subdirs: [URL], jsonFiles: [URL])] = [:]
    private var localAgentCache: [String: (stamp: FileStamp, agent: PaseoAgentSnapshot)] = [:]
    private var serverIDCache: (stamp: FileStamp, id: String)?

    /// 异步网络快照完成且会话结果发生变更时的回调（仅由异步刷新触发，不影响同步单元测试）。
    public var onSnapshotUpdated: (@Sendable () -> Void)?

    public var isPanelVisible: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _isPanelVisible }
        set { lock.lock(); _isPanelVisible = newValue; lock.unlock() }
    }

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                application: URL = URL(fileURLWithPath: "/Applications/Paseo.app")) {
        self.home = home
        self.application = application
    }

    /// 根据面板可见性与主机连接健康度动态调整桥接进程轮询间隔，避免在后台或存在离线主机时频繁派生 Electron 进程。
    private func currentRefreshInterval() -> TimeInterval {
        guard hasSnapshot else { return 0 }
        let hasOfflineHost = hosts.contains { !$0.connected }
        if _isPanelVisible {
            return hasOfflineHost ? 15.0 : 8.0
        } else {
            return hasOfflineHost ? 60.0 : 30.0
        }
    }

    /// 当无远程主机且本机 Paseo 守护进程未运行、LevelDB 注册表也未变化时，跳过派生桥接子进程。
    private func canSkipIdleLocalProbe() -> Bool {
        guard hasSnapshot else { return false }
        let hasRemote = hosts.contains { !$0.isLocal }
        let anyConnected = hosts.contains { $0.connected }
        guard !hasRemote && !anyConnected else { return false }

        let levelDBPath = home.appendingPathComponent("Library/Application Support/Paseo/Local Storage/leveldb").path
        let currentLevelDBStamp = FileUtils.fastStat(path: levelDBPath)
        if currentLevelDBStamp != lastLevelDBStamp {
            return false
        }

        if isLocalDaemonRunning() {
            return false
        }
        return true
    }

    private func isLocalDaemonRunning() -> Bool {
        let pidURL = home.appendingPathComponent(".paseo/paseo.pid")
        guard let data = try? Data(contentsOf: pidURL) else { return false }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let pid = json["pid"] as? Int, pid > 1 {
            return kill(Int32(pid), 0) == 0
        }
        if let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           let pid = Int32(raw), pid > 1 {
            return kill(pid, 0) == 0
        }
        return false
    }

    public func scan() throws -> [AgentSession] {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        let interval = currentRefreshInterval()
        if !refreshing && now.timeIntervalSince(lastRefresh) >= interval,
           FileManager.default.fileExists(atPath: application.path) {
            if canSkipIdleLocalProbe() {
                lastRefresh = now
            } else {
                refreshing = true
                lastLevelDBStamp = FileUtils.fastStat(
                    path: home.appendingPathComponent("Library/Application Support/Paseo/Local Storage/leveldb").path
                )
                queue.async { [weak self] in self?.refreshSnapshot() }
            }
        }
        // Local files are also available before the first network snapshot and
        // when Paseo's SDK changes. Only inspect .paseo/agents, never provider history.
        if !hasSnapshot {
            return localSessions()
        }
        var result = cached
        let connectedLocal = hosts.contains { $0.isLocal && $0.connected }
        if !connectedLocal {
            let ids = Set(result.map(\.id))
            let local = localSessions()
            result += local.filter { !ids.contains($0.id) }
        }
        return result
    }

    private func localSessions() -> [AgentSession] {
        let serverIDPath = home.appendingPathComponent(".paseo/server-id")
        guard let sidStamp = FileUtils.fastStat(path: serverIDPath.path) else { return [] }
        let serverID: String
        if let cachedSID = serverIDCache, cachedSID.stamp == sidStamp {
            serverID = cachedSID.id
        } else {
            guard let raw = try? String(contentsOf: serverIDPath, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return [] }
            serverIDCache = (sidStamp, raw)
            serverID = raw
        }

        let root = home.appendingPathComponent(".paseo/agents")
        let fm = FileManager.default
        guard FileUtils.fastStat(path: root.path)?.isDirectory == true else { return [] }

        // 递归遍历 .paseo/agents/<workspace>/*.json（兼容顶层与工作区子目录结构），并按目录 FileStamp 缓存
        var jsonFiles: [URL] = []
        var stack: [URL] = [root]
        var visitedDirs = Set<String>()

        while let dir = stack.popLast() {
            let dirPath = dir.path
            guard visitedDirs.insert(dirPath).inserted,
                  let dirStamp = FileUtils.fastStat(path: dirPath), dirStamp.isDirectory else { continue }

            let cachedEntry: (stamp: FileStamp, subdirs: [URL], jsonFiles: [URL])
            if let hit = localDirCache[dirPath], hit.stamp == dirStamp {
                cachedEntry = hit
            } else {
                let children = (try? fm.contentsOfDirectory(
                    at: dir,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )) ?? []
                var subdirs: [URL] = []
                var jsons: [URL] = []
                for child in children {
                    if child.pathExtension == "json" {
                        jsons.append(child)
                    } else if FileUtils.fastStat(path: child.path)?.isDirectory == true {
                        subdirs.append(child)
                    }
                }
                cachedEntry = (dirStamp, subdirs, jsons)
                localDirCache[dirPath] = cachedEntry
            }
            stack.append(contentsOf: cachedEntry.subdirs)
            jsonFiles.append(contentsOf: cachedEntry.jsonFiles)
        }

        if localDirCache.count > 128 {
            localDirCache = localDirCache.filter { visitedDirs.contains($0.key) }
        }

        var activePaths = Set<String>()
        var sessions: [AgentSession] = []
        let decoder = JSONDecoder()
        for file in jsonFiles {
            let path = file.path
            activePaths.insert(path)
            guard let stamp = FileUtils.fastStat(path: path), !stamp.isDirectory else { continue }
            let agent: PaseoAgentSnapshot
            if let hit = localAgentCache[path], hit.stamp == stamp {
                agent = hit.agent
            } else {
                guard let data = try? Data(contentsOf: file),
                      let decoded = try? decoder.decode(PaseoAgentSnapshot.self, from: data) else { continue }
                localAgentCache[path] = (stamp, decoded)
                agent = decoded
            }
            if let session = agent.session(serverID: serverID, hostName: "本机", isLocal: true, connected: false) {
                sessions.append(session)
            }
        }
        if localAgentCache.count > 128 {
            localAgentCache = localAgentCache.filter { activePaths.contains($0.key) }
        }
        return sessions
    }

    public func refreshNow() { refreshSnapshot() }

    private func refreshSnapshot() {
        let snapshot = Self.readSnapshot(home: home, application: application)
        let before: [AgentSession] = {
            lock.lock(); defer { lock.unlock() }; return cached
        }()
        applySnapshot(snapshot)
        let (after, callback): ([AgentSession], (@Sendable () -> Void)?) = {
            lock.lock(); defer { lock.unlock() }; return (cached, onSnapshotUpdated)
        }()
        if before != after {
            callback?()
        }
    }

    func applySnapshot(_ snapshot: [PaseoHostSnapshot]?) {
        lock.lock()
        defer { lock.unlock() }
        refreshing = false
        lastRefresh = Date()
        guard let snapshot else {
            for i in cached.indices { cached[i] = Self.disconnected(cached[i]) }
            return
        }
        let previous = cached
        hosts = snapshot
        hasSnapshot = true
        cached = snapshot.flatMap { host in
            if host.connected {
                return host.agents.compactMap { $0.session(serverID: host.serverID, hostName: host.hostName,
                                                         isLocal: host.isLocal, connected: true) }
            }
            return previous.filter { $0.paseo?.serverID == host.serverID }.map { session in
                var stale = Self.disconnected(session)
                stale.paseo?.hostName = host.hostName
                return stale
            }
        }
    }

    private static func disconnected(_ session: AgentSession) -> AgentSession {
        var value = session
        value.paseo?.connected = false
        value.state = .idle
        value.suppressCompletion = true
        value.detail = "连接断开 · 状态待同步"
        value.waitingLabel = nil
        return value
    }

    /// SDK work runs outside SessionStore's lock. No shell, PATH dependency, or
    /// daemon startup. SIGTERM lets the bridge release its SDK/SSH transports.
    static func readSnapshot(home: URL, application: URL) -> [PaseoHostSnapshot]? {
        guard let script = Bundle.module.url(forResource: "PaseoBridge", withExtension: "cjs") else { return nil }
        let executable = application.appendingPathComponent("Contents/Frameworks/Paseo Helper.app/Contents/MacOS/Paseo Helper")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { return nil }
        let process = Process(), output = Pipe()
        process.executableURL = executable
        process.arguments = [script.path, application.path, home.path]
        var environment = ProcessInfo.processInfo.environment
        environment["ELECTRON_RUN_AS_NODE"] = "1"
        process.environment = environment
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return nil }
        // Drain concurrently: large directories must not block on pipe capacity.
        let dataLock = NSLock()
        let buffer = PaseoOutputBuffer()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            let data = output.fileHandleForReading.readDataToEndOfFile()
            dataLock.lock(); buffer.data = data; dataLock.unlock()
            drained.signal()
        }
        if finished.wait(timeout: .now() + 12) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 1) == .timedOut { kill(process.processIdentifier, SIGKILL) }
            return nil
        }
        guard drained.wait(timeout: .now() + 1) == .success, process.terminationStatus == 0 else { return nil }
        dataLock.lock(); let data = buffer.data; dataLock.unlock()
        return try? JSONDecoder().decode([PaseoHostSnapshot].self, from: data)
    }

    public static func merging(_ sessions: [AgentSession]) -> [AgentSession] {
        let natives = Dictionary(sessions.filter { $0.paseo == nil }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let replaced = Set(sessions.compactMap { $0.paseo?.localIdentity })
        let aliases = Dictionary(sessions.compactMap { session in
            session.paseo?.localIdentity.map { ($0, session.id) }
        }, uniquingKeysWith: { a, _ in a })
        return sessions.filter { $0.paseo != nil || !replaced.contains($0.id) }.map { original in
            var session = original
            if let parent = session.parentSessionID { session.parentSessionID = aliases[parent] ?? parent }
            if let parent = session.parentId { session.parentId = aliases[parent] ?? parent }
            guard let identity = original.paseo?.localIdentity, let native = natives[identity] else { return session }
            session.usage = native.usage
            session.transcriptPath = native.transcriptPath
            return session
        }
    }
}

private final class PaseoOutputBuffer: @unchecked Sendable { var data = Data() }

struct PaseoHostSnapshot: Decodable, Sendable {
    var serverID: String
    var hostName: String
    var isLocal: Bool
    var connected: Bool
    var agents: [PaseoAgentSnapshot]
}

struct PaseoAgentSnapshot: Decodable, Sendable {
    var id: String
    var provider: String
    var title: String?
    var cwd: String?
    var status: String?
    var lastStatus: String?
    var createdAt: String?
    var updatedAt: String?
    var lastActivityAt: String?
    var requiresAttention: Bool?
    var attentionReason: String?
    var attentionTimestamp: String?
    var pendingPermission: Bool?
    var archivedAt: String?
    var archived: Bool?
    var isArchived: Bool?
    var `internal`: Bool?
    struct Identity: Decodable, Sendable { var sessionId: String? }
    var runtimeInfo: Identity?
    var persistence: Identity?

    func session(serverID: String, hostName: String, isLocal: Bool, connected: Bool) -> AgentSession? {
        guard UUID(uuidString: id) != nil, !serverID.isEmpty, `internal` != true,
              archived != true, isArchived != true, archivedAt?.isEmpty != false else { return nil }
        let rawID = runtimeInfo?.sessionId ?? persistence?.sessionId
        let nativeID: String?
        if let rawID, rawID.hasPrefix("plugin:"), let data = String(rawID.dropFirst(7)).data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let payload = json["data"] as? [String: Any] { nativeID = payload["dshSessionId"] as? String }
        else { nativeID = rawID }
        let origin = PaseoOrigin(serverID: serverID, agentID: id, hostName: hostName, isLocal: isLocal,
                                 provider: provider, nativeSessionID: nativeID, connected: connected)
        let activity = Self.date(lastActivityAt) ?? Self.date(updatedAt) ?? Self.date(createdAt) ?? .distantPast
        let permission = pendingPermission == true || (requiresAttention == true && attentionReason == "permission")
        let state: SessionState
        let detail: String?
        if !connected { state = .idle; detail = "连接断开 · 状态待同步" }
        else if permission { state = .waitingForUser; detail = "等待 Paseo 授权或回复" }
        else if status == "running" || status == "initializing" { state = .running; detail = nil }
        else { state = .idle; detail = (attentionReason == "error" || status == "error") ? "Paseo 会话出错" : nil }
        return AgentSession(id: "paseo:\(serverID):\(id)", kind: .paseo,
                            title: title?.isEmpty == false ? title! : (cwd.map { ($0 as NSString).lastPathComponent } ?? "Paseo 会话"),
                            cwd: cwd, state: state, stateSince: Self.date(attentionTimestamp) ?? activity,
                            lastActivity: activity, detail: detail, waitingLabel: permission && connected ? "等待授权或回复" : nil,
                            suppressCompletion: !connected || attentionReason == "error" || status == "error",
                            paseo: origin)
    }

    static func date(_ text: String?) -> Date? {
        FastDateParser.parse(text)
    }
}
