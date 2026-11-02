import Foundation

public struct ClaudeSessionJSON: Codable, Sendable {
    public let pid: Int
    public let sessionId: String
    public let cwd: String?
    public let name: String?
    public let kind: String?
    public let entrypoint: String?
    public let status: String?
    public let waitingFor: String?
    public let startedAt: Int64?
    public let updatedAt: Int64?
    public let statusUpdatedAt: Int64?

    enum CodingKeys: String, CodingKey {
        case pid, sessionId, cwd, name, kind, entrypoint, status, waitingFor
        case startedAt, updatedAt, statusUpdatedAt
    }
}

public final class ClaudeCodeAdapter: AgentAdapter, @unchecked Sendable {
    public let kind: AgentKind = .claudeCode

    public let sessionsDirectory: URL
    public let projectsDirectory: URL
    public let eventsDirectory: URL
    public let hookReader: ClaudeHookEventReader
    public let isPidAlive: @Sendable (Int32) -> Bool
    public let maxAgeSeconds: TimeInterval
    public let waitingThreshold: TimeInterval

    public var showUsage: Bool
    public var usageTracker: UsageTracker

    private struct TranscriptCacheEntry {
        let url: URL?
        let timestamp: Date
    }

    private var transcriptCache: [String: TranscriptCacheEntry] = [:]
    private let transcriptCacheLock = NSLock()

    public init(
        sessionsDirectory: URL? = nil,
        projectsDirectory: URL? = nil,
        eventsDirectory: URL? = nil,
        hookReader: ClaudeHookEventReader? = nil,
        isPidAlive: (@Sendable (Int32) -> Bool)? = nil,
        maxAgeSeconds: TimeInterval = 24 * 3600,
        waitingThreshold: TimeInterval = 5.0,
        showUsage: Bool = true,
        usageTracker: UsageTracker = .shared
    ) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.sessionsDirectory = sessionsDirectory ?? home.appendingPathComponent(".claude/sessions")
        self.projectsDirectory = projectsDirectory ?? home.appendingPathComponent(".claude/projects")
        let evDir = eventsDirectory ?? home.appendingPathComponent("Library/Application Support/AgentMonitor/events")
        self.eventsDirectory = evDir
        self.hookReader = hookReader ?? ClaudeHookEventReader(fileURL: evDir.appendingPathComponent("claude.tsv"))
        self.isPidAlive = isPidAlive ?? { pid in
            kill(pid, 0) == 0
        }
        self.maxAgeSeconds = maxAgeSeconds
        self.waitingThreshold = waitingThreshold
        self.showUsage = showUsage
        self.usageTracker = usageTracker
    }

    public var watchPaths: [URL] {
        [sessionsDirectory, projectsDirectory, eventsDirectory]
    }

    public func scan() throws -> [AgentSession] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: sessionsDirectory.path) else {
            return []
        }

        let sessionFiles: [URL]
        do {
            sessionFiles = try fm.contentsOfDirectory(
                at: sessionsDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ).filter { $0.pathExtension == "json" }
        } catch {
            return []
        }

        var results: [AgentSession] = []
        let now = Date()
        let hookStates = hookReader.poll()

        for fileURL in sessionFiles {
            guard let data = try? Data(contentsOf: fileURL),
                  let sessionMeta = try? JSONDecoder().decode(ClaudeSessionJSON.self, from: data) else {
                continue
            }

            // Liveness check
            guard isPidAlive(Int32(sessionMeta.pid)) else {
                continue
            }

            var updatedAt = sessionMeta.updatedAt.map { Date(timeIntervalSince1970: Double($0) / 1000.0) }
                ?? (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? now

            // Discard sessions older than max age
            if now.timeIntervalSince(updatedAt) > maxAgeSeconds {
                continue
            }

            let status = sessionMeta.status
            let waitingFor = sessionMeta.waitingFor
            let sessionId = sessionMeta.sessionId
            let cwd = sessionMeta.cwd

            let hookState = hookStates[sessionId]

            // Locate transcript: 优先使用 hookState 中的 transcriptPath（存在且文件存在时）
            var transcriptURL: URL? = nil
            if let hookTranscript = hookState?.transcriptPath, !hookTranscript.isEmpty {
                let candidateURL = URL(fileURLWithPath: hookTranscript)
                if fm.fileExists(atPath: candidateURL.path) {
                    transcriptURL = candidateURL
                }
            }
            if transcriptURL == nil {
                transcriptURL = locateTranscript(sessionId: sessionId, cwd: cwd, fm: fm)
            }

            var resolvedTitle = sessionMeta.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            if resolvedTitle?.isEmpty ?? true, let cwd = cwd {
                resolvedTitle = (cwd as NSString).lastPathComponent
            }
            if resolvedTitle?.isEmpty ?? true {
                resolvedTitle = "Claude Code"
            }

            var state: SessionState = .idle
            var detail: String? = nil
            var detailIsCommand = false
            var waitingLabel: String? = nil

            let transcriptSummary = transcriptURL != nil ? parseTranscript(transcriptURL: transcriptURL!) : nil

            if let transcriptTitle = transcriptSummary?.customTitle, !transcriptTitle.isEmpty {
                resolvedTitle = transcriptTitle
            }

            if status == "waiting" {
                state = .waitingForUser
                if waitingFor == "input needed" {
                    waitingLabel = "在问你"
                } else {
                    waitingLabel = "等待授权"
                }
                detail = transcriptSummary?.pendingToolDetail ?? transcriptSummary?.lastAssistantText
                detailIsCommand = transcriptSummary?.isCommand ?? false
            } else if status == "busy" {
                state = .running
                detail = transcriptSummary?.runningDetail ?? "正在思考…"
            } else if status == "idle" {
                state = .idle
                detail = transcriptSummary?.lastAssistantText
            } else {
                // Fallback when status field is missing: check transcript for pending tool use
                if let ts = transcriptSummary, ts.hasPendingToolUse {
                    let transcriptMtime = (try? transcriptURL?.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? updatedAt
                    if now.timeIntervalSince(transcriptMtime) >= waitingThreshold {
                        state = .waitingForUser
                        waitingLabel = ts.isUserQuestion ? "在问你" : "等待授权"
                        detail = ts.pendingToolDetail
                        detailIsCommand = ts.isCommand
                    } else {
                        state = .running
                        detail = ts.runningDetail ?? "正在思考…"
                    }
                } else {
                    state = .idle
                    detail = transcriptSummary?.lastAssistantText
                }
            }

            var suppressCompletion = false

            // Hook 状态覆盖判定
            if let hook = hookState {
                let thresholdDate: Date
                if let su = sessionMeta.statusUpdatedAt {
                    thresholdDate = Date(timeIntervalSince1970: Double(su) / 1000.0 - 1.0)
                } else {
                    thresholdDate = updatedAt.addingTimeInterval(-1.0)
                }

                if hook.at > thresholdDate {
                    switch hook.event {
                    case "PermissionRequest":
                        state = .waitingForUser
                        waitingLabel = "等待授权"
                        detail = hook.toolDetail
                        detailIsCommand = hook.detailIsCommand
                        if hook.at > updatedAt {
                            updatedAt = hook.at
                        }
                    case "Notification":
                        if hook.notificationType == "permission_prompt" {
                            state = .waitingForUser
                            waitingLabel = "等待授权"
                            detail = hook.message
                            detailIsCommand = false
                            if hook.at > updatedAt {
                                updatedAt = hook.at
                            }
                        } else if hook.notificationType == "elicitation_dialog" || hook.notificationType == "agent_needs_input" {
                            state = .waitingForUser
                            waitingLabel = "在问你"
                            detail = hook.message
                            detailIsCommand = false
                            if hook.at > updatedAt {
                                updatedAt = hook.at
                            }
                        }
                    case "Stop":
                        state = .idle
                        // 不覆盖 detail
                        if hook.at > updatedAt {
                            updatedAt = hook.at
                        }
                    case "StopFailure":
                        state = .idle
                        suppressCompletion = true
                        if hook.at > updatedAt {
                            updatedAt = hook.at
                        }
                    default:
                        // UserPromptSubmit, SessionStart, SessionEnd 等不覆盖
                        break
                    }
                }
            }

            let usage: SessionUsage?
            if showUsage, let transcriptURL = transcriptURL {
                usage = usageTracker.claudeUsage(transcript: transcriptURL)
            } else {
                usage = nil
            }

            let session = AgentSession(
                id: "\(kind.rawValue):\(sessionId)",
                kind: kind,
                title: resolvedTitle ?? "Claude Code",
                cwd: cwd,
                state: state,
                stateSince: updatedAt,
                lastActivity: updatedAt,
                detail: detail,
                detailIsCommand: detailIsCommand,
                waitingLabel: waitingLabel,
                entrypoint: sessionMeta.entrypoint,
                suppressCompletion: suppressCompletion,
                pid: Int32(sessionMeta.pid),
                transcriptPath: transcriptURL?.path,
                usage: usage
            )
            results.append(session)
        }

        return results
    }

    private func locateTranscript(sessionId: String, cwd: String?, fm: FileManager) -> URL? {
        let now = Date()
        transcriptCacheLock.lock()
        if let entry = transcriptCache[sessionId] {
            if let cachedURL = entry.url {
                if fm.fileExists(atPath: cachedURL.path) {
                    transcriptCacheLock.unlock()
                    return cachedURL
                }
            } else {
                // negative cache TTL: 约 30 秒
                if now.timeIntervalSince(entry.timestamp) < 30.0 {
                    transcriptCacheLock.unlock()
                    return nil
                }
            }
        }
        transcriptCacheLock.unlock()

        if let cwd = cwd {
            // Replace any non-alphanumeric character with "-"
            let slug = cwd.replacingOccurrences(of: "[^A-Za-z0-9]", with: "-", options: .regularExpression)
            let candidate = projectsDirectory.appendingPathComponent(slug).appendingPathComponent("\(sessionId).jsonl")
            if fm.fileExists(atPath: candidate.path) {
                transcriptCacheLock.lock()
                transcriptCache[sessionId] = TranscriptCacheEntry(url: candidate, timestamp: now)
                transcriptCacheLock.unlock()
                return candidate
            }
        }

        // Fallback: search in projectsDirectory/*/sessionId.jsonl
        if let subdirs = try? fm.contentsOfDirectory(at: projectsDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for dir in subdirs {
                let candidate = dir.appendingPathComponent("\(sessionId).jsonl")
                if fm.fileExists(atPath: candidate.path) {
                    transcriptCacheLock.lock()
                    transcriptCache[sessionId] = TranscriptCacheEntry(url: candidate, timestamp: now)
                    transcriptCacheLock.unlock()
                    return candidate
                }
            }
        }

        transcriptCacheLock.lock()
        transcriptCache[sessionId] = TranscriptCacheEntry(url: nil, timestamp: now)
        transcriptCacheLock.unlock()
        return nil
    }

    private struct TranscriptSummary {
        var customTitle: String?
        var hasPendingToolUse: Bool = false
        var isUserQuestion: Bool = false
        var isCommand: Bool = false
        var pendingToolDetail: String?
        var runningDetail: String?
        var lastAssistantText: String?
    }

    private func parseTranscript(transcriptURL: URL) -> TranscriptSummary {
        guard let lines = FileUtils.readTailLines(fileURL: transcriptURL, maxBytes: 32768) else {
            return TranscriptSummary()
        }

        var summary = TranscriptSummary()
        var pendingToolOrder: [String] = []
        var pendingToolUses: [String: (name: String, detail: String, isCmd: Bool, isQuestion: Bool)] = [:]

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let lineData = trimmed.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }

            let type = json["type"] as? String

            if type == "custom-title", let ct = json["customTitle"] as? String, !ct.isEmpty {
                summary.customTitle = ct
            }

            if type == "assistant" {
                if let message = json["message"] as? [String: Any],
                   let content = message["content"] as? [[String: Any]] {
                    for item in content {
                        let itemType = item["type"] as? String
                        if itemType == "tool_use" {
                            let toolId = item["id"] as? String ?? UUID().uuidString
                            let name = item["name"] as? String ?? "Tool"
                            var isCmd = false
                            var isQuestion = false
                            var toolDetail = name

                            if let input = item["input"] as? [String: Any] {
                                if let cmd = input["command"] as? String ?? input["cmd"] as? String {
                                    toolDetail = cmd
                                    isCmd = true
                                } else if let question = input["question"] as? String ?? input["prompt"] as? String {
                                    toolDetail = question
                                    isQuestion = true
                                } else if let path = input["path"] as? String ?? input["file_path"] as? String {
                                    toolDetail = "\(name) \(path)"
                                }
                            }

                            if pendingToolUses[toolId] == nil {
                                pendingToolOrder.append(toolId)
                            }
                            pendingToolUses[toolId] = (name, toolDetail, isCmd, isQuestion)
                            summary.runningDetail = "正在运行 \(name) · \(toolDetail)"
                        } else if itemType == "text", let text = item["text"] as? String {
                            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !clean.isEmpty {
                                summary.lastAssistantText = String(clean.prefix(80))
                            }
                        }
                    }
                }
            } else if type == "user" {
                if let message = json["message"] as? [String: Any],
                   let content = message["content"] as? [[String: Any]] {
                    for item in content {
                        if item["type"] as? String == "tool_result",
                           let toolUseId = item["tool_use_id"] as? String {
                            pendingToolUses.removeValue(forKey: toolUseId)
                            pendingToolOrder.removeAll { $0 == toolUseId }
                        }
                    }
                }
            }
        }

        if let lastId = pendingToolOrder.last, let lastPending = pendingToolUses[lastId] {
            summary.hasPendingToolUse = true
            summary.pendingToolDetail = lastPending.detail
            summary.isCommand = lastPending.isCmd
            summary.isUserQuestion = lastPending.isQuestion
        }

        return summary
    }


}
