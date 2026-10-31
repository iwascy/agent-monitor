import Foundation
import SQLite3

public final class AntigravityAdapter: AgentAdapter, @unchecked Sendable {
    public let kind: AgentKind = .antigravity

    public let baseDirectory: URL
    public let isLockHeld: @Sendable (String) -> Bool
    public let maxAgeSeconds: TimeInterval

    public init(
        baseDirectory: URL? = nil,
        isLockHeld: (@Sendable (String) -> Bool)? = nil,
        maxAgeSeconds: TimeInterval = 6 * 3600
    ) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.baseDirectory = baseDirectory ?? home.appendingPathComponent(".gemini/antigravity")
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
        let rows = readSummaries(dbURL: summariesDBURL)
        var results: [AgentSession] = []

        for row in rows {
            if row.killed {
                continue
            }

            let lockPath = presenceDir.appendingPathComponent("\(row.conversationId).lock").path
            let isLocked = isLockHeld(lockPath)

            let lastModified = row.lastModified ?? now
            if !isLocked && now.timeIntervalSince(lastModified) > maxAgeSeconds {
                continue
            }

            // Parse CWD from workspace_uris
            var resolvedCwd: String? = nil
            if let urisData = row.workspaceUris.data(using: .utf8),
               let uriArray = try? JSONSerialization.jsonObject(with: urisData) as? [String],
               let firstUri = uriArray.first {
                if firstUri.hasPrefix("file://") {
                    resolvedCwd = URL(string: firstUri)?.path
                } else {
                    resolvedCwd = firstUri
                }
            }

            let title = !row.title.isEmpty ? row.title : (resolvedCwd.map { ($0 as NSString).lastPathComponent } ?? "Antigravity")

            // Check transcript for waiting states if running
            let transcriptURL = brainDir.appendingPathComponent(row.conversationId).appendingPathComponent(".system_generated/logs/transcript.jsonl")
            var isWaiting = false
            var waitingDetail: String? = nil
            var runningDetail: String? = nil

            if fm.fileExists(atPath: transcriptURL.path) {
                let (waiting, waitText, runText) = inspectTranscript(url: transcriptURL)
                isWaiting = waiting
                waitingDetail = waitText
                runningDetail = runText
            }

            var state: SessionState = .idle
            var waitingLabel: String? = nil
            var detail: String? = nil

            if row.status == "CASCADE_RUN_STATUS_RUNNING" || row.notFullyIdle {
                if isWaiting {
                    state = .waitingForUser
                    waitingLabel = "在问你"
                    detail = waitingDetail ?? "等待用户确认或输入"
                } else {
                    state = .running
                    detail = runningDetail ?? "正在思考…"
                }
            } else {
                // CASCADE_RUN_STATUS_IDLE
                if isLocked {
                    state = .completed
                    detail = !row.preview.isEmpty ? row.preview : nil
                } else {
                    state = .completed
                    detail = !row.preview.isEmpty ? row.preview : nil
                }
            }

            let session = AgentSession(
                id: "\(kind.rawValue):\(row.conversationId)",
                kind: kind,
                title: title,
                cwd: resolvedCwd,
                state: state,
                stateSince: lastModified,
                lastActivity: lastModified,
                detail: detail,
                detailIsCommand: false,
                waitingLabel: waitingLabel
            )
            results.append(session)
        }

        return results
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
    }

    private func readSummaries(dbURL: URL) -> [SummaryRow] {
        var db: OpaquePointer?
        let uriString = "file:\(dbURL.path)?mode=ro&immutable=0"
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI

        var retries = 3
        while retries > 0 {
            if sqlite3_open_v2(uriString, &db, flags, nil) == SQLITE_OK {
                break
            }
            retries -= 1
            usleep(50_000)
        }

        guard let database = db else { return [] }
        defer { sqlite3_close(database) }

        sqlite3_busy_timeout(database, 300)

        let query = """
        SELECT conversation_id, title, preview, workspace_uris, status, not_fully_idle, killed, last_modified_time
        FROM conversation_summaries
        ORDER BY last_modified_time DESC
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        var rows: [SummaryRow] = []
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        while sqlite3_step(statement) == SQLITE_ROW {
            let convId = String(cString: sqlite3_column_text(statement, 0))
            let title = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            let preview = sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? ""
            let wsUris = sqlite3_column_text(statement, 3).map { String(cString: $0) } ?? ""
            let status = sqlite3_column_text(statement, 4).map { String(cString: $0) } ?? ""
            let notIdle = sqlite3_column_int(statement, 5) != 0
            let killed = sqlite3_column_int(statement, 6) != 0

            var modDate: Date? = nil
            if let dateStr = sqlite3_column_text(statement, 7) {
                let s = String(cString: dateStr)
                modDate = dateFormatter.date(from: s)
                if modDate == nil {
                    // Try fallback standard format "yyyy-MM-dd HH:mm:ss"
                    let df = DateFormatter()
                    df.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSZZZZZ"
                    modDate = df.date(from: s)
                }
            }

            rows.append(SummaryRow(
                conversationId: convId,
                title: title,
                preview: preview,
                workspaceUris: wsUris,
                status: status,
                notFullyIdle: notIdle,
                killed: killed,
                lastModified: modDate
            ))
        }

        return rows
    }

    private func inspectTranscript(url: URL) -> (isWaiting: Bool, waitingText: String?, runningText: String?) {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return (false, nil, nil)
        }
        defer { try? handle.close() }

        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let offset = max(0, size - 16384)
        guard let _ = try? handle.seek(toOffset: UInt64(offset)) else {
            return (false, nil, nil)
        }

        let data = handle.readDataToEndOfFile()
        guard let content = String(data: data, encoding: .utf8) else {
            return (false, nil, nil)
        }

        let lines = content.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let lastLine = lines.last,
              let lineData = lastLine.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
            return (false, nil, nil)
        }

        let type = json["type"] as? String
        var waiting = false
        var waitText: String? = nil
        var runText: String? = nil

        if let toolCalls = json["tool_calls"] as? [[String: Any]] {
            for call in toolCalls {
                let callName = call["tool_name"] as? String ?? call["name"] as? String ?? ""
                if callName == "ask_question" || callName == "ask_user_question" {
                    waiting = true
                    if let args = call["arguments"] as? [String: Any] ?? call["parameters"] as? [String: Any] {
                        waitText = args["question"] as? String ?? args["prompt"] as? String
                    }
                } else if !callName.isEmpty {
                    runText = "正在运行 \(callName)…"
                }
            }
        }

        if type == "PLANNER_RESPONSE" && waiting {
            return (true, waitText, runText)
        }

        return (false, nil, runText)
    }
}
