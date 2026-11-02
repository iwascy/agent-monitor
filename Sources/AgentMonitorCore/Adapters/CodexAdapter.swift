import Foundation

public final class CodexAdapter: AgentAdapter, @unchecked Sendable {
    public let kind: AgentKind = .codex

    public let sessionsDirectory: URL
    public let sessionIndexURL: URL
    public let maxAgeSeconds: TimeInterval
    public let activeThreshold: TimeInterval // Threshold to consider an uncompleted task running (default 10 min)

    // session_meta is the first line of a rollout and never changes, so cache it per file.
    private struct SessionMeta {
        var sessionId: String?
        var cwd: String?
        var isSubagent = false
    }
    private var metaCache: [String: SessionMeta] = [:]
    private let metaCacheLock = NSLock()

    public init(
        sessionsDirectory: URL? = nil,
        sessionIndexURL: URL? = nil,
        isCodexRunning: (@Sendable () -> Bool)? = nil, // Kept for backwards compatibility if needed
        maxAgeSeconds: TimeInterval = 6 * 3600,
        activeThreshold: TimeInterval = 600.0
    ) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.sessionsDirectory = sessionsDirectory ?? home.appendingPathComponent(".codex/sessions")
        self.sessionIndexURL = sessionIndexURL ?? home.appendingPathComponent(".codex/session_index.jsonl")
        self.maxAgeSeconds = maxAgeSeconds
        self.activeThreshold = activeThreshold
    }

    public var watchPaths: [URL] {
        [sessionsDirectory, sessionIndexURL]
    }

    public func scan() throws -> [AgentSession] {
        let fm = FileManager.default
        let now = Date()

        // 1. Load session_index.jsonl
        var threadNames: [String: String] = [:]
        if fm.fileExists(atPath: sessionIndexURL.path),
           let indexContent = try? String(contentsOf: sessionIndexURL, encoding: .utf8) {
            for line in indexContent.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let id = obj["id"] as? String,
                      let name = obj["thread_name"] as? String else {
                    continue
                }
                threadNames[id] = name
            }
        }

        // 2. Discover all rollout files in sessions directory
        guard fm.fileExists(atPath: sessionsDirectory.path) else {
            return []
        }

        let rolloutURLs = discoverRolloutFiles()
        var results: [AgentSession] = []

        for fileURL in rolloutURLs {
            let mtime = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now
            if now.timeIntervalSince(mtime) > maxAgeSeconds {
                continue
            }

            let meta = sessionMeta(fileURL: fileURL)
            // Guardian reviews and other child agents are implementation details of the parent turn.
            // Their session_id can be the parent's ID; merging them would overwrite its live state.
            guard !meta.isSubagent, let summary = parseRollout(fileURL: fileURL) else {
                continue
            }

            let nativeId = summary.sessionId ?? meta.sessionId ?? extractIdFromFilename(fileURL.lastPathComponent)
            let cwd = summary.cwd ?? meta.cwd
            let title = threadNames[nativeId] ?? summary.title ?? cwd.map { ($0 as NSString).lastPathComponent } ?? "Codex"

            var state: SessionState = .idle
            var waitingLabel: String? = nil
            var detailIsCommand = false
            var detail = summary.detail

            let isFresh = now.timeIntervalSince(mtime) <= activeThreshold
            switch summary.lastEventType {
            case .taskComplete, .aborted, .none:
                state = .idle
            case .waitingEscalation:
                // Heuristic: uncompleted function call requiring escalated sandbox permissions
                if isFresh {
                    state = .waitingForUser
                    waitingLabel = "等待授权"
                    detail = summary.activeToolCmd ?? summary.detail ?? "执行操作"
                    detailIsCommand = summary.detailIsCommand
                }
            case .taskStarted, .inProgressTool:
                // If modified within activeThreshold (e.g. 10 minutes), consider it running; otherwise timed out/aborted
                if isFresh {
                    state = .running
                    if detail == nil {
                        detail = "正在思考…"
                    }
                }
            }

            // Automation runs (scheduled checks) end with a <heartbeat> message; they are silent background
            // turns, so the store must not promote them to completed or notify.
            if summary.isHeartbeat {
                detail = nil
            }

            let session = AgentSession(
                id: "\(kind.rawValue):\(nativeId)",
                kind: kind,
                title: title,
                cwd: cwd,
                state: state,
                stateSince: mtime,
                lastActivity: mtime,
                detail: detail,
                detailIsCommand: detailIsCommand,
                waitingLabel: waitingLabel,
                suppressCompletion: summary.isHeartbeat || summary.lastEventType != .taskComplete
            )
            results.append(session)
        }

        return results
    }

    private func sessionMeta(fileURL: URL) -> SessionMeta {
        metaCacheLock.lock()
        if let cached = metaCache[fileURL.path] {
            metaCacheLock.unlock()
            return cached
        }
        metaCacheLock.unlock()

        // The first line may still be being written; don't cache until it is complete.
        guard let line = FileUtils.readFirstLine(fileURL: fileURL, maxBytes: 1 << 20) else {
            return SessionMeta()
        }
        var result = SessionMeta()
        if let data = line.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           json["type"] as? String == "session_meta",
           let p = json["payload"] as? [String: Any] {
            result.sessionId = p["id"] as? String ?? p["session_id"] as? String
            result.cwd = p["cwd"] as? String
            result.isSubagent = (p["source"] as? [String: Any])?["subagent"] != nil
                || p["source"] as? String == "subagent"
                || p["parent_thread_id"] as? String != nil
                || p["thread_source"] as? String == "guardian_review"
        } else {
            return result
        }

        metaCacheLock.lock()
        metaCache[fileURL.path] = result
        metaCacheLock.unlock()
        return result
    }

    private func discoverRolloutFiles() -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: sessionsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [URL] = []
        for case let fileURL as URL in enumerator {
            if fileURL.pathExtension == "jsonl" && fileURL.lastPathComponent.hasPrefix("rollout-") {
                files.append(fileURL)
            }
        }
        return files
    }

    private func extractIdFromFilename(_ filename: String) -> String {
        // format: rollout-YYYY-MM-DDTHH-MM-SS-<uuid>.jsonl
        let stem = (filename as NSString).deletingPathExtension
        if stem.count >= 36 {
            let candidate = String(stem.suffix(36))
            if candidate.filter({ $0 == "-" }).count == 4 {
                return candidate
            }
        }
        if stem.hasPrefix("rollout-") && stem.count > 28 {
            let index = stem.index(stem.startIndex, offsetBy: 28)
            let idCandidate = String(stem[index...])
            if !idCandidate.isEmpty {
                return idCandidate
            }
        }
        return stem
    }

    private enum RolloutEventType {
        case taskStarted
        case taskComplete
        case waitingEscalation
        case inProgressTool
        case aborted
        case none
    }

    private struct RolloutSummary {
        var sessionId: String?
        var cwd: String?
        var title: String?
        var cwdLastComponent: String?
        var lastEventType: RolloutEventType = .none
        var activeToolCmd: String?
        var isHeartbeat: Bool = false
        var detail: String?
        var detailIsCommand: Bool = false
    }

    private func parseRollout(fileURL: URL) -> RolloutSummary? {
        // A single tool result can exceed 64KB. Expand until a lifecycle event is present,
        // so output/reasoning alone cannot turn an active task into idle.
        let fileSize = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        var maxBytes = 65536
        var lines: [String]
        while true {
            guard var tail = FileUtils.readTailLines(fileURL: fileURL, maxBytes: maxBytes) else {
                return nil
            }
            // Only consume committed JSONL records while Codex is appending a large record.
            if tail.last != "" { tail.removeLast() }
            lines = tail
            let hasLifecycle = lines.contains { line in
                guard let data = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      json["type"] as? String == "event_msg",
                      let payload = json["payload"] as? [String: Any],
                      let type = payload["type"] as? String else { return false }
                return ["task_started", "task_complete", "turn_aborted"].contains(type)
            }
            if hasLifecycle || maxBytes >= fileSize { break }
            maxBytes = min(maxBytes * 2, fileSize)
        }
        guard !lines.isEmpty else {
            return nil
        }

        var summary = RolloutSummary()
        var lastAssistantMessage: String?

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let lineData = trimmed.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }

            let type = json["type"] as? String
            let payload = json["payload"] as? [String: Any]

            if type == "session_meta", let p = payload {
                if let sid = p["id"] as? String ?? p["session_id"] as? String {
                    summary.sessionId = sid
                }
                if let cwd = p["cwd"] as? String {
                    summary.cwd = cwd
                    summary.cwdLastComponent = (cwd as NSString).lastPathComponent
                }
            }

            if type == "turn_context", let p = payload {
                if let cwd = p["cwd"] as? String, summary.cwd == nil {
                    summary.cwd = cwd
                    summary.cwdLastComponent = (cwd as NSString).lastPathComponent
                }
            }

            if type == "event_msg", let p = payload, let ptype = p["type"] as? String {
                switch ptype {
                case "task_started":
                    lastAssistantMessage = nil
                    summary.lastEventType = .taskStarted
                    summary.detail = "正在思考…"
                    summary.detailIsCommand = false

                case "task_complete":
                    summary.lastEventType = .taskComplete
                    summary.detail = lastAssistantMessage
                    summary.detailIsCommand = false

                case "turn_aborted":
                    summary.lastEventType = .aborted
                    summary.detail = "已中止"
                    summary.detailIsCommand = false

                default:
                    break
                }
            } else if type == "response_item", let p = payload, let ptype = p["type"] as? String {
                if ptype == "message", let role = p["role"] as? String, role == "assistant" {
                    if let content = p["content"] as? [[String: Any]] {
                        for c in content {
                            if let text = c["text"] as? String {
                                let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !clean.isEmpty {
                                    lastAssistantMessage = String(clean.prefix(80))
                                }
                            }
                        }
                    }
                } else if ptype == "custom_tool_call" || ptype == "function_call" {
                    let toolName = p["name"] as? String ?? "工具"
                    var cmd: String? = nil
                    var requiresEscalated = false

                    if let args = p["arguments"] as? [String: Any] ?? p["input"] as? [String: Any] {
                        cmd = args["cmd"] as? String ?? args["command"] as? String
                        if let perm = args["sandbox_permissions"] as? String, perm == "require_escalated" {
                            requiresEscalated = true
                        }
                    } else if let argsStr = p["arguments"] as? String {
                        cmd = argsStr
                        if argsStr.contains("\"sandbox_permissions\":\"require_escalated\"") || argsStr.contains("require_escalated") {
                            requiresEscalated = true
                        }
                    }

                    if requiresEscalated {
                        summary.lastEventType = .waitingEscalation
                        summary.activeToolCmd = cmd
                        summary.detail = cmd ?? "执行 \(toolName)"
                        summary.detailIsCommand = cmd != nil
                    } else {
                        summary.lastEventType = .inProgressTool
                        let display = cmd != nil ? "正在运行 \(toolName) · \(cmd!)" : "正在运行 \(toolName)…"
                        summary.detail = display
                        summary.detailIsCommand = false
                    }
                } else if ptype == "custom_tool_call_output" || ptype == "function_call_output" {
                    if summary.lastEventType == .waitingEscalation || summary.lastEventType == .inProgressTool {
                        summary.lastEventType = .taskStarted
                        summary.detail = "正在思考…"
                    }
                }
            }
        }

        if summary.lastEventType == .taskComplete && summary.detail == nil {
            summary.detail = lastAssistantMessage
        }
        summary.isHeartbeat = lastAssistantMessage?.hasPrefix("<heartbeat>") ?? false

        return summary
    }
}
