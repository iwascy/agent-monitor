import Foundation

public struct NotificationFormatter {
    public static func cleanTitle(_ raw: String, maxLength: Int = 40) -> String {
        var text = raw.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if text.count > maxLength {
            let idx = text.index(text.startIndex, offsetBy: maxLength - 1)
            text = String(text[..<idx]) + "…"
        }
        return text
    }

    public static func formatTitle(for session: AgentSession, parentTitle: String? = nil) -> String {
        let cleaned = cleanTitle(session.title, maxLength: 40)
        if let parent = parentTitle {
            let parentCleaned = cleanTitle(parent, maxLength: 40)
            return "\(session.kind.displayName) · \(parentCleaned) › \(cleaned)"
        }
        return "\(session.kind.displayName) · \(cleaned)"
    }

    public static func formatSubtitle(for session: AgentSession) -> String {
        if session.state == .waitingForUser {
            return session.waitingLabel ?? "等待授权"
        } else if session.state == .completed {
            let durationSeconds = Int(session.completedDuration ?? session.lastActivity.timeIntervalSince(session.stateSince))
            let formatted = formatDuration(seconds: max(1, durationSeconds))
            return "已完成 · 用时 \(formatted)"
        }
        return ""
    }

    public static func formatReminderSubtitle(for session: AgentSession, now: Date = Date()) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(session.stateSince) / 60))
        return "仍在等你 · 已等 \(minutes) 分钟"
    }

    public static func formatDuration(seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        if m > 0 {
            return "\(m) 分 \(s) 秒"
        } else {
            return "\(s) 秒"
        }
    }

    public static func formatBody(for session: AgentSession) -> String {
        let detail = session.detail ?? ""
        return session.detailIsCommand ? cleanCommand(detail) : cleanBody(detail)
    }

    /// Commands are shown verbatim: `*`, `_` and backticks are meaningful there, so only collapse whitespace.
    public static func cleanCommand(_ raw: String, maxLength: Int = 120) -> String {
        let text = raw.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return truncate(text, maxLength: maxLength)
    }

    public static func cleanBody(_ raw: String, maxLength: Int = 120) -> String {
        var text = raw

        // 1. Markdown links: [text](url) -> text
        text = text.replacingOccurrences(of: #"(?s)\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        // Adapters truncate detail, which can cut a link in half: "[text](file:///Us" -> "text"
        text = text.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*$"#, with: "$1", options: .regularExpression)

        // 2. Code blocks ```...``` -> ...
        text = text.replacingOccurrences(of: #"```[a-zA-Z0-9_-]*\n?"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"```"#, with: "")

        // 3. Inline code `code` -> code
        text = text.replacingOccurrences(of: #"`([^`]+)`"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"`"#, with: "")

        // 4. Bold / italic: **text**, *text*, __text__, _text_
        text = text.replacingOccurrences(of: #"\*\*([^*]+)\*\*"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\*([^*]+)\*"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\*\*"#, with: "")
        text = text.replacingOccurrences(of: #"__([^_]+)__"#, with: "$1", options: .regularExpression)

        // 5. Header symbols: # header
        text = text.replacingOccurrences(of: #"(?m)^#{1,6}\s*"#, with: "", options: .regularExpression)

        // 6. Merge excessive blank lines / whitespace
        text = text.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\n\s*\n+"#, with: "\n", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        return truncate(text, maxLength: maxLength)
    }

    private static func truncate(_ text: String, maxLength: Int) -> String {
        guard text.count > maxLength else { return text }
        let idx = text.index(text.startIndex, offsetBy: maxLength - 1)
        return String(text[..<idx]) + "…"
    }
}
