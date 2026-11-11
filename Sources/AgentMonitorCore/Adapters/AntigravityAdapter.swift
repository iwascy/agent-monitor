import Foundation
import SQLite3

public final class AntigravityAdapter: AgentAdapter, @unchecked Sendable {
    public let kind: AgentKind = .antigravity

    public let baseDirectory: URL
    public let isLockHeld: @Sendable (String) -> Bool
    public let maxAgeSeconds: TimeInterval
    public var showUsage: Bool

    private let usesDefaultLockCheck: Bool
    private let cacheLock = NSLock()
    private var schemaColumnsCache: [String: Set<String>] = [:]
    private var transcriptCache: [String: (stamp: FileStamp, info: TranscriptInfo)] = [:]
    private var cwdCache: [String: String?] = [:]

    public init(
        baseDirectory: URL? = nil,
        isLockHeld: (@Sendable (String) -> Bool)? = nil,
        maxAgeSeconds: TimeInterval = 24 * 3600,
        showUsage: Bool = true
    ) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.baseDirectory = baseDirectory ?? home.appendingPathComponent(".gemini/antigravity")
        self.usesDefaultLockCheck = (isLockHeld == nil)
        self.isLockHeld = isLockHeld ?? { path in
            guard FileManager.default.fileExists(atPath: path) else { return false }
            let fd = open(path, O_RDONLY)
            guard fd >= 0 else { return false }
            defer { close(fd) }

            let ret = flock(fd, LOCK_EX | LOCK_NB)
            if ret != 0 {
                let err = errno
                return err == EWOULDBLOCK || err == EAGAIN
            } else {
                flock(fd, LOCK_UN)
                return false
            }
        }
        self.maxAgeSeconds = maxAgeSeconds
        self.showUsage = showUsage
    }

    public var watchPaths: [URL] {
        let summariesDB = baseDirectory.appendingPathComponent("conversation_summaries.db")
        let presenceDir = baseDirectory.appendingPathComponent("presence")
        let brainDir = baseDirectory.appendingPathComponent("brain")
        return [summariesDB, presenceDir, brainDir]
    }

    public func scan() throws -> [AgentSession] {
        let fm = FileManager.default
        let summariesDBURL = baseDirectory.appendingPathComponent("conversation_summaries.db")
        guard fm.fileExists(atPath: summariesDBURL.path) else {
            return []
        }

        let presenceDir = baseDirectory.appendingPathComponent("presence")
        let brainDir = baseDirectory.appendingPathComponent("brain")
        let now = Date()

        // Read conversation_summaries.db safely via SQLite read-only mode
        let rows = try readSummaries(dbURL: summariesDBURL)
        var results: [AgentSession] = []

        // 默认锁检测模式下，先一次性读取 presence 目录中实际存在的 .lock 文件集合，避免对大量过期行逐个发起系统调用
        let existingLockNames: Set<String>? = usesDefaultLockCheck
            ? Set((try? fm.contentsOfDirectory(atPath: presenceDir.path)) ?? [])
            : nil

        let rowsByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.conversationId, $0) })
        // Keep ancestors of recent children, even if the parent itself has not written recently.
        var includedIDs = Set<String>()
        for row in rows where !row.killed || !row.parentConversationID.isEmpty {
            guard let modified = row.lastModified else { continue }
            let isWithinWindow = now.timeIntervalSince(modified) <= maxAgeSeconds
            if !isWithinWindow {
                let lockFileName = "\(row.conversationId).lock"
                if let existingLockNames, !existingLockNames.contains(lockFileName) {
                    continue
                }
                let lockPath = presenceDir.appendingPathComponent(lockFileName).path
                guard isLockHeld(lockPath) else { continue }
            }
            var current: SummaryRow? = row
            var visited = Set<String>()
            while let ancestor = current, visited.insert(ancestor.conversationId).inserted {
                includedIDs.insert(ancestor.conversationId)
                current = rowsByID[ancestor.parentConversationID]
            }
        }

        var activeTranscriptPaths = Set<String>()

        for row in rows where includedIDs.contains(row.conversationId) {

            guard let lastModified = row.lastModified else {
                continue
            }

            // Parse CWD from workspace_uris（带缓存）
            let resolvedCwd = resolveWorkspaceCwd(row.workspaceUris)

            var fallbackTitle = resolvedCwd.map { ($0 as NSString).lastPathComponent } ?? "Antigravity"
            if !row.parentConversationID.isEmpty {
                if !row.agentName.isEmpty && row.agentName != "self" {
                    fallbackTitle = row.agentName
                } else if fallbackTitle.hasPrefix("subagent-") {
                    fallbackTitle = String(fallbackTitle.dropFirst("subagent-".count))
                    if let suffix = fallbackTitle.range(of: "-self-", options: .backwards) {
                        fallbackTitle = String(fallbackTitle[..<suffix.lowerBound])
                    }
                    fallbackTitle = fallbackTitle.replacingOccurrences(of: "-", with: " ")
                } else {
                    fallbackTitle = "子代理 · \(row.conversationId.prefix(8))"
                }
            }
            let title = !row.title.isEmpty ? row.title : fallbackTitle

            let isActiveRow = !row.killed && (row.status == "CASCADE_RUN_STATUS_RUNNING" || row.notFullyIdle)
            let needsTranscriptForIdleDetail = row.preview.isEmpty || row.preview == title

            let transcriptURL = brainDir.appendingPathComponent(row.conversationId).appendingPathComponent(".system_generated/logs/transcript.jsonl")
            let transcriptInfo: TranscriptInfo
            if isActiveRow || needsTranscriptForIdleDetail {
                activeTranscriptPaths.insert(transcriptURL.path)
                transcriptInfo = cachedTranscriptInfo(url: transcriptURL)
            } else {
                // 空闲会话已有有效 preview 时无需触碰磁盘读取 transcript.jsonl
                transcriptInfo = TranscriptInfo()
            }

            var state: SessionState = .idle
            var waitingLabel: String? = nil
            var detail: String? = nil

            if isActiveRow {
                if transcriptInfo.isWaiting {
                    state = .waitingForUser
                    waitingLabel = "在问你"
                    detail = transcriptInfo.waitingText ?? "等待用户确认或输入"
                } else {
                    state = .running
                    detail = transcriptInfo.runningText ?? "正在思考…"
                }
            } else {
                // CASCADE_RUN_STATUS_IDLE
                state = .idle
                // If preview equals title or preview is empty, use the last planner response content
                if !row.preview.isEmpty && row.preview != title {
                    detail = row.preview
                } else {
                    detail = transcriptInfo.lastPlannerText
                }
            }

            let stateSince: Date
            switch state {
            case .running:
                var start = row.lastUserInput
                if start == nil && !row.parentConversationID.isEmpty {
                    start = (try? transcriptURL.resourceValues(forKeys: [.creationDateKey]))?.creationDate
                }
                stateSince = min(now, start ?? lastModified)
            case .waitingForUser:
                stateSince = min(now, transcriptInfo.waitingSince ?? lastModified)
            case .completed, .idle:
                stateSince = lastModified
            }

            let session = AgentSession(
                id: "\(kind.rawValue):\(row.conversationId)",
                kind: kind,
                title: title,
                cwd: resolvedCwd,
                state: state,
                stateSince: stateSince,
                lastActivity: lastModified,
                detail: detail,
                detailIsCommand: false,
                waitingLabel: waitingLabel,
                suppressCompletion: row.killed,
                usage: showUsage ? SessionUsage(steps: row.stepCount, updatedAt: lastModified) : nil,
                parentSessionID: row.parentConversationID.isEmpty ? nil : "\(kind.rawValue):\(row.parentConversationID)"
            )
            results.append(session)
        }

        pruneCachesIfNeeded(keepingTranscriptPaths: activeTranscriptPaths)
        return results
    }

    private func resolveWorkspaceCwd(_ workspaceUris: String) -> String? {
        guard !workspaceUris.isEmpty, workspaceUris != "[]" else { return nil }
        cacheLock.lock()
        if let hit = cwdCache[workspaceUris] {
            cacheLock.unlock()
            return hit
        }
        cacheLock.unlock()

        var resolvedCwd: String? = nil
        if let urisData = workspaceUris.data(using: .utf8),
           let uriArray = try? JSONSerialization.jsonObject(with: urisData) as? [String],
           let firstUri = uriArray.first {
            if firstUri.hasPrefix("file://") {
                resolvedCwd = URL(string: firstUri)?.path
            } else {
                resolvedCwd = firstUri
            }
        }

        cacheLock.lock()
        if cwdCache.count > 512 {
            cwdCache.removeAll(keepingCapacity: true)
        }
        cwdCache[workspaceUris] = resolvedCwd
        cacheLock.unlock()
        return resolvedCwd
    }

    private func cachedTranscriptInfo(url: URL) -> TranscriptInfo {
        let path = url.path
        guard let stamp = FileUtils.fastStat(path: path) else {
            cacheLock.lock()
            transcriptCache.removeValue(forKey: path)
            cacheLock.unlock()
            return TranscriptInfo()
        }

        cacheLock.lock()
        if let cached = transcriptCache[path], cached.stamp == stamp {
            cacheLock.unlock()
            return cached.info
        }
        cacheLock.unlock()

        let info = inspectTranscript(url: url)

        cacheLock.lock()
        transcriptCache[path] = (stamp, info)
        cacheLock.unlock()
        return info
    }

    private func pruneCachesIfNeeded(keepingTranscriptPaths: Set<String>) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if transcriptCache.count > 128 {
            transcriptCache = transcriptCache.filter { keepingTranscriptPaths.contains($0.key) }
        }
    }

    private struct SummaryRow {
        let conversationId: String
        let title: String
        let preview: String
        let workspaceUris: String
        let status: String
        let notFullyIdle: Bool
        let killed: Bool
        let lastModified: Date?
        let stepCount: Int
        let parentConversationID: String
        let agentName: String
        let lastUserInput: Date?
    }

    public struct DatabaseError: Error, CustomStringConvertible {
        public let description: String
    }

    /// Opens the summaries DB read-only and prepares `query`.
    /// The DB is in WAL mode. While Antigravity is idle it checkpoints and deletes `-wal`/`-shm`,
    /// and a `mode=ro` connection then fails with SQLITE_CANTOPEN because it cannot create `-shm`.
    /// In that case the main file is a complete snapshot, so `immutable=1` is safe.
    private func openAndPrepare(dbURL: URL, query: String) throws -> (db: OpaquePointer, statement: OpaquePointer) {
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

            var statement: OpaquePointer?
            if sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK, let stmt = statement {
                return (database, stmt)
            }
            lastError = String(cString: sqlite3_errmsg(database))
            sqlite3_finalize(statement)
            sqlite3_close(database)
        }
        throw DatabaseError(description: "conversation_summaries.db: \(lastError)")
    }

    private static func buildSummariesQuery(columns: Set<String>) -> String {
        let stepExpr = columns.contains("step_count") ? "step_count" : "0 AS step_count"
        let parentExpr = columns.contains("parent_conversation_id") ? "parent_conversation_id" : "''"
        let nameExpr = columns.contains("agent_name") ? "agent_name" : "''"
        let userInputExpr = columns.contains("last_user_input_time") ? "last_user_input_time" : "''"
        return """
        SELECT conversation_id, title, preview, workspace_uris, status, not_fully_idle, killed, last_modified_time, \(stepExpr), \(parentExpr), \(nameExpr), \(userInputExpr)
        FROM conversation_summaries
        ORDER BY last_modified_time DESC
        """
    }

    private func readSummaries(dbURL: URL) throws -> [SummaryRow] {
        cacheLock.lock()
        let cachedColumns = schemaColumnsCache[dbURL.path]
        cacheLock.unlock()

        let database: OpaquePointer
        let stmt: OpaquePointer

        if let cachedColumns {
            let query = Self.buildSummariesQuery(columns: cachedColumns)
            if let prepared = try? openAndPrepare(dbURL: dbURL, query: query) {
                database = prepared.db
                stmt = prepared.statement
            } else {
                // 表结构可能变更或数据库不可读，清除缓存后重新探测
                cacheLock.lock()
                schemaColumnsCache.removeValue(forKey: dbURL.path)
                cacheLock.unlock()
                let probed = try openAndPrepareWithSchemaProbe(dbURL: dbURL)
                database = probed.db
                stmt = probed.statement
            }
        } else {
            let probed = try openAndPrepareWithSchemaProbe(dbURL: dbURL)
            database = probed.db
            stmt = probed.statement
        }

        defer {
            sqlite3_finalize(stmt)
            sqlite3_close(database)
        }

        var rows: [SummaryRow] = []
        rows.reserveCapacity(128)

        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW {
            defer { rc = sqlite3_step(stmt) }
            guard let idText = sqlite3_column_text(stmt, 0) else { continue }
            let convId = String(cString: idText)
            let title = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let preview = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
            let wsUris = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
            let status = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""
            let notIdle = sqlite3_column_int(stmt, 5) != 0
            let killed = sqlite3_column_int(stmt, 6) != 0

            var modDate: Date? = nil
            if let dateStr = sqlite3_column_text(stmt, 7) {
                modDate = FastDateParser.parse(cString: dateStr)
            }

            let stepCount = Int(sqlite3_column_int(stmt, 8))

            var userInputDate: Date? = nil
            if let dateStr = sqlite3_column_text(stmt, 11) {
                if let parsed = FastDateParser.parse(cString: dateStr), parsed.timeIntervalSince1970 > 1577836800 { // after 2020-01-01
                    userInputDate = parsed
                }
            }

            // If date parsing fails, modDate remains nil, row will be skipped in scan()
            rows.append(SummaryRow(
                conversationId: convId,
                title: title,
                preview: preview,
                workspaceUris: wsUris,
                status: status,
                notFullyIdle: notIdle,
                killed: killed,
                lastModified: modDate,
                stepCount: stepCount,
                parentConversationID: sqlite3_column_text(stmt, 9).map { String(cString: $0) } ?? "",
                agentName: sqlite3_column_text(stmt, 10).map { String(cString: $0) } ?? "",
                lastUserInput: userInputDate
            ))
        }
        guard rc == SQLITE_DONE else {
            throw DatabaseError(description: "conversation_summaries.db: \(String(cString: sqlite3_errmsg(database)))")
        }

        return rows
    }

    private func openAndPrepareWithSchemaProbe(dbURL: URL) throws -> (db: OpaquePointer, statement: OpaquePointer) {
        let (database, pragmaStmt) = try openAndPrepare(dbURL: dbURL, query: "PRAGMA table_info(conversation_summaries)")
        var columns = Set<String>()
        while sqlite3_step(pragmaStmt) == SQLITE_ROW {
            if let nameCol = sqlite3_column_text(pragmaStmt, 1) {
                columns.insert(String(cString: nameCol))
            }
        }
        sqlite3_finalize(pragmaStmt)

        let query = Self.buildSummariesQuery(columns: columns)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK, let stmt = statement else {
            let errMsg = String(cString: sqlite3_errmsg(database))
            sqlite3_close(database)
            throw DatabaseError(description: "conversation_summaries.db: \(errMsg)")
        }

        cacheLock.lock()
        schemaColumnsCache[dbURL.path] = columns
        cacheLock.unlock()
        return (database, stmt)
    }

    private struct TranscriptInfo {
        var isWaiting: Bool = false
        var waitingText: String? = nil
        var waitingSince: Date? = nil
        var runningText: String? = nil
        var lastPlannerText: String? = nil
    }

    private func inspectTranscript(url: URL) -> TranscriptInfo {
        guard let lines = FileUtils.readTailLines(fileURL: url, maxBytes: 32768) else {
            return TranscriptInfo()
        }

        var info = TranscriptInfo()

        for line in lines {
            // 先用子串快速过滤，跳过无关的 SYSTEM / TOOL 等大体积步骤行
            guard line.contains("\"PLANNER_RESPONSE\"") || line.contains("\"USER_INPUT\"") else {
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let lineData = trimmed.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }

            let type = json["type"] as? String

            if type == "PLANNER_RESPONSE" {
                if let toolCalls = json["tool_calls"] as? [[String: Any]] {
                    for call in toolCalls {
                        let callName = call["tool_name"] as? String ?? call["name"] as? String ?? ""
                        if callName == "ask_question" || callName == "ask_user_question" {
                            info.isWaiting = true
                            info.waitingSince = FastDateParser.parse(json["created_at"] as? String)
                            if let args = call["arguments"] as? [String: Any] ?? call["parameters"] as? [String: Any] {
                                info.waitingText = args["question"] as? String ?? args["prompt"] as? String
                            }
                        } else if !callName.isEmpty {
                            info.runningText = "正在运行 \(callName)…"
                        }
                    }
                }
                if let content = json["content"] as? String {
                    let clean = content.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !clean.isEmpty {
                        info.lastPlannerText = String(clean.prefix(80))
                    }
                }
            } else if type == "USER_INPUT" {
                // User replied, reset waiting state
                info.isWaiting = false
                info.waitingSince = nil
            }
        }

        return info
    }
}
