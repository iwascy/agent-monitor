import Foundation

public final class CodexAdapter: AgentAdapter, @unchecked Sendable {
    public let kind: AgentKind = .codex

    public let sessionsDirectory: URL
    public let sessionIndexURL: URL
    public let isCodexRunning: @Sendable () -> Bool
    public let maxAgeSeconds: TimeInterval

    public init(
        sessionsDirectory: URL? = nil,
        sessionIndexURL: URL? = nil,
        isCodexRunning: (@Sendable () -> Bool)? = nil,
        maxAgeSeconds: TimeInterval = 6 * 3600
    ) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.sessionsDirectory = sessionsDirectory ?? home.appendingPathComponent(".codex/sessions")
        self.sessionIndexURL = sessionIndexURL ?? home.appendingPathComponent(".codex/session_index.jsonl")
        self.isCodexRunning = isCodexRunning ?? {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            process.arguments = ["-q", "-f", "codex"]
            do {
                try process.run()
                process.waitUntilExit()
                return process.terminationStatus == 0
            } catch {
                return false
            }
        }
        self.maxAgeSeconds = maxAgeSeconds
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

        // 2. Discover rollout files from recent 2 days
        guard fm.fileExists(atPath: sessionsDirectory.path) else {
            return []
        }

        let calendar = Calendar(identifier: .gregorian)
        var dayURLs: [URL] = []
        for dayOffset in 0...1 {
            if let date = calendar.date(byAdding: .day, value: -dayOffset, to: now) {
                let year = String(format: "%04d", calendar.component(.year, from: date))
                let month = String(format: "%02d", calendar.component(.month, from: date))
                let day = String(format: "%02d", calendar.component(.day, from: date))
                let dir = sessionsDirectory.appendingPathComponent(year).appendingPathComponent(month).appendingPathComponent(day)
                if fm.fileExists(atPath: dir.path) {
                    dayURLs.append(dir)
                }
            }
        }

        var rolloutURLs: [URL] = []
        for dayDir in dayURLs {
            if let files = try? fm.contentsOfDirectory(at: dayDir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) {
                rolloutURLs.append(contentsOf: files.filter { $0.lastPathComponent.hasPrefix("rollout-") && $0.pathExtension == "jsonl" })
            }
        }

        let isRunning = isCodexRunning()
        var results: [AgentSession] = []

        for fileURL in rolloutURLs {
            let mtime = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now
            if now.timeIntervalSince(mtime) > maxAgeSeconds {
                continue
            }

            guard let summary = parseRollout(fileURL: fileURL) else {
                continue
            }

            let nativeId = summary.sessionId ?? extractIdFromFilename(fileURL.lastPathComponent)
            let title = threadNames[nativeId] ?? summary.title ?? summary.cwdLastComponent ?? "Codex"

            var state: SessionState = .idle
            var waitingLabel: String? = nil
            var detailIsCommand = false

            switch summary.lastEventType {
            case .approvalRequest:
                state = .waitingForUser
                waitingLabel = "等待授权"
                detailIsCommand = summary.detailIsCommand
            case .userInputRequest:
                state = .waitingForUser
                waitingLabel = "在问你"
                detailIsCommand = false
            case .taskComplete:
                state = .idle
            case .taskStarted, .inProgressTool:
                if isRunning {
                    state = .running
                } else {
                    state = .idle
                }
            case .aborted, .none:
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
                waitingLabel: waitingLabel
            )
            results.append(session)
        }

        return results
    }

    private func extractIdFromFilename(_ filename: String) -> String {
        // format: rollout-2026-11-01T00-24-07-01a192c6-76d1-7a20-8d79-7b78776c9a55.jsonl
        let stem = (filename as NSString).deletingPathExtension
        if let lastDashRange = stem.range(of: "-", options: .backwards) {
            let idCandidate = String(stem[lastDashRange.upperBound...])
            if idCandidate.count >= 8 {
                return idCandidate
            }
        }
        return stem
    }

    private enum RolloutEventType {
        case taskStarted
        case taskComplete
        case approvalRequest
        case userInputRequest
        case inProgressTool
        case aborted
        case none
    }

    private struct RolloutSummary {
        var sessionId: String?
        var cwd: String?
        var title: String?
        var cwdLastComponent: String?
        var lastEventType: RolloutEventType = .taskComplete
        var detail: String?
        var detailIsCommand: Bool = false
    }

    private func parseRollout(fileURL: URL) -> RolloutSummary? {
        guard let lines = FileUtils.readTailLines(fileURL: fileURL, maxBytes: 65536) else {
            return nil
        }

        var summary = RolloutSummary()
        var lastAssistantMessage: String?
        var activeToolCmd: String?

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let lineData = trimmed.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }

            let type = json["type"] as? String
            let payload = json["payload"] as? [String: Any]

            if type == "session_meta", let p = payload {
                if let sid = p["session_id"] as? String ?? p["id"] as? String {
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

                case "exec_approval_request":
                    summary.lastEventType = .approvalRequest
                    let cmd = p["command"] as? String ?? p["cmd"] as? String ?? activeToolCmd ?? "执行命令"
                    summary.detail = cmd
                    summary.detailIsCommand = true

                case "apply_patch_approval_request":
                    summary.lastEventType = .approvalRequest
                    let path = p["path"] as? String ?? p["file"] as? String ?? "应用代码修改"
                    summary.detail = path
                    summary.detailIsCommand = false

                case "request_user_input", "elicitation_request":
                    summary.lastEventType = .userInputRequest
                    let q = p["question"] as? String ?? p["prompt"] as? String ?? "请确认下一步操作"
                    summary.detail = q
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
                    if let args = p["arguments"] as? [String: Any] ?? p["input"] as? [String: Any] {
                        activeToolCmd = args["cmd"] as? String ?? args["command"] as? String
                    } else if let argsStr = p["arguments"] as? String {
                        activeToolCmd = argsStr
                    }
                    if summary.lastEventType != .approvalRequest && summary.lastEventType != .userInputRequest {
                        summary.lastEventType = .inProgressTool
                        let display = activeToolCmd != nil ? "正在运行 \(toolName) · \(activeToolCmd!)" : "正在运行 \(toolName)…"
                        summary.detail = display
                    }
                } else if ptype == "custom_tool_call_output" || ptype == "function_call_output" {
                    activeToolCmd = nil
                }
            }
        }

        if summary.lastEventType == .taskComplete && summary.detail == nil {
            summary.detail = lastAssistantMessage
        }

        return summary
    }


}
