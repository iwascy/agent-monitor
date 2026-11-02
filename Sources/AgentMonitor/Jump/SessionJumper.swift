import AppKit
import Foundation
import AgentMonitorCore

public enum JumpTarget {
    case terminal(host: HostInfo, windowHint: String?)
    case editor(bundleId: String, folder: URL)
    case app(bundleId: String)
}

@MainActor
public final class SessionJumper {
    public static let shared = SessionJumper()

    public static let editorBundleIds: Set<String> = [
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92", // Cursor
        "com.exafunction.windsurf",
        "dev.zed.Zed"
    ]

    public static let terminalBundleIds: [String] = [
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty",
        "com.github.wez.wezterm",
        "org.alacritty",
        "com.apple.Terminal"
    ]

    public init() {}

    public static func firstRunningTerminalBundleId() -> String {
        for id in terminalBundleIds {
            if !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty {
                return id
            }
        }
        for id in terminalBundleIds {
            if NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil {
                return id
            }
        }
        return "com.apple.Terminal"
    }

    public static func codexDesktopBundleId() -> String {
        let candidates = ["com.openai.codex", "com.openai.chat"]
        for id in candidates {
            if !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty {
                return id
            }
        }
        for id in candidates {
            if NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil {
                return id
            }
        }
        if FileManager.default.fileExists(atPath: "/Applications/ChatGPT.app"),
           let bundle = Bundle(path: "/Applications/ChatGPT.app"),
           let id = bundle.bundleIdentifier {
            return id
        }
        return "com.openai.codex"
    }

    public func target(for session: AgentSession) -> JumpTarget {
        if let pid = session.pid, let host = HostResolver.shared.resolve(pid: pid) {
            let bundleId = host.app.bundleIdentifier ?? ""
            if Self.editorBundleIds.contains(bundleId) {
                if let cwd = session.cwd, !cwd.isEmpty {
                    return .editor(bundleId: bundleId, folder: URL(fileURLWithPath: cwd))
                } else {
                    return .app(bundleId: bundleId)
                }
            } else {
                return .terminal(host: host, windowHint: session.title)
            }
        }

        switch session.kind {
        case .claudeCode:
            if session.entrypoint == "cli" || session.entrypoint == nil {
                return .app(bundleId: Self.firstRunningTerminalBundleId())
            } else {
                return .app(bundleId: "com.anthropic.claudefordesktop")
            }
        case .codex:
            if let originator = session.originator, originator.contains("Desktop") {
                return .app(bundleId: Self.codexDesktopBundleId())
            } else {
                return .app(bundleId: Self.firstRunningTerminalBundleId())
            }
        case .dsh:
            return .app(bundleId: Self.firstRunningTerminalBundleId())
        case .antigravity:
            return .app(bundleId: "com.google.antigravity")
        }
    }

    public func jump(to session: AgentSession) {
        let tgt = target(for: session)
        switch tgt {
        case .terminal(let host, let windowHint):
            Task { @MainActor in
                await FocusStrategies.shared.focusTerminal(host: host, titleHint: windowHint, cwd: session.cwd)
            }
        case .editor(let bundleId, let folder):
            FocusStrategies.shared.focusEditor(bundleId: bundleId, folder: folder)
        case .app(let bundleId):
            FocusStrategies.shared.activateAppByBundleId(bundleId)
        }
    }

    private struct TargetDescCacheEntry {
        let description: String?
        let timestamp: Date
    }

    private var targetDescCache: [String: TargetDescCacheEntry] = [:]
    private let targetDescTTL: TimeInterval = 5.0

    public func describeTarget(for session: AgentSession) -> String? {
        let now = Date()
        if let entry = targetDescCache[session.id], now.timeIntervalSince(entry.timestamp) < targetDescTTL {
            return entry.description
        }
        let desc = computeDescribeTarget(for: session)
        targetDescCache[session.id] = TargetDescCacheEntry(description: desc, timestamp: now)
        return desc
    }

    private func computeDescribeTarget(for session: AgentSession) -> String? {
        let tgt = target(for: session)
        switch tgt {
        case .terminal(let host, let windowHint):
            let appName = host.app.localizedName ?? "终端"
            if let matchedTitle = FocusStrategies.shared.getMatchedWindowTitle(app: host.app, titleHint: windowHint, cwd: session.cwd) {
                return "\(appName) · 窗口「\(matchedTitle)」"
            }
            if let tty = host.tty, !tty.isEmpty {
                let shortTTY = tty.hasPrefix("/dev/") ? String(tty.dropFirst(5)) : tty
                return "\(appName) · \(shortTTY)"
            }
            return appName

        case .editor(let bundleId, let folder):
            let appName: String
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first {
                appName = app.localizedName ?? bundleId
            } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
                appName = (url.deletingPathExtension().lastPathComponent as String)
            } else {
                appName = "编辑器"
            }
            let folderName = folder.lastPathComponent
            return "\(appName) · \(folderName)"

        case .app(let bundleId):
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first {
                return app.localizedName ?? bundleId
            }
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
                return url.deletingPathExtension().lastPathComponent
            }
            switch session.kind {
            case .claudeCode: return "Claude Code"
            case .codex: return "Codex"
            case .dsh: return "DeepSeek Harness"
            case .antigravity: return "Antigravity"
            }
        }
    }
}
