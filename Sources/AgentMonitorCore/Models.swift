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
        entrypoint: String? = nil
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
    }
}
