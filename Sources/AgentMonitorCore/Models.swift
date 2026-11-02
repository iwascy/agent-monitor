import Foundation

public enum SessionState: String, Codable, Sendable, CaseIterable {
    case running
    case waitingForUser
    case completed
    case idle
}

public enum AgentKind: String, Codable, Sendable, CaseIterable {
    case claudeCode = "claudeCode"
    case codex = "codex"
    case dsh = "dsh"
    case antigravity = "antigravity"

    public var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .dsh: return "DeepSeek Harness"
        case .antigravity: return "Antigravity"
        }
    }

    public var shortCode: String {
        switch self {
        case .claudeCode: return "CC"
        case .codex: return "CX"
        case .dsh: return "DS"
        case .antigravity: return "AG"
        }
    }

    public var bundleIdentifier: String {
        switch self {
        case .claudeCode: return "com.anthropic.claudefordesktop"
        case .codex: return "com.openai.chat"
        case .dsh: return "com.deepseek.dsh"
        case .antigravity: return "com.google.antigravity"
        }
    }
}

public struct AgentSession: Identifiable, Equatable, Sendable {
    public let id: String            // "\(kind.rawValue):\(nativeId)"
    public let kind: AgentKind       // .claudeCode, .codex, .dsh, .antigravity
    public var title: String         // 会话名，没有就用 cwd 最后一段
    public var cwd: String?
    public var state: SessionState
    public var stateSince: Date
    public var lastActivity: Date
    public var detail: String?       // 例如 "等待授权: Bash(rm ...)"、最后一句助手消息的前 80 字
    public var detailIsCommand: Bool
    public var waitingLabel: String? // "等待授权" 或 "在问你"
    public var completedDuration: TimeInterval?
    public var entrypoint: String?
    public var suppressCompletion: Bool // 本轮结束不升级为 completed（例如 Codex 定时任务的 heartbeat）
    public var pid: Int32?              // agent 进程 PID，用于 F1 找宿主终端
    public var transcriptPath: String?  // 会话记录文件，F6 增量读取用
    public var originator: String?      // Codex session_meta.originator，例如 "Codex Desktop"、"codex_cli_rs"
    public var usage: SessionUsage?     // F6

    public init(
        id: String,
        kind: AgentKind,
        title: String,
        cwd: String? = nil,
        state: SessionState,
        stateSince: Date = Date(),
        lastActivity: Date = Date(),
        detail: String? = nil,
        detailIsCommand: Bool = false,
        waitingLabel: String? = nil,
        completedDuration: TimeInterval? = nil,
        entrypoint: String? = nil,
        suppressCompletion: Bool = false,
        pid: Int32? = nil,
        transcriptPath: String? = nil,
        originator: String? = nil,
        usage: SessionUsage? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.cwd = cwd
        self.state = state
        self.stateSince = stateSince
        self.lastActivity = lastActivity
        self.detail = detail
        self.detailIsCommand = detailIsCommand
        self.waitingLabel = waitingLabel
        self.completedDuration = completedDuration
        self.entrypoint = entrypoint
        self.suppressCompletion = suppressCompletion
        self.pid = pid
        self.transcriptPath = transcriptPath
        self.originator = originator
        self.usage = usage
    }
}

public struct SessionUsage: Equatable, Sendable {
    public var model: String?
    public var inputTokens: Int?          // 本会话累计，不含缓存
    public var cachedInputTokens: Int?    // Claude: cache_read_input_tokens；Codex: cached_input_tokens
    public var cacheWriteTokens: Int?     // Claude: cache_creation_input_tokens
    public var outputTokens: Int?
    public var reasoningTokens: Int?      // Codex: reasoning_output_tokens
    public var requestCount: Int?         // Claude: 去重后的 message.id 数
    public var contextTokens: Int?        // 当前上下文占用
    public var contextWindow: Int?        // 已知窗口大小；Claude 为 nil
    public var steps: Int?                // Antigravity step_count
    public var updatedAt: Date

    public init(
        model: String? = nil,
        inputTokens: Int? = nil,
        cachedInputTokens: Int? = nil,
        cacheWriteTokens: Int? = nil,
        outputTokens: Int? = nil,
        reasoningTokens: Int? = nil,
        requestCount: Int? = nil,
        contextTokens: Int? = nil,
        contextWindow: Int? = nil,
        steps: Int? = nil,
        updatedAt: Date = Date()
    ) {
        self.model = model
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.requestCount = requestCount
        self.contextTokens = contextTokens
        self.contextWindow = contextWindow
        self.steps = steps
        self.updatedAt = updatedAt
    }
}

public struct MuteRule: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var path: String          // 绝对路径，已展开 ~，末尾不带 /
    public var scope: Scope          // .all / .completedOnly
    public var hideInPanel: Bool

    public enum Scope: String, Codable, Sendable { case all, completedOnly }

    public init(id: UUID = UUID(), path: String, scope: Scope = .all, hideInPanel: Bool = false) {
        self.id = id
        self.path = path
        self.scope = scope
        self.hideInPanel = hideInPanel
    }

    public static func matchingRule(for cwd: String?, rules: [MuteRule]) -> MuteRule? {
        guard let cwd = cwd, !cwd.isEmpty else { return nil }
        // cwd == rule.path 或 cwd.hasPrefix(rule.path + "/") 才算命中；多条命中取 path 最长的；cwd 为 nil 时返回 nil
        let matches = rules.filter { rule in
            cwd == rule.path || cwd.hasPrefix(rule.path + "/")
        }
        return matches.max { $0.path.count < $1.path.count }
    }
}

public struct KeyCombo: Codable, Equatable, Sendable {
    public var keyCode: UInt32
    public var carbonModifiers: UInt32

    public init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }
}
