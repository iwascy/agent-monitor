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
        var originator: String?
        var isSubagent = false
    }
    public var showUsage: Bool
    public var usageTracker: UsageTracker

    private struct DirCacheEntry {
        let stamp: FileStamp
        let subdirs: [URL]
        let rolloutFiles: [URL]
    }

    private var metaCache: [String: SessionMeta] = [:]
    private var indexCache: (stamp: FileStamp, offset: UInt64, head: Data, names: [String: String])?
    private var dirCache: [String: DirCacheEntry] = [:]
    private var rolloutCache: [String: (stamp: FileStamp, summary: RolloutSummary)] = [:]
    private let cacheLock = NSLock()

    public init(
        sessionsDirectory: URL? = nil,
        sessionIndexURL: URL? = nil,
        isCodexRunning: (@Sendable () -> Bool)? = nil, // Kept for backwards compatibility if needed
        maxAgeSeconds: TimeInterval = 24 * 3600,
        activeThreshold: TimeInterval = 600.0,
        showUsage: Bool = true,
        usageTracker: UsageTracker = .shared
    ) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.sessionsDirectory = sessionsDirectory ?? home.appendingPathComponent(".codex/sessions")
        self.sessionIndexURL = sessionIndexURL ?? home.appendingPathComponent(".codex/session_index.jsonl")
        self.maxAgeSeconds = maxAgeSeconds
        self.activeThreshold = activeThreshold
        self.showUsage = showUsage
        self.usageTracker = usageTracker
    }

    public var watchPaths: [URL] {
        [sessionsDirectory, sessionIndexURL]
    }

    public func scan() throws -> [AgentSession] {
        let now = Date()

        // 1. Load session_index.jsonl（带增量偏移与文件快照缓存）
        let threadNames = loadThreadNames()

        // 2. Discover active rollout files in sessions directory（目录快照缓存 + 快速 stat 过滤）
        guard FileUtils.fastStat(path: sessionsDirectory.path)?.isDirectory == true else {
            return []
        }

        let activeRollouts = discoverActiveRolloutFiles(now: now)
        var results: [AgentSession] = []
        var activePaths = Set<String>()

        for (fileURL, stamp) in activeRollouts {
            let mtime = stamp.modificationDate
            activePaths.insert(fileURL.path)

            let meta = sessionMeta(fileURL: fileURL)
            // Guardian reviews and other child agents are implementation details of the parent turn.
            // Their session_id can be the parent's ID; merging them would overwrite its live state.
            guard !meta.isSubagent, let summary = cachedParseRollout(fileURL: fileURL, stamp: stamp) else {
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

            let usage = showUsage ? usageTracker.codexUsage(rollout: fileURL) : nil

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
                suppressCompletion: summary.isHeartbeat || summary.lastEventType != .taskComplete,
                transcriptPath: fileURL.path,
                originator: meta.originator,
                usage: usage
            )
            results.append(session)
        }

        pruneCachesIfNeeded(activePaths: activePaths)
        return results
    }

    private func loadThreadNames() -> [String: String] {
        let indexPath = sessionIndexURL.path
        guard let stamp = FileUtils.fastStat(path: indexPath) else {
            cacheLock.lock()
            indexCache = nil
            cacheLock.unlock()
            return [:]
        }

        cacheLock.lock()
        let existing = indexCache
        cacheLock.unlock()

        if let existing, existing.stamp == stamp {
            return existing.names
        }

        guard let handle = try? FileHandle(forReadingFrom: sessionIndexURL) else {
            return existing?.names ?? [:]
        }
        defer { try? handle.close() }

        let head = (try? handle.read(upToCount: 64)) ?? Data()
        let currentSize = UInt64(max(0, stamp.size))

        var names: [String: String]
        var offset: UInt64

        // 若文件头部未变且大小单调增长，只增量解析追加的尾部字节
        if let existing, !existing.head.isEmpty, existing.head == head, currentSize >= existing.offset {
            names = existing.names
            offset = existing.offset
        } else {
            names = [:]
            offset = 0
        }

        if currentSize > offset {
            do {
                try handle.seek(toOffset: offset)
                let chunk = handle.readDataToEndOfFile()
                if let lastNL = chunk.lastIndex(of: 0x0A) {
                    let validSlice = chunk[chunk.startIndex...lastNL]
                    var lineStart = validSlice.startIndex
                    for idx in validSlice.indices where validSlice[idx] == 0x0A {
                        let lineBytes = validSlice[lineStart..<idx]
                        lineStart = validSlice.index(after: idx)
                        if !lineBytes.isEmpty,
                           let obj = try? JSONSerialization.jsonObject(with: Data(lineBytes)) as? [String: Any],
                           let id = obj["id"] as? String,
                           let name = obj["thread_name"] as? String {
                            names[id] = name
                        }
                    }
                    offset += UInt64(validSlice.count)
                } else if let text = String(data: chunk, encoding: .utf8) {
                    // 兼容末尾无换行符的小体积索引文件（如测试 fixture）
                    for line in text.components(separatedBy: .newlines) {
                        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let id = obj["id"] as? String,
                              let name = obj["thread_name"] as? String else {
                            continue
                        }
                        names[id] = name
                    }
                    offset = currentSize
                }
            } catch {
                return names
            }
        }

        cacheLock.lock()
        indexCache = (stamp: stamp, offset: offset, head: head, names: names)
        cacheLock.unlock()
        return names
    }

    private func sessionMeta(fileURL: URL) -> SessionMeta {
        cacheLock.lock()
        if let cached = metaCache[fileURL.path] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

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
            result.originator = p["originator"] as? String
            result.isSubagent = (p["source"] as? [String: Any])?["subagent"] != nil
                || p["source"] as? String == "subagent"
                || p["parent_thread_id"] as? String != nil
                || p["thread_source"] as? String == "guardian_review"
        } else {
            return result
        }

        cacheLock.lock()
        metaCache[fileURL.path] = result
        cacheLock.unlock()
        return result
    }

    /// 结合目录级 mtime 缓存与轻量 POSIX `stat` 发现处于活跃时间窗口内的 rollout 文件。
    private func discoverActiveRolloutFiles(now: Date) -> [(url: URL, stamp: FileStamp)] {
        let fm = FileManager.default
        var stack: [URL] = [sessionsDirectory]
        var activeFiles: [(url: URL, stamp: FileStamp)] = []
        var visitedDirs = Set<String>()

        while let dirURL = stack.popLast() {
            let dirPath = dirURL.path
            guard visitedDirs.insert(dirPath).inserted,
                  let dirStamp = FileUtils.fastStat(path: dirPath),
                  dirStamp.isDirectory else {
                continue
            }

            let entry: DirCacheEntry
            cacheLock.lock()
            let cachedDir = dirCache[dirPath]
            cacheLock.unlock()

            if let cachedDir, cachedDir.stamp == dirStamp {
                entry = cachedDir
            } else {
                let children = (try? fm.contentsOfDirectory(
                    at: dirURL,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )) ?? []
                var subdirs: [URL] = []
                var rollouts: [URL] = []
                for child in children {
                    let name = child.lastPathComponent
                    if name.hasPrefix("rollout-") && child.pathExtension == "jsonl" {
                        rollouts.append(child)
                    } else if FileUtils.fastStat(path: child.path)?.isDirectory == true {
                        subdirs.append(child)
                    }
                }
                entry = DirCacheEntry(stamp: dirStamp, subdirs: subdirs, rolloutFiles: rollouts)
                cacheLock.lock()
                dirCache[dirPath] = entry
                cacheLock.unlock()
            }

            stack.append(contentsOf: entry.subdirs)

            for fileURL in entry.rolloutFiles {
                guard let fileStamp = FileUtils.fastStat(path: fileURL.path), !fileStamp.isDirectory else {
                    continue
                }
                if now.timeIntervalSince(fileStamp.modificationDate) <= maxAgeSeconds {
                    activeFiles.append((fileURL, fileStamp))
                }
            }
        }

        if visitedDirs.count < 512 {
            cacheLock.lock()
            if dirCache.count > 512 {
                dirCache = dirCache.filter { visitedDirs.contains($0.key) }
            }
            cacheLock.unlock()
        }

        return activeFiles
    }

    private func pruneCachesIfNeeded(activePaths: Set<String>) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if rolloutCache.count > 128 {
            rolloutCache = rolloutCache.filter { activePaths.contains($0.key) }
        }
        if metaCache.count > 512 {
            metaCache = metaCache.filter { activePaths.contains($0.key) }
        }
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

    private func cachedParseRollout(fileURL: URL, stamp: FileStamp) -> RolloutSummary? {
        let path = fileURL.path
        cacheLock.lock()
        if let hit = rolloutCache[path], hit.stamp == stamp {
            cacheLock.unlock()
            return hit.summary
        }
        cacheLock.unlock()

        guard let summary = parseRollout(fileURL: fileURL, fileSize: stamp.size) else {
            return nil
        }

        cacheLock.lock()
        rolloutCache[path] = (stamp, summary)
        cacheLock.unlock()
        return summary
    }

    private static func lineMayContainLifecycle(_ line: String) -> Bool {
        guard line.contains("\"event_msg\"") else { return false }
        return line.contains("\"task_started\"")
            || line.contains("\"task_complete\"")
            || line.contains("\"turn_aborted\"")
    }

    private static func isRelevantRolloutLine(_ line: String) -> Bool {
        line.contains("\"event_msg\"")
            || line.contains("\"message\"")
            || line.contains("\"function_call\"")
            || line.contains("\"custom_tool_call\"")
            || line.contains("\"session_meta\"")
            || line.contains("\"turn_context\"")
    }

    private func parseRollout(fileURL: URL, fileSize: Int) -> RolloutSummary? {
        // A single tool result can exceed 64KB. Expand until a lifecycle event is present,
        // so output/reasoning alone cannot turn an active task into idle.
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
                guard Self.lineMayContainLifecycle(line),
                      let data = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      json["type"] as? String == "event_msg",
                      let payload = json["payload"] as? [String: Any],
                      let type = payload["type"] as? String else { return false }
                return type == "task_started" || type == "task_complete" || type == "turn_aborted"
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
            guard Self.isRelevantRolloutLine(line) else { continue }
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
