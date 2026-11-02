import Foundation

public final class DshAdapter: AgentAdapter, @unchecked Sendable {
    public let kind: AgentKind = .dsh

    public let sessionsDirectory: URL
    public let zstdExecutablePath: String
    public let isLockHeld: @Sendable (String) -> Bool
    public let maxAgeSeconds: TimeInterval

    // Cache parsed summaries by (path, mtime, fileSize)
    private struct CacheKey: Hashable {
        let path: String
        let mtime: Date
        let size: Int
    }
    private var summaryCache: [String: (key: CacheKey, summary: DshSessionSummary)] = [:]
    private let cacheLock = NSLock()

    public init(
        sessionsDirectory: URL? = nil,
        zstdExecutablePath: String = "/opt/homebrew/bin/zstd",
        isLockHeld: (@Sendable (String) -> Bool)? = nil,
        maxAgeSeconds: TimeInterval = 24 * 3600
    ) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.sessionsDirectory = sessionsDirectory ?? home.appendingPathComponent(".dsh/sessions")
        self.zstdExecutablePath = zstdExecutablePath
        self.isLockHeld = isLockHeld ?? { path in
            guard FileManager.default.fileExists(atPath: path) else { return false }
            let fd = open(path, O_RDONLY)
            guard fd >= 0 else { return false }
            defer { close(fd) }

            // Probe with LOCK_SH | LOCK_NB so we don't conflict with dsh resuming sessions
            let ret = flock(fd, LOCK_SH | LOCK_NB)
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
        [sessionsDirectory]
    }

    public func scan() throws -> [AgentSession] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: sessionsDirectory.path) else {
            return []
        }

        let now = Date()
        var results: [AgentSession] = []

        // Enumerate directory: sessions/<slug>/<uuid>/
        guard let slugDirs = try? fm.contentsOfDirectory(
            at: sessionsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        for slugDir in slugDirs {
            guard let sessionDirs = try? fm.contentsOfDirectory(
                at: slugDir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for sessionDir in sessionDirs {
                let zstdFile = sessionDir.appendingPathComponent("session.v4.jsonl.zstd")
                let uncompressedFile = sessionDir.appendingPathComponent("session.v4.jsonl") // In case uncompressed fixture
                let targetDataFile: URL

                if fm.fileExists(atPath: zstdFile.path) {
                    targetDataFile = zstdFile
                } else if fm.fileExists(atPath: uncompressedFile.path) {
                    targetDataFile = uncompressedFile
                } else {
                    continue
                }

                let resourceValues = try? targetDataFile.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                let mtime = resourceValues?.contentModificationDate ?? now
                let fileSize = resourceValues?.fileSize ?? 0

                // Filter by mtime first before any lock probing!
                if now.timeIntervalSince(mtime) > maxAgeSeconds {
                    continue
                }

                // Check lock state only for sessions within the active time window
                let lockFile = sessionDir.appendingPathComponent("session.lock")
                let isLocked = isLockHeld(lockFile.path)

                // Parse session events (cached)
                guard let summary = getOrParseSummary(fileURL: targetDataFile, mtime: mtime, fileSize: fileSize) else {
                    continue
                }

                let nativeId = summary.sessionId ?? sessionDir.lastPathComponent
                let title = summary.title ?? summary.cwdLastComponent ?? unslug(slugDir.lastPathComponent)

                var state: SessionState = .idle
                var waitingLabel: String? = nil
                var detailIsCommand = false

                if isLocked {
                    if summary.hasWaitingQuestion {
                        state = .waitingForUser
                        waitingLabel = "在问你"
                        detailIsCommand = false
                    } else if summary.hasPendingApproval {
                        state = .waitingForUser
                        waitingLabel = "等待授权"
                        detailIsCommand = summary.detailIsCommand
                    } else if summary.isTurnActive {
                        state = .running
                    } else {
                        // Stale locked session without active turn -> idle
                        state = .idle
                    }
                } else {
                    state = .idle
                }

                let session = AgentSession(
                    id: "\(kind.rawValue):\(nativeId)",
                    kind: kind,
                    title: title,
                    cwd: summary.cwd,
                    state: state,
                    stateSince: mtime,
                    lastActivity: mtime,
                    detail: summary.detail,
                    detailIsCommand: detailIsCommand,
                    waitingLabel: waitingLabel,
                    suppressCompletion: summary.lastTurnAborted
                )
                results.append(session)
            }
        }

        return results
    }

    private func unslug(_ slug: String) -> String {
        // e.g. --Users-cy-code-mac-rea-display-rea-- -> display-rea
        let s = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if let last = s.split(separator: "-").last {
            return String(last)
        }
        return slug
    }

    private struct DshSessionSummary {
        var sessionId: String?
        var cwd: String?
        var cwdLastComponent: String?
        var title: String?
        var isTurnActive: Bool = false
        var hasCompletedTurn: Bool = false
        var lastTurnAborted: Bool = false
        var hasWaitingQuestion: Bool = false
        var hasPendingApproval: Bool = false
        var detail: String?
        var detailIsCommand: Bool = false
    }

    private func getOrParseSummary(fileURL: URL, mtime: Date, fileSize: Int) -> DshSessionSummary? {
        cacheLock.lock()
        if let cached = summaryCache[fileURL.path],
           cached.key.mtime == mtime,
           cached.key.size == fileSize {
            cacheLock.unlock()
            return cached.summary
        }
        cacheLock.unlock()

        let lines: [String]
        if fileURL.pathExtension == "zstd" {
            lines = decompressZstdTail(fileURL: fileURL)
        } else {
            lines = FileUtils.readTailLines(fileURL: fileURL, maxBytes: 65536) ?? []
        }

        guard !lines.isEmpty else { return nil }

        let summary = parseDshLines(lines)

        cacheLock.lock()
        summaryCache[fileURL.path] = (CacheKey(path: fileURL.path, mtime: mtime, size: fileSize), summary)
        cacheLock.unlock()

        return summary
    }

    private func parseDshLines(_ lines: [String]) -> DshSessionSummary {
        var summary = DshSessionSummary()
        var lastAssistantText: String?
        var pendingCallIds: Set<String> = []
        var questionCallIds: Set<String> = []
        var approvalCallIds: Set<String> = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let lineData = trimmed.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }

            guard let type = json["type"] as? String else { continue }

            if type == "session" {
                if let id = json["id"] as? String {
                    summary.sessionId = id
                }
                if let cwd = json["cwd"] as? String {
                    summary.cwd = cwd
                    summary.cwdLastComponent = (cwd as NSString).lastPathComponent
                }
            } else if type == "session/title" {
                if let data = json["data"] as? [String: Any], let title = data["title"] as? String {
                    let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !clean.isEmpty {
                        summary.title = clean
                    }
                }
            } else if type == "turn/start" {
                questionCallIds.removeAll()
                approvalCallIds.removeAll()
                summary.hasWaitingQuestion = false
                summary.hasPendingApproval = false
                summary.isTurnActive = true
                summary.lastTurnAborted = false
                summary.hasCompletedTurn = false
                summary.detail = "正在思考…"
                summary.detailIsCommand = false
            } else if type == "turn/end" {
                questionCallIds.removeAll()
                approvalCallIds.removeAll()
                summary.isTurnActive = false
                summary.hasWaitingQuestion = false
                summary.hasPendingApproval = false
                // A turn ended by the user (or by an error) is not a completion worth notifying about.
                let reasonKind = ((json["data"] as? [String: Any])?["reason"] as? [String: Any])?["kind"] as? String
                summary.hasCompletedTurn = reasonKind == nil || reasonKind == "completed"
                summary.lastTurnAborted = !summary.hasCompletedTurn
                summary.detail = lastAssistantText
                summary.detailIsCommand = false
            } else if type == "tool/call" {
                if let data = json["data"] as? [String: Any] {
                    let toolName = data["name"] as? String ?? "工具"
                    let callId = data["callId"] as? String ?? UUID().uuidString
                    
                    var cmd = data["command"] as? String ?? data["cmd"] as? String
                    var question = data["question"] as? String ?? data["prompt"] as? String

                    // Parse arguments if it is a JSON string or dictionary
                    if let argsStr = data["arguments"] as? String,
                       let argsData = argsStr.data(using: .utf8),
                       let argsObj = try? JSONSerialization.jsonObject(with: argsData) as? [String: Any] {
                        if cmd == nil {
                            cmd = argsObj["command"] as? String ?? argsObj["cmd"] as? String
                        }
                        if question == nil {
                            question = argsObj["question"] as? String ?? argsObj["prompt"] as? String
                        }
                    } else if let argsObj = data["arguments"] as? [String: Any] {
                        if cmd == nil {
                            cmd = argsObj["command"] as? String ?? argsObj["cmd"] as? String
                        }
                        if question == nil {
                            question = argsObj["question"] as? String ?? argsObj["prompt"] as? String
                        }
                    }

                    pendingCallIds.insert(callId)

                    if toolName == "ask_user_question" || toolName == "ask_question" {
                        questionCallIds.insert(callId)
                        summary.hasWaitingQuestion = true
                        summary.detail = question ?? "请确认下一步操作"
                        summary.detailIsCommand = false
                    } else {
                        let display = cmd != nil ? "正在运行 \(toolName) · \(cmd!)" : "正在运行 \(toolName)…"
                        summary.detail = display
                        summary.detailIsCommand = false
                    }
                }
            } else if type == "approval/asked" {
                if let data = json["data"] as? [String: Any],
                   let callId = data["callId"] as? String {
                    approvalCallIds.insert(callId)
                    summary.hasPendingApproval = true
                    summary.detail = data["reason"] as? String ?? "请批准工具执行"
                    summary.detailIsCommand = false
                }
            } else if type == "tool/result" {
                if let data = json["data"] as? [String: Any] {
                    var callId = data["toolCallId"] as? String ?? data["callId"] as? String
                    if callId == nil,
                       let msg = data["message"] as? [String: Any],
                       let src = msg["source"] as? [String: Any] {
                        callId = src["callId"] as? String
                    }
                    if let cid = callId {
                        pendingCallIds.remove(cid)
                        approvalCallIds.remove(cid)
                        summary.hasPendingApproval = !approvalCallIds.isEmpty
                        questionCallIds.remove(cid)
                        if questionCallIds.isEmpty {
                            summary.hasWaitingQuestion = false
                        }
                    }
                }
            } else if type == "assistant/message" {
                if let data = json["data"] as? [String: Any],
                   let message = data["message"] as? [String: Any],
                   let content = message["content"] as? [[String: Any]] {
                    for block in content {
                        if block["type"] as? String == "text", let text = block["text"] as? String {
                            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !clean.isEmpty {
                                lastAssistantText = String(clean.prefix(80))
                            }
                        }
                    }
                }
            }
        }

        if summary.hasCompletedTurn && summary.detail == nil {
            summary.detail = lastAssistantText
        }

        return summary
    }

    private func decompressZstdTail(fileURL: URL) -> [String] {
        guard FileManager.default.fileExists(atPath: zstdExecutablePath) else {
            return []
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: zstdExecutablePath)
        process.arguments = ["-dc", fileURL.path]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            // dsh may be mid-write: a torn final frame decodes only partially, so the output can end inside
            // a multi-byte character or a JSON line. Decode leniently and drop the unterminated last line.
            var lines = String(decoding: data, as: UTF8.self).components(separatedBy: .newlines)
            if data.last != UInt8(ascii: "\n"), !lines.isEmpty {
                lines.removeLast()
            }
            return lines
        } catch {
            return []
        }
    }


}
