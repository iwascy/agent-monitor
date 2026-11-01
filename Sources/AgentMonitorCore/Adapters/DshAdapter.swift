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
        maxAgeSeconds: TimeInterval = 6 * 3600
    ) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.sessionsDirectory = sessionsDirectory ?? home.appendingPathComponent(".dsh/sessions")
        self.zstdExecutablePath = zstdExecutablePath
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

                // Check lock state
                let lockFile = sessionDir.appendingPathComponent("session.lock")
                let isLocked = isLockHeld(lockFile.path)

                // If not locked and older than max age, ignore
                if !isLocked && now.timeIntervalSince(mtime) > maxAgeSeconds {
                    continue
                }

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
                    } else if summary.hasCompletedTurn {
                        state = .completed
                    } else {
                        state = .running
                    }
                } else {
                    if summary.hasCompletedTurn {
                        state = .completed
                    } else {
                        state = .idle
                    }
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
                    waitingLabel: waitingLabel
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
                summary.isTurnActive = true
                summary.hasCompletedTurn = false
                summary.detail = "正在思考…"
                summary.detailIsCommand = false
            } else if type == "turn/end" {
                summary.isTurnActive = false
                summary.hasCompletedTurn = true
                summary.hasWaitingQuestion = false
                summary.hasPendingApproval = false
                summary.detail = lastAssistantText
                summary.detailIsCommand = false
            } else if type == "tool/call" {
                if let data = json["data"] as? [String: Any] {
                    let toolName = data["name"] as? String ?? "工具"
                    let callId = data["callId"] as? String ?? UUID().uuidString
                    let cmd = data["command"] as? String ?? data["cmd"] as? String
                    pendingCallIds.insert(callId)

                    if toolName == "ask_user_question" || toolName == "ask_question" {
                        questionCallIds.insert(callId)
                        summary.hasWaitingQuestion = true
                        summary.detail = data["question"] as? String ?? data["prompt"] as? String ?? "请确认下一步操作"
                        summary.detailIsCommand = false
                    } else {
                        let display = cmd != nil ? "正在运行 \(toolName) · \(cmd!)" : "正在运行 \(toolName)…"
                        summary.detail = display
                        summary.detailIsCommand = false
                    }
                }
            } else if type == "tool/result" {
                if let data = json["data"] as? [String: Any], let callId = data["callId"] as? String {
                    pendingCallIds.remove(callId)
                    questionCallIds.remove(callId)
                    if questionCallIds.isEmpty {
                        summary.hasWaitingQuestion = false
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

            guard let content = String(data: data, encoding: .utf8) else {
                return []
            }
            let allLines = content.components(separatedBy: .newlines)
            // Take the last 100 lines for efficiency
            return Array(allLines.suffix(100))
        } catch {
            return []
        }
    }


}
