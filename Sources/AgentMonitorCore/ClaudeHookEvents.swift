import Foundation

public struct ClaudeHookState: Equatable, Sendable {
    public var event: String          // hook_event_name
    public var at: Date
    public var notificationType: String?
    public var message: String?       // Notification.message
    public var toolName: String?      // PermissionRequest.tool_name
    public var toolDetail: String?    // tool_input.command ?? tool_input.file_path ?? tool_name
    public var transcriptPath: String?
    public var detailIsCommand: Bool
    public var suppressCompletion: Bool

    public init(
        event: String,
        at: Date,
        notificationType: String? = nil,
        message: String? = nil,
        toolName: String? = nil,
        toolDetail: String? = nil,
        transcriptPath: String? = nil,
        detailIsCommand: Bool = false,
        suppressCompletion: Bool = false
    ) {
        self.event = event
        self.at = at
        self.notificationType = notificationType
        self.message = message
        self.toolName = toolName
        self.toolDetail = toolDetail
        self.transcriptPath = transcriptPath
        self.detailIsCommand = detailIsCommand
        self.suppressCompletion = suppressCompletion
    }
}

public final class ClaudeHookEventReader: @unchecked Sendable {
    public static var defaultFileURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/Application Support/AgentMonitor/events/claude.tsv")
    }

    public let fileURL: URL
    private var fileOffset: UInt64 = 0
    private var fileHeadSignature: Data?
    private var states: [String: ClaudeHookState] = [:]
    private var lastEventInfo: (at: Date, event: String)?
    private let lock = NSLock()
    private let maxFileSizeBeforeRotation: UInt64 = 5 * 1024 * 1024 // 5 MB

    public init(fileURL: URL = ClaudeHookEventReader.defaultFileURL) {
        self.fileURL = fileURL
        checkRotationOnStartup()
    }

    public var lastEvent: (at: Date, event: String)? {
        lock.lock()
        defer { lock.unlock() }
        return lastEventInfo
    }

    private func checkRotationOnStartup() {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
              let size = attrs[.size] as? UInt64 else {
            return
        }

        if size > maxFileSizeBeforeRotation {
            rotateFile()
        }
    }

    private func rotateFile() {
        let fm = FileManager.default
        let rotatedURL = fileURL.deletingPathExtension().appendingPathExtension("tsv.1")
        try? fm.removeItem(at: rotatedURL)
        try? fm.moveItem(at: fileURL, to: rotatedURL)
        fileOffset = 0
    }

    public func poll() -> [String: ClaudeHookState] {
        lock.lock()
        defer { lock.unlock() }

        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
              let currentSize = attrs[.size] as? UInt64 else {
            return states
        }

        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return states
        }
        defer {
            try? handle.close()
        }

        // 检测文件头部签名变化（判断文件是否被覆盖重写或轮转）
        let head = (try? handle.read(upToCount: 32)) ?? Data()
        if let currentHeadSig = fileHeadSignature, currentHeadSig != head {
            fileOffset = 0
            states.removeAll()
            lastEventInfo = nil
        }
        fileHeadSignature = head

        // 文件大小变小（被截断或替换），重置偏移量并清空缓存重读
        if currentSize < fileOffset {
            fileOffset = 0
            states.removeAll()
            lastEventInfo = nil
        }

        if currentSize == fileOffset && fileOffset > 0 {
            return states
        }

        do {
            try handle.seek(toOffset: fileOffset)
        } catch {
            return states
        }

        let chunk = handle.readDataToEndOfFile()
        guard !chunk.isEmpty else {
            return states
        }

        // 寻找最后一个换行符 \n (0x0A)
        guard let lastNewlineIndex = chunk.lastIndex(of: 0x0A) else {
            // 没有完整的行，留到下次读取
            return states
        }

        // 只处理截止到最后一个 \n 的完整行数据
        let validData = chunk.subdata(in: 0..<lastNewlineIndex)
        fileOffset += UInt64(lastNewlineIndex + 1)

        // 按 0x0A 字节切行，每行单独 UTF-8 解码，单行解码失败只跳过该行
        var lineStart = 0
        for i in 0..<validData.count {
            if validData[i] == 0x0A {
                if i > lineStart {
                    let lineBytes = validData.subdata(in: lineStart..<i)
                    if let lineStr = String(data: lineBytes, encoding: .utf8) {
                        let trimmed = lineStr.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            parseLine(trimmed)
                        }
                    }
                }
                lineStart = i + 1
            }
        }
        if lineStart < validData.count {
            let lineBytes = validData.subdata(in: lineStart..<validData.count)
            if let lineStr = String(data: lineBytes, encoding: .utf8) {
                let trimmed = lineStr.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    parseLine(trimmed)
                }
            }
        }

        return states
    }

    private func parseLine(_ line: String) {
        // 格式：<unix 秒>\t<hook 的 stdin JSON>
        guard let tabIndex = line.firstIndex(of: "\t") else {
            return
        }

        let timeStr = String(line[..<tabIndex])
        let jsonStr = String(line[line.index(after: tabIndex)...])

        guard let timestamp = Double(timeStr) else {
            return
        }
        let date = Date(timeIntervalSince1970: timestamp)

        guard let jsonData = jsonStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            return
        }

        guard let sessionId = json["session_id"] as? String, !sessionId.isEmpty else {
            return
        }

        let event = json["hook_event_name"] as? String ?? ""
        let transcriptPath = json["transcript_path"] as? String
        let notificationType = json["notification_type"] as? String
        let message = json["message"] as? String
        let toolName = json["tool_name"] as? String

        var toolDetail: String? = nil
        var isCmd = false
        if let toolInput = json["tool_input"] as? [String: Any] {
            if let cmd = toolInput["command"] as? String {
                toolDetail = cmd
                isCmd = true
            } else if let filePath = toolInput["file_path"] as? String {
                toolDetail = filePath
            }
        }
        if toolDetail == nil {
            toolDetail = toolName
        }

        let suppressCompletion = (event == "StopFailure")

        let state = ClaudeHookState(
            event: event,
            at: date,
            notificationType: notificationType,
            message: message,
            toolName: toolName,
            toolDetail: toolDetail,
            transcriptPath: transcriptPath,
            detailIsCommand: isCmd,
            suppressCompletion: suppressCompletion
        )

        states[sessionId] = state
        lastEventInfo = (at: date, event: event)
    }
}
