import Foundation
import SQLite3

/// T3 Code 会话来源元数据，用于副标题展示、精准深链接跳转以及与本地原生会话去重合并。
public struct T3CodeOrigin: Equatable, Sendable {
    public var environmentID: String
    public var threadID: String
    public var provider: String
    public var nativeSessionID: String?

    public init(
        environmentID: String,
        threadID: String,
        provider: String,
        nativeSessionID: String? = nil
    ) {
        self.environmentID = environmentID
        self.threadID = threadID
        self.provider = provider
        self.nativeSessionID = nativeSessionID
    }

    public var providerDisplayName: String {
        switch provider.lowercased() {
        case "antigravity": return "Antigravity"
        case "codex": return "Codex"
        case "claudeagent", "claude", "claude-code", "claudecode": return "Claude Code"
        case "cursor": return "Cursor"
        case "opencode": return "OpenCode"
        case "kiro": return "Kiro"
        case "pi": return "Pi"
        case "dsh", "dsh-pi": return "DSH"
        case "": return ""
        default: return provider
        }
    }

    public var displayLabel: String {
        let name = providerDisplayName
        return name.isEmpty ? "T3 Code" : "T3 Code · \(name)"
    }

    /// 构造 T3 Code 桌面端深链接 `t3code://threads/<environmentID>/<threadID>`。
    public var deepLink: URL? {
        Self.makeDeepLink(environmentID: environmentID, threadID: threadID)
    }

    public static func isValidPathSegment(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        if value == "." || value == ".." || value.contains("..") { return false }
        for scalar in value.unicodeScalars {
            if scalar == "/" || scalar == "\\" || scalar == "?" || scalar == "#" || scalar.properties.isWhitespace {
                return false
            }
        }
        return true
    }

    public static func makeDeepLink(environmentID: String, threadID: String) -> URL? {
        guard isValidPathSegment(environmentID), isValidPathSegment(threadID) else { return nil }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        guard let envSegment = environmentID.addingPercentEncoding(withAllowedCharacters: allowed),
              let threadSegment = threadID.addingPercentEncoding(withAllowedCharacters: allowed) else {
            return nil
        }
        return URL(string: "t3code://threads/\(envSegment)/\(threadSegment)")
    }

    /// 映射到原生本地 Adapter 的会话 ID（用于与 Codex / Claude Code / Antigravity / DSH 去重合并）。
    public var localIdentity: String? {
        guard let nativeSessionID, !nativeSessionID.isEmpty, !nativeSessionID.hasPrefix("pending:") else {
            return nil
        }
        let kind: AgentKind
        switch provider.lowercased() {
        case "codex":
            kind = .codex
        case "claudeagent", "claude", "claude-code", "claudecode":
            kind = .claudeCode
        case "antigravity":
            kind = .antigravity
        case "dsh", "dsh-pi":
            kind = .dsh
        default:
            return nil
        }
        return "\(kind.rawValue):\(nativeSessionID)"
    }
}

public final class T3CodeAdapter: AgentAdapter, @unchecked Sendable {
    public let kind: AgentKind = .t3Code

    public let baseDirectory: URL
    public let maxAgeSeconds: TimeInterval
    public var showUsage: Bool

    private let serverAliveChecker: (@Sendable () -> Bool)?
    private let cacheLock = NSLock()
    private var environmentIDCache: (stamp: FileStamp, id: String)?

    public init(
        baseDirectory: URL? = nil,
        maxAgeSeconds: TimeInterval = 24 * 3600,
        showUsage: Bool = true,
        isServerAlive: (@Sendable () -> Bool)? = nil
    ) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.baseDirectory = baseDirectory ?? home.appendingPathComponent(".t3/userdata")
        self.maxAgeSeconds = maxAgeSeconds
        self.showUsage = showUsage
        self.serverAliveChecker = isServerAlive
    }

    public var watchPaths: [URL] {
        [
            baseDirectory.appendingPathComponent("statev2.sqlite"),
            baseDirectory.appendingPathComponent("server-runtime.json")
        ]
    }

    public struct DatabaseError: Error, CustomStringConvertible {
        public let description: String
    }

    public func scan() throws -> [AgentSession] {
        let dbURL = baseDirectory.appendingPathComponent("statev2.sqlite")
        guard FileManager.default.fileExists(atPath: dbURL.path) else {
            return []
        }

        let now = Date()
        let environmentID = readEnvironmentID()
        let serverAlive = isServerProcessAlive()
        let snapshot = try readSnapshot(dbURL: dbURL)

        guard !snapshot.threads.isEmpty else { return [] }

        let threadsByID = Dictionary(uniqueKeysWithValues: snapshot.threads.map { ($0.threadID, $0) })

        // 筛选候选线程：排除归档/删除，且纯静态导入（无 T3 运行记录）的 import: 线程不纳入；
        // 有近期子线程的祖先线程一并保留。
        var includedIDs = Set<String>()
        for thread in snapshot.threads {
            guard thread.deletedAt == nil, thread.archivedAt == nil else { continue }
            if thread.threadID.hasPrefix("import:") && snapshot.latestRunByThread[thread.threadID] == nil {
                continue
            }
            guard let updated = thread.updatedAt else { continue }
            let isWithinWindow = now.timeIntervalSince(updated) <= maxAgeSeconds
            let hasActiveWork = serverAlive && (
                snapshot.pendingRequestByThread[thread.threadID] != nil ||
                Self.isActiveRunStatus(snapshot.latestRunByThread[thread.threadID]?.status)
            )
            guard isWithinWindow || hasActiveWork else { continue }

            var cursor: ThreadRow? = thread
            var visited = Set<String>()
            while let current = cursor, visited.insert(current.threadID).inserted {
                guard current.deletedAt == nil, current.archivedAt == nil else { break }
                includedIDs.insert(current.threadID)
                if let parentID = current.parentThreadID {
                    cursor = threadsByID[parentID]
                } else {
                    cursor = nil
                }
            }
        }

        guard !includedIDs.isEmpty else { return [] }

        // 仅对保留下来的候选线程按需查询最近 turn_item / 助手消息详情
        let detailMap = (try? readThreadDetails(
            dbURL: dbURL,
            threadIDs: includedIDs,
            pendingRequestByThread: snapshot.pendingRequestByThread,
            latestRunByThread: snapshot.latestRunByThread,
            serverAlive: serverAlive
        )) ?? [:]

        var sessions: [AgentSession] = []
        sessions.reserveCapacity(includedIDs.count)

        for thread in snapshot.threads where includedIDs.contains(thread.threadID) {
            guard let updatedAt = thread.updatedAt else { continue }

            let latestRun = snapshot.latestRunByThread[thread.threadID]
            let pendingRequest = snapshot.pendingRequestByThread[thread.threadID]
            let providerThread = thread.activeProviderThreadID.flatMap { snapshot.providerThreadsByID[$0] }
            let detailInfo = detailMap[thread.threadID]

            let resolvedCwd = thread.worktreePath ?? snapshot.projectWorkspaceByID[thread.projectID]
            let fallbackTitle = resolvedCwd.map { ($0 as NSString).lastPathComponent } ?? "T3 Code"
            let title = thread.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? fallbackTitle
                : thread.title

            let provider = latestRun?.provider
                ?? providerThread?.provider
                ?? thread.providerInstanceID
                ?? thread.defaultProvider

            let origin = T3CodeOrigin(
                environmentID: environmentID,
                threadID: thread.threadID,
                provider: provider,
                nativeSessionID: providerThread?.nativeSessionID
            )

            let state: SessionState
            let stateSince: Date
            var waitingLabel: String? = nil
            var detail: String? = nil
            var detailIsCommand = false
            var suppressCompletion = false

            if serverAlive, let pending = pendingRequest {
                state = .waitingForUser
                waitingLabel = Self.waitingLabel(for: pending.kind)
                stateSince = min(now, pending.createdAt ?? updatedAt)
                if let text = detailInfo?.waitingText, !text.isEmpty {
                    detail = text
                    detailIsCommand = detailInfo?.waitingIsCommand ?? false
                } else {
                    detail = pending.kind == "user_input" ? "等待你回复" : "等待 T3 Code 授权"
                }
            } else if serverAlive, let run = latestRun, run.status == "waiting" {
                state = .waitingForUser
                waitingLabel = "等待授权"
                stateSince = min(now, run.startedAt ?? run.requestedAt ?? updatedAt)
                detail = detailInfo?.waitingText ?? detailInfo?.runningText ?? "等待 T3 Code 授权或回复"
                detailIsCommand = detailInfo?.waitingIsCommand ?? false
            } else if serverAlive, let run = latestRun, Self.isActiveRunStatus(run.status) {
                state = .running
                stateSince = min(now, run.startedAt ?? run.requestedAt ?? updatedAt)
                detail = detailInfo?.runningText ?? "正在思考…"
            } else {
                state = .idle
                stateSince = latestRun?.completedAt ?? updatedAt
                detail = detailInfo?.lastAssistantText
                if !serverAlive {
                    // 服务未运行，避免把残留活跃态或离线状态误升级为已完成
                    suppressCompletion = true
                } else if let run = latestRun {
                    suppressCompletion = (run.status != "completed")
                } else {
                    suppressCompletion = true
                }
            }

            let usage: SessionUsage? = showUsage
                ? buildUsage(
                    providerThread: providerThread,
                    model: thread.model ?? latestRun?.model,
                    updatedAt: providerThread?.updatedAt ?? updatedAt
                )
                : nil

            let parentSessionID: String?
            if let parentID = thread.parentThreadID, parentID != thread.threadID {
                parentSessionID = "\(kind.rawValue):\(parentID)"
            } else {
                parentSessionID = nil
            }

            let session = AgentSession(
                id: "\(kind.rawValue):\(thread.threadID)",
                kind: kind,
                title: title,
                cwd: resolvedCwd,
                state: state,
                stateSince: stateSince,
                lastActivity: updatedAt,
                detail: detail,
                detailIsCommand: detailIsCommand,
                waitingLabel: waitingLabel,
                suppressCompletion: suppressCompletion,
                usage: usage,
                parentSessionID: parentSessionID,
                t3Code: origin
            )
            sessions.append(session)
        }

        return sessions
    }

    /// 将 T3 Code 管理的会话与本地原生 Adapter 扫描到的同一会话去重合并：
    /// 保留 T3 Code 卡片，继承原生会话缺失的用量/日志路径，并把原生子代理的父引用重定向到 T3 Code。
    public static func merging(_ sessions: [AgentSession]) -> [AgentSession] {
        let hasT3 = sessions.contains { $0.t3Code != nil }
        guard hasT3 else { return sessions }

        let natives = Dictionary(
            sessions.filter { $0.t3Code == nil && $0.paseo == nil }.map { ($0.id, $0) },
            uniquingKeysWith: { a, _ in a }
        )
        let replaced = Set(sessions.compactMap { $0.t3Code?.localIdentity })
        guard !replaced.isEmpty else { return sessions }

        let aliases = Dictionary(
            sessions.compactMap { session in
                session.t3Code?.localIdentity.map { ($0, session.id) }
            },
            uniquingKeysWith: { a, _ in a }
        )

        return sessions.filter { $0.t3Code != nil || !replaced.contains($0.id) }.map { original in
            var session = original
            if let parent = session.parentSessionID {
                session.parentSessionID = aliases[parent] ?? parent
            }
            if let parent = session.parentId {
                session.parentId = aliases[parent] ?? parent
            }
            guard let identity = original.t3Code?.localIdentity,
                  let native = natives[identity] else {
                return session
            }
            if session.usage == nil {
                session.usage = native.usage
            }
            if session.transcriptPath == nil {
                session.transcriptPath = native.transcriptPath
            }
            return session
        }
    }

    // MARK: - Server Liveness & Environment ID

    private func isServerProcessAlive() -> Bool {
        if let checker = serverAliveChecker {
            return checker()
        }
        let runtimeURL = baseDirectory.appendingPathComponent("server-runtime.json")
        guard let data = try? Data(contentsOf: runtimeURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = json["pid"] as? Int, pid > 1 else {
            // 无 runtime 文件时，仅在 WAL 存在且近期（2 分钟内）被写入时视为活跃兜底
            let walPath = baseDirectory.appendingPathComponent("statev2.sqlite-wal").path
            guard let stamp = FileUtils.fastStat(path: walPath) else { return false }
            let mtime = Date(timeIntervalSince1970: Double(stamp.mtimeSec) + Double(stamp.mtimeNsec) / 1_000_000_000.0)
            return Date().timeIntervalSince(mtime) < 120
        }
        return kill(Int32(pid), 0) == 0
    }

    private func readEnvironmentID() -> String {
        let envURL = baseDirectory.appendingPathComponent("environment-id")
        guard let stamp = FileUtils.fastStat(path: envURL.path) else { return "" }
        cacheLock.lock()
        if let cached = environmentIDCache, cached.stamp == stamp {
            cacheLock.unlock()
            return cached.id
        }
        cacheLock.unlock()

        let value = (try? String(contentsOf: envURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        cacheLock.lock()
        environmentIDCache = (stamp, value)
        cacheLock.unlock()
        return value
    }

    private static func isActiveRunStatus(_ status: String?) -> Bool {
        guard let status else { return false }
        switch status {
        case "preparing", "queued", "starting", "running":
            return true
        default:
            return false
        }
    }

    private static func waitingLabel(for kind: String) -> String {
        switch kind {
        case "user_input":
            return "在问你"
        default:
            return "等待授权"
        }
    }

    private func buildUsage(providerThread: ProviderThreadRow?, model: String?, updatedAt: Date) -> SessionUsage? {
        guard let pt = providerThread, let cu = pt.contextUsage else { return nil }
        guard cu.usedTokens > 0 || (cu.inputTokens ?? 0) > 0 || (cu.outputTokens ?? 0) > 0 else {
            return nil
        }
        return SessionUsage(
            model: model,
            inputTokens: cu.inputTokens,
            cachedInputTokens: cu.cachedInputTokens,
            outputTokens: cu.outputTokens,
            reasoningTokens: cu.reasoningOutputTokens,
            contextTokens: cu.usedTokens,
            contextWindow: cu.maxTokens,
            updatedAt: updatedAt
        )
    }

    // MARK: - SQLite Read-Only Access

    private struct ThreadRow {
        let threadID: String
        let projectID: String
        let title: String
        let defaultProvider: String
        let providerInstanceID: String?
        let activeProviderThreadID: String?
        let updatedAt: Date?
        let archivedAt: String?
        let deletedAt: String?
        let worktreePath: String?
        let parentThreadID: String?
        let model: String?
    }

    private struct RunRow {
        let runID: String
        let threadID: String
        let ordinal: Int
        let provider: String
        let status: String
        let requestedAt: Date?
        let startedAt: Date?
        let completedAt: Date?
        let model: String?
    }

    private struct RuntimeRequestRow {
        let requestID: String
        let threadID: String
        let kind: String
        let status: String
        let createdAt: Date?
    }

    private struct ContextUsageData {
        let usedTokens: Int
        let maxTokens: Int?
        let inputTokens: Int?
        let cachedInputTokens: Int?
        let outputTokens: Int?
        let reasoningOutputTokens: Int?
    }

    private struct ProviderThreadRow {
        let providerThreadID: String
        let provider: String
        let nativeSessionID: String?
        let contextUsage: ContextUsageData?
        let updatedAt: Date?
    }

    private struct DatabaseSnapshot {
        var projectWorkspaceByID: [String: String] = [:]
        var threads: [ThreadRow] = []
        var latestRunByThread: [String: RunRow] = [:]
        var pendingRequestByThread: [String: RuntimeRequestRow] = [:]
        var providerThreadsByID: [String: ProviderThreadRow] = [:]
    }

    private struct ThreadDetailInfo {
        var waitingText: String? = nil
        var waitingIsCommand: Bool = false
        var runningText: String? = nil
        var lastAssistantText: String? = nil
    }

    /// 以只读模式打开 WAL 数据库；无 `-wal` 时回退 `immutable=1`，避免创建 `-shm` 失败。
    private func openReadOnlyDatabase(dbURL: URL) throws -> OpaquePointer {
        let walExists = FileManager.default.fileExists(atPath: dbURL.path + "-wal")
        var uris = ["file:\(dbURL.path)?mode=ro"]
        if !walExists {
            uris.append("file:\(dbURL.path)?mode=ro&immutable=1")
        }

        var lastError = "unknown"
        for uri in uris {
            var db: OpaquePointer?
            let rc = sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
            guard rc == SQLITE_OK, let database = db else {
                lastError = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed (\(rc))"
                sqlite3_close(db)
                continue
            }
            sqlite3_busy_timeout(database, 300)

            // 做一次极轻的探测查询确认快照可读（无 -wal 时 mode=ro 会在首次 prepare 报 CANTOPEN）
            var probeStmt: OpaquePointer?
            if sqlite3_prepare_v2(database, "SELECT 1 FROM sqlite_master LIMIT 1", -1, &probeStmt, nil) == SQLITE_OK {
                sqlite3_finalize(probeStmt)
                return database
            }
            lastError = String(cString: sqlite3_errmsg(database))
            sqlite3_finalize(probeStmt)
            sqlite3_close(database)
        }
        throw DatabaseError(description: "statev2.sqlite: \(lastError)")
    }

    private func existingTables(in db: OpaquePointer) throws -> Set<String> {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type='table'", -1, &stmt, nil) == SQLITE_OK,
              let statement = stmt else {
            throw DatabaseError(description: "statev2.sqlite: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(statement) }
        var tables = Set<String>()
        var rc = sqlite3_step(statement)
        while rc == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 0) {
                tables.insert(String(cString: text))
            }
            rc = sqlite3_step(statement)
        }
        guard rc == SQLITE_DONE else {
            throw DatabaseError(description: "statev2.sqlite: \(String(cString: sqlite3_errmsg(db)))")
        }
        return tables
    }

    private func readSnapshot(dbURL: URL) throws -> DatabaseSnapshot {
        let db = try openReadOnlyDatabase(dbURL: dbURL)
        defer { sqlite3_close(db) }

        let tables = try existingTables(in: db)
        guard tables.contains("orchestration_v2_projection_threads") else {
            return DatabaseSnapshot()
        }

        var snapshot = DatabaseSnapshot()

        // 1. 项目工作目录
        if tables.contains("projection_projects") {
            let sql = "SELECT project_id, workspace_root FROM projection_projects WHERE deleted_at IS NULL"
            try queryRows(db: db, sql: sql) { stmt in
                guard let pidPtr = sqlite3_column_text(stmt, 0),
                      let wsPtr = sqlite3_column_text(stmt, 1) else { return }
                let pid = String(cString: pidPtr)
                let ws = String(cString: wsPtr)
                if !ws.isEmpty {
                    snapshot.projectWorkspaceByID[pid] = ws
                }
            }
        }

        // 2. 线程列表
        let threadSQL = """
        SELECT thread_id, project_id, title, default_provider, provider_instance_id,
               active_provider_thread_id, updated_at, archived_at, deleted_at, payload_json
        FROM orchestration_v2_projection_threads
        ORDER BY updated_at DESC
        """
        try queryRows(db: db, sql: threadSQL) { stmt in
            guard let tidPtr = sqlite3_column_text(stmt, 0),
                  let pidPtr = sqlite3_column_text(stmt, 1) else { return }
            let threadID = String(cString: tidPtr)
            let projectID = String(cString: pidPtr)
            let title = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
            let defaultProvider = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
            let providerInstanceID = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
            let activeProviderThreadID = sqlite3_column_text(stmt, 5).map { String(cString: $0) }
            let updatedAt = sqlite3_column_text(stmt, 6).flatMap { FastDateParser.parse(cString: $0) }
            let archivedAt = sqlite3_column_text(stmt, 7).map { String(cString: $0) }
            let deletedAt = sqlite3_column_text(stmt, 8).map { String(cString: $0) }

            var worktreePath: String? = nil
            var parentThreadID: String? = nil
            var model: String? = nil
            if let payloadPtr = sqlite3_column_text(stmt, 9) {
                let payloadStr = String(cString: payloadPtr)
                if let data = payloadStr.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if let wt = obj["worktreePath"] as? String, !wt.isEmpty {
                        worktreePath = wt
                    }
                    if let lineage = obj["lineage"] as? [String: Any],
                       let parent = lineage["parentThreadId"] as? String, !parent.isEmpty {
                        parentThreadID = parent
                    }
                    if let sel = obj["modelSelection"] as? [String: Any],
                       let m = sel["model"] as? String, !m.isEmpty {
                        model = m
                    }
                }
            }

            snapshot.threads.append(ThreadRow(
                threadID: threadID,
                projectID: projectID,
                title: title,
                defaultProvider: defaultProvider,
                providerInstanceID: providerInstanceID,
                activeProviderThreadID: activeProviderThreadID,
                updatedAt: updatedAt,
                archivedAt: archivedAt,
                deletedAt: deletedAt,
                worktreePath: worktreePath,
                parentThreadID: parentThreadID,
                model: model
            ))
        }

        // 3. 每个线程的最新 run（按 ordinal 降序取最大）
        if tables.contains("orchestration_v2_projection_runs") {
            let runSQL = """
            SELECT run_id, thread_id, ordinal, provider, provider_instance_id,
                   status, requested_at, completed_at, payload_json
            FROM orchestration_v2_projection_runs
            ORDER BY ordinal DESC
            """
            try queryRows(db: db, sql: runSQL) { stmt in
                guard let runIDPtr = sqlite3_column_text(stmt, 0),
                      let tidPtr = sqlite3_column_text(stmt, 1) else { return }
                let threadID = String(cString: tidPtr)
                let ordinal = Int(sqlite3_column_int(stmt, 2))
                if let existing = snapshot.latestRunByThread[threadID], existing.ordinal >= ordinal {
                    return
                }
                let runID = String(cString: runIDPtr)
                let provider = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
                    ?? sqlite3_column_text(stmt, 3).map { String(cString: $0) }
                    ?? ""
                let status = sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? ""
                let requestedAt = sqlite3_column_text(stmt, 6).flatMap { FastDateParser.parse(cString: $0) }
                let completedAt = sqlite3_column_text(stmt, 7).flatMap { FastDateParser.parse(cString: $0) }

                var startedAt: Date? = nil
                var model: String? = nil
                if let payloadPtr = sqlite3_column_text(stmt, 8) {
                    let payloadStr = String(cString: payloadPtr)
                    if let data = payloadStr.data(using: .utf8),
                       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        if let s = obj["startedAt"] as? String {
                            startedAt = FastDateParser.parse(s)
                        }
                        if let sel = obj["modelSelection"] as? [String: Any],
                           let m = sel["model"] as? String, !m.isEmpty {
                            model = m
                        }
                    }
                }

                snapshot.latestRunByThread[threadID] = RunRow(
                    runID: runID,
                    threadID: threadID,
                    ordinal: ordinal,
                    provider: provider,
                    status: status,
                    requestedAt: requestedAt,
                    startedAt: startedAt,
                    completedAt: completedAt,
                    model: model
                )
            }
        }

        // 4. 待处理运行时请求（审批或用户输入）
        if tables.contains("orchestration_v2_projection_runtime_requests") {
            let reqSQL = """
            SELECT runtime_request_id, thread_id, kind, status, created_at
            FROM orchestration_v2_projection_runtime_requests
            WHERE status IN ('pending', 'waiting')
            ORDER BY created_at ASC
            """
            try queryRows(db: db, sql: reqSQL) { stmt in
                guard let reqIDPtr = sqlite3_column_text(stmt, 0),
                      let tidPtr = sqlite3_column_text(stmt, 1) else { return }
                let threadID = String(cString: tidPtr)
                // 保留最早打开的待处理请求，准确反映已等待时长
                if snapshot.pendingRequestByThread[threadID] != nil { return }
                snapshot.pendingRequestByThread[threadID] = RuntimeRequestRow(
                    requestID: String(cString: reqIDPtr),
                    threadID: threadID,
                    kind: sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? "permission",
                    status: sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "pending",
                    createdAt: sqlite3_column_text(stmt, 4).flatMap { FastDateParser.parse(cString: $0) }
                )
            }
        }

        // 5. Provider threads（提取 nativeSessionID 与 contextUsage）
        if tables.contains("orchestration_v2_projection_provider_threads") {
            let activePTIDs = Set(snapshot.threads.compactMap(\.activeProviderThreadID))
            if !activePTIDs.isEmpty {
                let ptSQL = """
                SELECT provider_thread_id, provider, provider_instance_id, updated_at, payload_json
                FROM orchestration_v2_projection_provider_threads
                """
                try queryRows(db: db, sql: ptSQL) { stmt in
                    guard let ptIDPtr = sqlite3_column_text(stmt, 0) else { return }
                    let ptID = String(cString: ptIDPtr)
                    guard activePTIDs.contains(ptID) else { return }
                    let provider = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
                        ?? sqlite3_column_text(stmt, 1).map { String(cString: $0) }
                        ?? ""
                    let updatedAt = sqlite3_column_text(stmt, 3).flatMap { FastDateParser.parse(cString: $0) }

                    var nativeSessionID: String? = nil
                    var contextUsage: ContextUsageData? = nil
                    if let payloadPtr = sqlite3_column_text(stmt, 4),
                       let data = String(cString: payloadPtr).data(using: .utf8),
                       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        if let ref = obj["nativeThreadRef"] as? [String: Any],
                           let nid = ref["nativeId"] as? String,
                           !nid.isEmpty, !nid.hasPrefix("pending:") {
                            nativeSessionID = nid
                        }
                        if let cu = obj["contextUsage"] as? [String: Any],
                           let used = cu["usedTokens"] as? Int {
                            contextUsage = ContextUsageData(
                                usedTokens: used,
                                maxTokens: cu["maxTokens"] as? Int,
                                inputTokens: cu["inputTokens"] as? Int,
                                cachedInputTokens: cu["cachedInputTokens"] as? Int,
                                outputTokens: cu["outputTokens"] as? Int,
                                reasoningOutputTokens: cu["reasoningOutputTokens"] as? Int
                            )
                        }
                    }

                    snapshot.providerThreadsByID[ptID] = ProviderThreadRow(
                        providerThreadID: ptID,
                        provider: provider,
                        nativeSessionID: nativeSessionID,
                        contextUsage: contextUsage,
                        updatedAt: updatedAt
                    )
                }
            }
        }

        return snapshot
    }

    private func readThreadDetails(
        dbURL: URL,
        threadIDs: Set<String>,
        pendingRequestByThread: [String: RuntimeRequestRow],
        latestRunByThread: [String: RunRow],
        serverAlive: Bool
    ) throws -> [String: ThreadDetailInfo] {
        let db = try openReadOnlyDatabase(dbURL: dbURL)
        defer { sqlite3_close(db) }

        let tables = try existingTables(in: db)
        let hasTurnItems = tables.contains("orchestration_v2_projection_turn_items")
        let hasMessages = tables.contains("orchestration_v2_projection_messages")

        var result: [String: ThreadDetailInfo] = [:]

        for threadID in threadIDs {
            var info = ThreadDetailInfo()
            let pendingReq = serverAlive ? pendingRequestByThread[threadID] : nil
            let latestRun = latestRunByThread[threadID]
            let isWaiting = pendingReq != nil || (serverAlive && latestRun?.status == "waiting")
            let isRunning = serverAlive && Self.isActiveRunStatus(latestRun?.status)

            if isWaiting && hasTurnItems {
                let waitSQL = """
                SELECT type, payload_json
                FROM orchestration_v2_projection_turn_items
                WHERE thread_id = ? AND type IN ('approval_request', 'user_input_request')
                ORDER BY ordinal DESC
                LIMIT 5
                """
                try queryRows(db: db, sql: waitSQL, bindStrings: [threadID]) { stmt in
                    guard info.waitingText == nil else { return }
                    guard let typePtr = sqlite3_column_text(stmt, 0),
                          let payloadPtr = sqlite3_column_text(stmt, 1) else { return }
                    let itemType = String(cString: typePtr)
                    guard let data = String(cString: payloadPtr).data(using: .utf8),
                          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

                    if let targetReqID = pendingReq?.requestID,
                       let itemReqID = obj["requestId"] as? String,
                       itemReqID != targetReqID {
                        return
                    }

                    if itemType == "approval_request" {
                        let reqKind = obj["requestKind"] as? String
                        let text = firstNonEmpty(
                            obj["prompt"] as? String,
                            obj["reason"] as? String,
                            obj["title"] as? String
                        )
                        if let text {
                            info.waitingText = Self.trimmedDetail(text)
                            info.waitingIsCommand = (reqKind == "command")
                        }
                    } else if itemType == "user_input_request" {
                        if let questions = obj["questions"] as? [[String: Any]],
                           let firstQ = questions.first {
                            let text = firstNonEmpty(
                                firstQ["question"] as? String,
                                firstQ["header"] as? String,
                                firstQ["prompt"] as? String,
                                obj["title"] as? String
                            )
                            if let text {
                                info.waitingText = Self.trimmedDetail(text)
                            }
                        } else if let title = obj["title"] as? String, !title.isEmpty {
                            info.waitingText = Self.trimmedDetail(title)
                        }
                    }
                }
            }

            if isRunning && hasTurnItems {
                let runSQL = """
                SELECT type, status, payload_json
                FROM orchestration_v2_projection_turn_items
                WHERE thread_id = ? AND type NOT IN ('user_message', 'checkpoint', 'notification')
                ORDER BY CASE WHEN status = 'running' THEN 0 ELSE 1 END, ordinal DESC
                LIMIT 3
                """
                try queryRows(db: db, sql: runSQL, bindStrings: [threadID]) { stmt in
                    guard info.runningText == nil else { return }
                    guard let typePtr = sqlite3_column_text(stmt, 0),
                          let payloadPtr = sqlite3_column_text(stmt, 2) else { return }
                    let itemType = String(cString: typePtr)
                    let payloadStr = String(cString: payloadPtr)
                    let obj = payloadStr.data(using: .utf8).flatMap {
                        try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
                    }
                    info.runningText = Self.formatRunningDetail(type: itemType, payload: obj)
                }
            }

            if !isWaiting && !isRunning && hasMessages {
                let msgSQL = """
                SELECT payload_json
                FROM orchestration_v2_projection_messages
                WHERE thread_id = ? AND role = 'assistant'
                ORDER BY updated_at DESC
                LIMIT 1
                """
                try queryRows(db: db, sql: msgSQL, bindStrings: [threadID]) { stmt in
                    guard let payloadPtr = sqlite3_column_text(stmt, 0),
                          let data = String(cString: payloadPtr).data(using: .utf8),
                          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let text = obj["text"] as? String else { return }
                    let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !cleaned.isEmpty {
                        info.lastAssistantText = Self.trimmedDetail(cleaned)
                    }
                }
            }

            result[threadID] = info
        }

        return result
    }

    private func queryRows(
        db: OpaquePointer,
        sql: String,
        bindStrings: [String] = [],
        onRow: (OpaquePointer) -> Void
    ) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let statement = stmt else {
            throw DatabaseError(description: "statev2.sqlite: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(statement) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (idx, value) in bindStrings.enumerated() {
            sqlite3_bind_text(statement, Int32(idx + 1), value, -1, transient)
        }

        var rc = sqlite3_step(statement)
        while rc == SQLITE_ROW {
            onRow(statement)
            rc = sqlite3_step(statement)
        }
        guard rc == SQLITE_DONE else {
            throw DatabaseError(description: "statev2.sqlite: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    private static func formatRunningDetail(type: String, payload: [String: Any]?) -> String? {
        let title = (payload?["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch type {
        case "command_execution":
            if let input = payload?["input"] as? String {
                let firstLine = input
                    .split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .first { !$0.isEmpty }
                if let cmd = firstLine {
                    return "正在运行 \(trimmedDetail(cmd, limit: 64))"
                }
            }
            if let title, !title.isEmpty { return title }
            return "正在执行命令…"
        case "file_change":
            if let fileName = payload?["fileName"] as? String, !fileName.isEmpty {
                return "正在修改 \((fileName as NSString).lastPathComponent)"
            }
            return title?.isEmpty == false ? title : "正在修改文件…"
        case "dynamic_tool", "tool_call", "mcp_tool_call":
            if let title, !title.isEmpty {
                return trimmedDetail(title, limit: 80)
            }
            if let tool = payload?["toolName"] as? String, !tool.isEmpty {
                return "正在运行 \(tool)…"
            }
            return "正在调用工具…"
        case "web_search":
            return title?.isEmpty == false ? title : "正在搜索网页…"
        case "reasoning":
            return "正在思考…"
        case "assistant_message":
            return "正在生成回复…"
        case "todo_list", "proposed_plan":
            return "正在规划任务…"
        default:
            if let title, !title.isEmpty { return trimmedDetail(title, limit: 80) }
            return nil
        }
    }

    private func firstNonEmpty(_ values: String?...) -> String? {
        for v in values {
            if let trimmed = v?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    private static func trimmedDetail(_ raw: String, limit: Int = 80) -> String {
        let singleLine = raw
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if singleLine.count > limit {
            return String(singleLine.prefix(limit)) + "…"
        }
        return singleLine
    }
}
