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
        var lastModified: Date?
    }

    private var claudeCache: [String: ClaudeState] = [:]
    private var codexCache: [String: CodexState] = [:]
    private var _readCount: Int = 0
    private let lock = NSLock()

    // 预构造字节特征串，避免对非 assistant 行执行完整的 JSON 反序列化
    private static let assistantMarker = Data("\"assistant\"".utf8)

    public init() {}

    /// 文件读取次数统计（主要用于测试验证缓存和开关逻辑）
    public var readCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _readCount
    }

    private func recordRead() {
        _readCount += 1
    }

    /// 清空缓存（测试或重置时使用）
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        claudeCache.removeAll()
        codexCache.removeAll()
        _readCount = 0
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
                    recordRead()
                } else {
                    break
                }
            } catch {
                break
            }

            buffer.append(chunk)

            if let lastNewline = buffer.lastIndex(of: UInt8(ascii: "\n")) {
                let completeBlock = buffer[buffer.startIndex...lastNewline]
                processClaudeDataBlock(completeBlock, state: &state)
                state.offset += UInt64(completeBlock.count)
                buffer = Data(buffer[buffer.index(after: lastNewline)...])
            }
        }

        state.lastModified = mtime
        claudeCache[path] = state
        pruneClaudeCacheIfNeeded()

        return state.buildUsage(updatedAt: mtime)
    }

    private func pruneClaudeCacheIfNeeded() {
        guard claudeCache.count > 256 else { return }
        let sortedKeys = claudeCache.sorted {
            ($0.value.lastModified ?? .distantPast) < ($1.value.lastModified ?? .distantPast)
        }.map(\.key)
        for key in sortedKeys.prefix(claudeCache.count - 128) {
            claudeCache.removeValue(forKey: key)
        }
    }

    private func pruneCodexCacheIfNeeded() {
        guard codexCache.count > 256 else { return }
        let sortedKeys = codexCache.sorted {
            ($0.value.lastModified ?? .distantPast) < ($1.value.lastModified ?? .distantPast)
        }.map(\.key)
        for key in sortedKeys.prefix(codexCache.count - 128) {
            codexCache.removeValue(forKey: key)
        }
    }

    private func processClaudeDataBlock(_ block: Data, state: inout ClaudeState) {
        var start = block.startIndex
        for i in block.indices {
            if block[i] == 0x0A {
                let lineData = block[start..<i]
                start = block.index(after: i)
                processClaudeLineData(lineData, state: &state)
            }
        }
        if start < block.endIndex {
            let lineData = block[start..<block.endIndex]
            processClaudeLineData(lineData, state: &state)
        }
    }

    private func processClaudeLineData(_ lineData: Data, state: inout ClaudeState) {
        guard !lineData.isEmpty,
              lineData.range(of: Self.assistantMarker) != nil,
              let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
              json["type"] as? String == "assistant" else {
            return
        }

        let isSidechain = (json["isSidechain"] as? Bool) ?? false

        guard let message = json["message"] as? [String: Any],
              let msgId = message["id"] as? String else {
            return
        }

        if !isSidechain {
            if let model = message["model"] as? String, !model.isEmpty {
                state.lastModel = model
            }
        }

        guard let usage = message["usage"] as? [String: Any] else {
            return
        }

        let inputTokens = usage["input_tokens"] as? Int ?? 0
        let cacheCreation = usage["cache_creation_input_tokens"] as? Int ?? 0
        let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
        let outputTokens = usage["output_tokens"] as? Int ?? 0

        // sidechain 消息照常计入 messages[msgId]，只是不更新 lastNonSidechainContext 和模型名
        state.messages[msgId] = ClaudeMessageUsage(
            inputTokens: inputTokens,
            cacheCreationTokens: cacheCreation,
            cacheReadTokens: cacheRead,
            outputTokens: outputTokens
        )

        // 仅非 sidechain 消息更新 lastNonSidechainContext
        if !isSidechain {
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

        // P1-21: 文件大小和 mtime 都没变时，直接返回 state.lastUsage，避免每秒重读 64KB
        if let lastSize = state.lastFileSize,
           let lastMtime = state.lastModified,
           lastSize == currentSize,
           lastMtime == mtime {
            return state.lastUsage
        }

        // 读取尾部 64KB
        recordRead()
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

            guard trimmed.contains("\"token_count\""),
                  let data = trimmed.data(using: .utf8),
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

        // P1-19: Codex 缓存里还没有模型名时，从文件末尾按 1MB 一块往前流式扫描，找到最后一个 "model":"..." 后缓存起来
        if latestModel == nil {
            if let model = scanCodexModelBackwards(fileURL: rollout, fileSize: currentSize) {
                latestModel = model
                state.lastModel = model
            }
        }

        if let info = latestTokenCountInfo {
            let total = info["total_token_usage"] as? [String: Any]
            let last = info["last_token_usage"] as? [String: Any]
            let window = info["model_context_window"] as? Int

            // P2-19: inputTokens 改为 input_tokens - cached_input_tokens
            let rawInput = total?["input_tokens"] as? Int
            let cachedInput = total?["cached_input_tokens"] as? Int
            let netInput: Int?
            if let rawInput = rawInput {
                if let cachedInput = cachedInput {
                    netInput = max(0, rawInput - cachedInput)
                } else {
                    netInput = rawInput
                }
            } else {
                netInput = nil
            }

            let usage = SessionUsage(
                model: latestModel,
                inputTokens: netInput,
                cachedInputTokens: cachedInput,
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
            state.lastModified = mtime
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
            state.lastFileSize = currentSize
            state.lastModified = mtime
            codexCache[path] = state
            return cachedUsage
        }

        state.lastFileSize = currentSize
        state.lastModified = mtime
        if let latestModel = latestModel {
            state.lastModel = latestModel
        }
        codexCache[path] = state
        pruneCodexCacheIfNeeded()

        return nil
    }

    /// 从文件末尾按 1MB 一块往前流式扫描，寻找最后一个出现且有效的 model
    private func scanCodexModelBackwards(fileURL: URL, fileSize: Int) -> String? {
        guard fileSize > 0,
              let fileHandle = try? FileHandle(forReadingFrom: fileURL) else {
            return nil
        }
        defer { try? fileHandle.close() }

        let chunkSize = 1024 * 1024 // 1 MB
        var currentEnd = fileSize
        var remainingBytes = Data()

        while currentEnd > 0 {
            let start = max(0, currentEnd - chunkSize)
            let length = currentEnd - start
            do {
                try fileHandle.seek(toOffset: UInt64(start))
                guard let chunk = try fileHandle.read(upToCount: length), !chunk.isEmpty else {
                    break
                }
                recordRead()

                var data = chunk
                if !remainingBytes.isEmpty {
                    data.append(remainingBytes)
                    remainingBytes.removeAll()
                }

                // 按 0x0A 字节切行
                var linesData: [Data] = []
                var lineStart = data.startIndex
                var foundFirstNewline = false

                for i in data.indices {
                    if data[i] == 0x0A {
                        if !foundFirstNewline && start > 0 {
                            // 非开头分块的第一个 0x0A 之前属于截断行，保留给前一个分块
                            remainingBytes = Data(data[data.startIndex..<i])
                            lineStart = data.index(after: i)
                            foundFirstNewline = true
                        } else {
                            linesData.append(Data(data[lineStart..<i]))
                            lineStart = data.index(after: i)
                        }
                    }
                }
                if lineStart < data.endIndex {
                    linesData.append(Data(data[lineStart..<data.endIndex]))
                }

                // 倒序寻找最后一个出现的 model
                for lineData in linesData.reversed() {
                    guard let lineStr = String(data: lineData, encoding: .utf8) else { continue }
                    let trimmed = lineStr.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty, trimmed.contains("\"model\"") else { continue }
                    if let model = extractCodexModel(from: trimmed) {
                        return model
                    }
                }

                currentEnd = start
            } catch {
                break
            }
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
