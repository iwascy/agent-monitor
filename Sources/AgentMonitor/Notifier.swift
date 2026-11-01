import Foundation
import AppKit
import UserNotifications
import AgentMonitorCore

@MainActor
public final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    public static let shared = Notifier()

    public var pauseUntil: Date? = nil
    public var onNotificationClicked: (@Sendable (String) -> Void)?

    private var recentNotifications: [String: (state: SessionState, timestamp: Date)] = [:]

    public override init() {
        super.init()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            // Authorization granted or ignored
        }
    }

    public var isPaused: Bool {
        if let until = pauseUntil {
            if Date() < until {
                return true
            } else {
                pauseUntil = nil
                return false
            }
        }
        return false
    }

    public func togglePause(hours: Double = 1.0) {
        if isPaused {
            pauseUntil = nil
        } else {
            pauseUntil = Date().addingTimeInterval(hours * 3600)
        }
    }

    public func notify(transition: SessionTransition) {
        guard !isPaused else { return }

        switch transition {
        case .added(let session):
            // .added only notifies if state is waitingForUser (avoids false alerts on new/idle sessions)
            if session.state == .waitingForUser {
                sendNotification(for: session, previousState: nil)
            }
        case .stateChanged(let session, let fromState, let toState):
            if toState == .waitingForUser || toState == .completed {
                sendNotification(for: session, previousState: fromState)
            }
        case .removed:
            break
        }
    }

    private func sendNotification(for session: AgentSession, previousState: SessionState?) {
        let now = Date()
        let key = session.id

        // Don't repeat identical state change within 30 seconds
        if let recent = recentNotifications[key] {
            if recent.state == session.state && now.timeIntervalSince(recent.timestamp) < 30.0 {
                return
            }
        }
        recentNotifications[key] = (session.state, now)

        let content = UNMutableNotificationContent()
        content.title = "\(session.kind.displayName) · \(session.title)"

        if session.state == .waitingForUser {
            content.subtitle = session.waitingLabel ?? "等待授权"
        } else if session.state == .completed {
            let durationSeconds = Int(session.completedDuration ?? session.lastActivity.timeIntervalSince(session.stateSince))
            let formatted = formatDuration(seconds: max(1, durationSeconds))
            content.subtitle = "已完成 · 用时 \(formatted)"
        }

        content.body = session.detail ?? ""
        content.sound = UNNotificationSound.default
        content.userInfo = [
            "sessionId": session.id,
            "kind": session.kind.rawValue,
            "cwd": session.cwd ?? "",
            "entrypoint": session.entrypoint ?? ""
        ]

        let request = UNNotificationRequest(
            identifier: "\(session.id)-\(Int(now.timeIntervalSince1970))",
            content: content,
            trigger: nil // immediate delivery
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                NSLog("Failed to deliver notification: %@", error.localizedDescription)
            }
        }
    }

    private func formatDuration(seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        if m > 0 {
            return "\(m) 分 \(s) 秒"
        } else {
            return "\(s) 秒"
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let sessionId = userInfo["sessionId"] as? String
        let kindRaw = userInfo["kind"] as? String
        let entrypoint = userInfo["entrypoint"] as? String
        let cwd = userInfo["cwd"] as? String

        Task { @MainActor in
            if let sid = sessionId {
                self.onNotificationClicked?(sid)
            }
            if let kindRaw = kindRaw, let kind = AgentKind(rawValue: kindRaw) {
                activateApp(for: kind, entrypoint: entrypoint, cwd: cwd)
            }
        }
        completionHandler()
    }

    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

@MainActor
public func activateApp(for kind: AgentKind, entrypoint: String? = nil, cwd: String? = nil) {
    let ws = NSWorkspace.shared

    // Claude Code CLI sessions should activate terminal instead of Claude Desktop
    if kind == .claudeCode && entrypoint == "cli" {
        let terminalIds = ["com.googlecode.iterm2", "com.apple.Terminal"]
        for tid in terminalIds {
            if let termURL = ws.urlForApplication(withBundleIdentifier: tid) {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                ws.openApplication(at: termURL, configuration: config, completionHandler: nil)
                return
            }
        }
        return
    }

    if let bundleId = kind.bundleIdentifier.isEmpty ? nil : kind.bundleIdentifier,
       let appURL = ws.urlForApplication(withBundleIdentifier: bundleId) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        ws.openApplication(at: appURL, configuration: config, completionHandler: nil)
        return
    }

    // Fallbacks
    let fallbackPath: String?
    switch kind {
    case .claudeCode:
        fallbackPath = "/Applications/Claude.app"
    case .codex:
        fallbackPath = "/Applications/ChatGPT.app"
    case .antigravity:
        fallbackPath = "/Applications/Antigravity.app"
    case .dsh:
        fallbackPath = nil
    }

    if let path = fallbackPath, FileManager.default.fileExists(atPath: path) {
        let appURL = URL(fileURLWithPath: path)
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        ws.openApplication(at: appURL, configuration: config, completionHandler: nil)
    }
}
