import AppKit
import ApplicationServices
import AgentMonitorCore

@MainActor
final class SessionNavigator {
    static let shared = SessionNavigator()
    private var isOpening = false
    private var pending: (SessionNavigationRequest, (@MainActor () -> Void)?)?

    func open(_ request: SessionNavigationRequest, onSuccess: (@MainActor () -> Void)? = nil) {
        guard !isOpening else {
            pending = (request, onSuccess)
            return
        }
        isOpening = true
        Task {
            defer {
                isOpening = false
                if let next = pending {
                    pending = nil
                    open(next.0, onSuccess: next.1)
                }
            }
            let target = await Task.detached { SessionNavigationResolver().resolve(request) }.value
            do {
                switch target {
                case .deepLink(let url, let bundleID):
                    let appURL = applicationURL(bundleID: bundleID, kind: request.kind)
                    guard let appURL else { throw Failure("未找到对应应用。") }
                    // Route explicitly to this app instead of whichever application
                    // last registered the custom scheme.
                    let config = NSWorkspace.OpenConfiguration()
                    config.activates = true
                    try await NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: config)
                case .antigravity(let id):
                    let app = try await activate(kind: .antigravity)
                    if await AntigravityConnection().focus(nativeID: id) { break }
                    guard AXIsProcessTrusted() else {
                        throw Failure("Antigravity 的本地会话接口不可用；可为 Agent Monitor 开启「系统设置 → 隐私与安全性 → 辅助功能」，以使用辅助功能定位。")
                    }
                    guard await AntigravitySessionNavigator.focus(processID: app.processIdentifier, nativeID: id) else {
                        throw Failure("未能在 Antigravity 会话列表中找到该 ID。请展开对应项目后重试。")
                    }
                case .terminal(let pid):
                    let identity = await Task.detached { TerminalSessionNavigator.identity(processID: pid) }.value
                    guard let identity else {
                        throw Failure("会话进程没有可定位的终端，或终端类型尚不支持。支持 Terminal、iTerm2 以及 Warp。")
                    }
                    let warpURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "dev.warp.Warp-Stable")?
                        .appendingPathComponent("Contents/MacOS/stable").path
                    let focused = await Task.detached { TerminalSessionNavigator.focus(identity, warpExecutable: warpURL) }.value
                    guard focused else {
                        throw Failure("无法选择原终端会话。Terminal / iTerm2 需要自动化权限；Warp 需要能匹配原会话 ID。")
                    }
                case .unavailable(let reason):
                    throw Failure(reason)
                }
                onSuccess?()
            } catch {
                // A failed selection is visible to the user rather than silently
                // opening an unrelated application/window or starting another agent.
                let alert = NSAlert()
                alert.messageText = "无法定位到对应会话"
                alert.informativeText = (error as? Failure)?.reason ?? error.localizedDescription
                alert.addButton(withTitle: "好")
                NSApp.activate()
                alert.runModal()
            }
        }
    }

    private struct Failure: Error {
        let reason: String
        init(_ reason: String) { self.reason = reason }
    }

    private func applicationURL(bundleID: String, kind: AgentKind) -> URL? {
        let ws = NSWorkspace.shared
        if let url = ws.urlForApplication(withBundleIdentifier: bundleID) { return url }
        // Older Codex distributions still use the ChatGPT bundle ID.
        if kind == .codex, let url = ws.urlForApplication(withBundleIdentifier: "com.openai.chat") { return url }
        let path: String
        switch kind {
        case .claudeCode: path = "/Applications/Claude.app"
        case .codex: path = "/Applications/ChatGPT.app"
        case .antigravity: path = "/Applications/Antigravity.app"
        case .dsh: path = "/Applications/Paseo.app"
        }
        return FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    private func activate(kind: AgentKind) async throws -> NSRunningApplication {
        guard let url = applicationURL(bundleID: kind.bundleIdentifier, kind: kind) else { throw Failure("未找到对应应用。") }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        return try await NSWorkspace.shared.openApplication(at: url, configuration: config)
    }
}

@MainActor
private enum AntigravitySessionNavigator {
    static func focus(processID: pid_t, nativeID: String) async -> Bool {
        let app = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(app, 0.25)
        // Wait for a newly opened Electron window to publish its AX tree.
        for _ in 0..<8 {
            if pressConversation(in: app, nativeID: nativeID) { return true }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return false
    }

    private static func pressConversation(in app: AXUIElement, nativeID: String) -> Bool {
        // Already on the requested conversation is also success.
        if find(in: app, where: { element in
            string(element, kAXRoleAttribute) == "AXWebArea" && matches(element, id: nativeID)
        }) != nil { return true }
        guard let link = find(in: app, where: { element in
            string(element, kAXRoleAttribute) == "AXLink" && matches(element, id: nativeID)
        }) else { return false }
        guard AXUIElementPerformAction(link, kAXPressAction as CFString) == .success else { return false }
        // The outer retry loop verifies the selected web area's URL on its next pass.
        return false
    }

    private static func matches(_ element: AXUIElement, id: String) -> Bool {
        for attribute in [kAXURLAttribute, kAXValueAttribute] {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { continue }
            let url = (value as? URL) ?? (value as? String).flatMap(URL.init(string:))
            if let url, isAntigravityConversationURL(url, nativeID: id) { return true }
        }
        return false
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func find(in root: AXUIElement, where predicate: (AXUIElement) -> Bool) -> AXUIElement? {
        var queue = [root]
        var index = 0
        let deadline = Date().addingTimeInterval(0.7)
        while index < queue.count, index < 2000, Date() < deadline {
            let element = queue[index]
            index += 1
            if predicate(element) { return element }
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
               let children = value as? [AXUIElement] { queue.append(contentsOf: children) }
        }
        return nil
    }
}

func isAntigravityConversationURL(_ url: URL, nativeID: String) -> Bool {
    ["http", "https"].contains(url.scheme) &&
    ["127.0.0.1", "localhost"].contains(url.host) &&
    url.path == "/c/\(nativeID)"
}

@MainActor
public func activateApp(for kind: AgentKind, sessionID: String? = nil, entrypoint: String? = nil, cwd: String? = nil, onSuccess: (@MainActor () -> Void)? = nil) {
    SessionNavigator.shared.open(SessionNavigationRequest(kind: kind, sessionID: sessionID, entrypoint: entrypoint, cwd: cwd), onSuccess: onSuccess)
}
