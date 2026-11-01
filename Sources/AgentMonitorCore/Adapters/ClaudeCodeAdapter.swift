import Foundation

public struct ClaudeSessionJSON: Codable, Sendable {
    public let pid: Int
    public let sessionId: String
    public let cwd: String?
    public let name: String?
    public let kind: String?
    public let entrypoint: String?
    public let status: String?
    public let startedAt: Int64?
    public let updatedAt: Int64?
    public let statusUpdatedAt: Int64?

    enum CodingKeys: String, CodingKey {
        case pid, sessionId, cwd, name, kind, entrypoint, status
        case startedAt, updatedAt, statusUpdatedAt
    }
}

public final class ClaudeCodeAdapter: AgentAdapter, @unchecked Sendable {
    public let kind: AgentKind = .claudeCode

    public let sessionsDirectory: URL
    public let projectsDirectory: URL
    public let isPidAlive: @Sendable (Int32) -> Bool
    public let maxAgeSeconds: TimeInterval
    public let waitingThreshold: TimeInterval

    public init(
        sessionsDirectory: URL? = nil,
        projectsDirectory: URL? = nil,
        isPidAlive: (@Sendable (Int32) -> Bool)? = nil,
        maxAgeSeconds: TimeInterval = 6 * 3600,
        waitingThreshold: TimeInterval = 5.0
    ) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.sessionsDirectory = sessionsDirectory ?? home.appendingPathComponent(".claude/sessions")
        self.projectsDirectory = projectsDirectory ?? home.appendingPathComponent(".claude/projects")
        self.isPidAlive = isPidAlive ?? { pid in
            kill(pid, 0) == 0
        }
        self.maxAgeSeconds = maxAgeSeconds
        self.waitingThreshold = waitingThreshold
    }

    public var watchPaths: [URL] {
        [sessionsDirectory, projectsDirectory]
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

        for fileURL in sessionFiles {
            guard let data = try? Data(contentsOf: fileURL),
                  let sessionMeta = try? JSONDecoder().decode(ClaudeSessionJSON.self, from: data) else {
                continue
            }

            // Liveness check
            guard isPidAlive(Int32(sessionMeta.pid)) else {
                continue
            }

            let updatedAt = sessionMeta.updatedAt.map { Date(timeIntervalSince1970: Double($0) / 1000.0) }
                ?? (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? now

            // Discard sessions older than max age
            if now.timeIntervalSince(updatedAt) > maxAgeSeconds {
                continue
            }

            let status = sessionMeta.status ?? "idle"
            let sessionId = sessionMeta.sessionId
            let cwd = sessionMeta.cwd

            // Locate transcript
            let transcriptURL: URL?
            if let cwd = cwd {
                let slug = cwd.replacingOccurrences(of: "/", with: "-")
                let candidate = projectsDirectory.appendingPathComponent(slug).appendingPathComponent("\(sessionId).jsonl")
                transcriptURL = fm.fileExists(atPath: candidate.path) ? candidate : nil
            } else {
                transcriptURL = nil
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

            if status == "busy" {
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
                    state = .running
                    detail = transcriptSummary?.runningDetail ?? "正在思考…"
                }
            } else {
                // status == "idle"
                state = .completed
                detail = transcriptSummary?.lastAssistantText
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
                waitingLabel: waitingLabel
            )
            results.append(session)
        }

        return results
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
                        }
                    }
                }
            }
        }

        if let lastPending = Array(pendingToolUses.values).last {
            summary.hasPendingToolUse = true
            summary.pendingToolDetail = lastPending.detail
            summary.isCommand = lastPending.isCmd
            summary.isUserQuestion = lastPending.isQuestion
        }

        return summary
    }


}
