import Foundation

public final class UsageTracker: @unchecked Sendable {
    public static let shared = UsageTracker()

    private struct ClaudeMessageUsage {
        var inputTokens: Int
        var cacheCreationTokens: Int
        var cacheReadTokens: Int
        var outputTokens: Int
    }

    private struct ClaudeState {
        var offset: UInt64 = 0
        var messages: [String: ClaudeMessageUsage] = [:]
        var lastNonSidechainContext: Int? = nil
        var lastModel: String? = nil
        var lastModified: Date? = nil

        func buildUsage(updatedAt: Date) -> SessionUsage? {
            guard !messages.isEmpty || lastNonSidechainContext != nil else {
                return nil
            }
            var totalIn = 0
            var totalCacheRead = 0
            var totalCacheCreation = 0
            var totalOut = 0

            for usage in messages.values {
                totalIn += usage.inputTokens
                totalCacheRead += usage.cacheReadTokens
                totalCacheCreation += usage.cacheCreationTokens
                totalOut += usage.outputTokens
            }

            return SessionUsage(
                model: lastModel,
                inputTokens: totalIn,
                cachedInputTokens: totalCacheRead,
                cacheWriteTokens: totalCacheCreation,
                outputTokens: totalOut,
                reasoningTokens: nil,
                requestCount: messages.count,
                contextTokens: lastNonSidechainContext,
                contextWindow: nil,
                steps: nil,
                updatedAt: updatedAt
            )
        }
    }

    private struct CodexState {
        var lastUsage: SessionUsage?
        var lastModel: String?
        var lastFileSize: Int?
    }

    private var claudeCache: [String: ClaudeState] = [:]
    private var codexCache: [String: CodexState] = [:]
    private let lock = NSLock()

    public init() {}

    /// 清空缓存（测试或重置时使用）
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        claudeCache.removeAll()
        codexCache.removeAll()
    }

    // MARK: - Claude Usage

    public func claudeUsage(transcript: URL) -> SessionUsage? {
        lock.lock()
        defer { lock.unlock() }

        let path = transcript.path
        let fm = FileManager.default
        guard fm.fileExists(atPath: path),
              let attrs = try? fm.attributesOfItem(atPath: path),
              let currentSize = attrs[.size] as? UInt64 else {
            claudeCache.removeValue(forKey: path)
            return nil
        }

        let mtime = (attrs[.modificationDate] as? Date) ?? Date()

        var state = claudeCache[path] ?? ClaudeState()

        // 文件被截断或重写时清空缓存从头读
        if currentSize < state.offset {
            state = ClaudeState()
        }

        if currentSize == state.offset && state.offset > 0 {
            return state.buildUsage(updatedAt: mtime)
        }

        guard let fileHandle = try? FileHandle(forReadingFrom: transcript) else {
            return state.buildUsage(updatedAt: mtime)
        }
        defer { try? fileHandle.close() }

        do {
            try fileHandle.seek(toOffset: state.offset)
        } catch {
            return state.buildUsage(updatedAt: mtime)
        }

        var buffer = Data()
        let chunkSize = 1024 * 1024 // 1 MB 流式分块

        while true {
            let chunk: Data
            do {
                if let readData = try fileHandle.read(upToCount: chunkSize), !readData.isEmpty {
                    chunk = readData
                } else {
                    break
                }
            } catch {
                break
            }

            buffer.append(chunk)

            if let lastNewline = buffer.lastIndex(of: UInt8(ascii: "\n")) {
                let completeBlock = buffer[buffer.startIndex...lastNewline]
                let text = String(decoding: completeBlock, as: UTF8.self)
                processClaudeLines(text, state: &state)
                state.offset += UInt64(completeBlock.count)
                buffer = Data(buffer[buffer.index(after: lastNewline)...])
            }
        }

        state.lastModified = mtime
        claudeCache[path] = state

        return state.buildUsage(updatedAt: mtime)
    }

    private func processClaudeLines(_ text: String, state: inout ClaudeState) {
        let lines = text.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let data = trimmed.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            guard json["type"] as? String == "assistant" else {
                continue
            }

            // 排除 isSidechain == true
            if let isSidechain = json["isSidechain"] as? Bool, isSidechain {
                continue
            }

            guard let message = json["message"] as? [String: Any],
                  let msgId = message["id"] as? String else {
                continue
            }

            if let model = message["model"] as? String, !model.isEmpty {
                state.lastModel = model
            }

            guard let usage = message["usage"] as? [String: Any] else {
                continue
            }

            let inputTokens = usage["input_tokens"] as? Int ?? 0
            let cacheCreation = usage["cache_creation_input_tokens"] as? Int ?? 0
            let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
            let outputTokens = usage["output_tokens"] as? Int ?? 0

            state.messages[msgId] = ClaudeMessageUsage(
                inputTokens: inputTokens,
                cacheCreationTokens: cacheCreation,
                cacheReadTokens: cacheRead,
                outputTokens: outputTokens
            )

            // 当前上下文 = 最后一条 isSidechain != true 的 assistant 消息的 input_tokens + cache_creation + cache_read
            let context = inputTokens + cacheCreation + cacheRead
            state.lastNonSidechainContext = context
        }
    }

    // MARK: - Codex Usage

    public func codexUsage(rollout: URL) -> SessionUsage? {
        lock.lock()
        defer { lock.unlock() }

        let path = rollout.path
        let fm = FileManager.default
        guard fm.fileExists(atPath: path),
              let attrs = try? fm.attributesOfItem(atPath: path) else {
            codexCache.removeValue(forKey: path)
            return nil
        }

        let mtime = (attrs[.modificationDate] as? Date) ?? Date()
        let currentSize = (attrs[.size] as? Int) ?? 0

        var state = codexCache[path] ?? CodexState()

        // 读取尾部 64KB
        guard let lines = FileUtils.readTailLines(fileURL: rollout, maxBytes: 65536) else {
            return state.lastUsage
        }

        var latestTokenCountInfo: [String: Any]? = nil
        var latestModel: String? = state.lastModel

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            // 提取 model 名（支持 thread_settings_applied、turn_context 等）
            if trimmed.contains("\"model\""),
               let model = extractCodexModel(from: trimmed) {
                latestModel = model
            }

            guard let data = trimmed.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["type"] as? String == "event_msg",
                  let payload = json["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count" else {
                continue
            }

            // 忽略 payload.info == nil
            if let info = payload["info"] as? [String: Any] {
                latestTokenCountInfo = info
            }
        }

        if let info = latestTokenCountInfo {
            let total = info["total_token_usage"] as? [String: Any]
            let last = info["last_token_usage"] as? [String: Any]
            let window = info["model_context_window"] as? Int

            let usage = SessionUsage(
                model: latestModel,
                inputTokens: total?["input_tokens"] as? Int,
                cachedInputTokens: total?["cached_input_tokens"] as? Int,
                cacheWriteTokens: nil,
                outputTokens: total?["output_tokens"] as? Int,
                reasoningTokens: total?["reasoning_output_tokens"] as? Int,
                requestCount: nil,
                contextTokens: last?["input_tokens"] as? Int,
                contextWindow: window,
                steps: nil,
                updatedAt: mtime
            )

            state.lastUsage = usage
            state.lastModel = latestModel
            state.lastFileSize = currentSize
            codexCache[path] = state
            return usage
        } else if var cachedUsage = state.lastUsage {
            // 尾部未找到时保留上一次的值，若有新 model 则更新
            if let latestModel = latestModel {
                cachedUsage.model = latestModel
                state.lastModel = latestModel
            }
            cachedUsage.updatedAt = mtime
            state.lastUsage = cachedUsage
            codexCache[path] = state
            return cachedUsage
        }

        return nil
    }

    private func extractCodexModel(from line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let payload = json["payload"] as? [String: Any] {
            if let settings = payload["thread_settings"] as? [String: Any],
               let model = settings["model"] as? String, !model.isEmpty {
                return model
            }
            if let model = payload["model"] as? String, !model.isEmpty {
                return model
            }
        }
        return nil
    }
}
