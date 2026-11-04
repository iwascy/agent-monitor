import AppKit
import Foundation
import AgentMonitorCore

public enum JumpTarget: Sendable {
    case terminal(host: HostInfo, windowHint: String?)
    case editor(bundleId: String, folder: URL)
    case app(bundleId: String)
}

@MainActor
public final class SessionJumper {
    public static let shared = SessionJumper()

    nonisolated public static let editorBundleIds: Set<String> = [
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92", // Cursor
        "com.exafunction.windsurf",
        "dev.zed.Zed"
    ]

    nonisolated public static let terminalBundleIds: [String] = [
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty",
        "com.github.wez.wezterm",
        "org.alacritty",
        "com.apple.Terminal"
    ]

    private let describe: @Sendable (AgentSession) -> String?

    public init() {
        self.describe = Self.computeDescribeTarget
    }

    init(describe: @escaping @Sendable (AgentSession) -> String?) {
        self.describe = describe
    }

    nonisolated public static func firstRunningTerminalBundleId() -> String {
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

    nonisolated public static func codexDesktopBundleId() -> String {
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
        Self.resolveTarget(for: session)
    }

    nonisolated private static func resolveTarget(for session: AgentSession) -> JumpTarget {
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

    public func jump(to session: AgentSession, onSuccess: (@MainActor () -> Void)? = nil) {
        let request = SessionNavigationRequest(kind: session.kind, sessionID: session.id,
                                               entrypoint: session.entrypoint, cwd: session.cwd)
        let isCodexCLI = session.kind == .codex && session.originator != nil
            && !(session.originator?.contains("Desktop") ?? false)
        // Desktop sessions must keep their exact conversation link even when
        // the adapter also discovers a backing CLI process.
        let isDesktop = session.kind == .codex && !isCodexCLI
            || session.kind == .claudeCode && session.entrypoint != nil && session.entrypoint != "cli"
        if request.nativeID != nil && (session.pid == nil || isDesktop) && !isCodexCLI {
            SessionNavigator.shared.open(request, onSuccess: onSuccess)
            return
        }
        let tgt = target(for: session)
        switch tgt {
        case .terminal(let host, let windowHint):
            Task { @MainActor in
                await FocusStrategies.shared.focusTerminal(host: host, titleHint: windowHint, cwd: session.cwd)
                onSuccess?()
            }
        case .editor(let bundleId, let folder):
            FocusStrategies.shared.focusEditor(bundleId: bundleId, folder: folder)
            onSuccess?()
        case .app(let bundleId):
            FocusStrategies.shared.activateAppByBundleId(bundleId)
            onSuccess?()
        }
    }

    private struct TargetDescCacheEntry {
        let description: String?
        let timestamp: Date
    }

    private var targetDescCache: [String: TargetDescCacheEntry] = [:]
    private let targetDescTTL: TimeInterval = 5.0

    public func describeTarget(for session: AgentSession) async -> String? {
        let now = Date()
        if let entry = targetDescCache[session.id], now.timeIntervalSince(entry.timestamp) < targetDescTTL {
            return entry.description
        }
        let describe = self.describe
        let desc = await Task.detached(priority: .utility) {
            describe(session)
        }.value
        targetDescCache[session.id] = TargetDescCacheEntry(description: desc, timestamp: Date())
        return desc
    }

    nonisolated private static func computeDescribeTarget(for session: AgentSession) -> String? {
        let tgt = resolveTarget(for: session)
        switch tgt {
        case .terminal(let host, let windowHint):
            let appName = host.app.localizedName ?? "终端"
            if let matchedTitle = FocusStrategies.getMatchedWindowTitle(app: host.app, titleHint: windowHint, cwd: session.cwd) {
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
