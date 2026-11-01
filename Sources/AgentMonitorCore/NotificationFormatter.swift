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

    public static func formatTitle(for session: AgentSession) -> String {
        let cleaned = cleanTitle(session.title, maxLength: 40)
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

    public static func formatDuration(seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        if m > 0 {
            return "\(m) 分 \(s) 秒"
        } else {
            return "\(s) 秒"
        }
    }

    public static func cleanBody(_ raw: String, maxLength: Int = 120) -> String {
        var text = raw

        // 1. Markdown links: [text](url) -> text
        text = text.replacingOccurrences(of: #"(?s)\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)

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

        if text.count > maxLength {
            let idx = text.index(text.startIndex, offsetBy: maxLength - 1)
            text = String(text[..<idx]) + "…"
        }
        return text
    }
}
