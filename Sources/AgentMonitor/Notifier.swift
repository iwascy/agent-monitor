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
        guard Bundle.main.bundleIdentifier != nil else {
            return
        }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            // Authorization granted or ignored
        }

        if let testKind = ProcessInfo.processInfo.environment["AGENT_MONITOR_TEST_NOTIFICATION"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.sendTestNotification(kind: testKind)
            }
        }
    }

    public func sendTestNotification(kind: String) {
        let testSession: AgentSession
        if kind == "waiting" {
            testSession = AgentSession(
                id: "test:waiting-\(Int(Date().timeIntervalSince1970))",
                kind: .codex,
                title: "重构 Cookie 同步逻辑",
                cwd: "/Users/cy/code/115-cookie",
                state: .waitingForUser,
                detail: "git push --force origin main",
                detailIsCommand: true,
                waitingLabel: "等待授权"
            )
        } else {
            testSession = AgentSession(
                id: "test:completed-\(Int(Date().timeIntervalSince1970))",
                kind: .antigravity,
                title: "Loon 规则整理",
                cwd: "/Users/cy/code/loon-rea",
                state: .completed,
                detail: "已生成 3 个文件，测试全部通过",
                completedDuration: 372
            )
        }
        sendNotification(for: testSession, previousState: nil)
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

    public static func notificationSound(name: String) -> UNNotificationSound? {
        if name == "default" {
            return .default
        } else if name == "none" {
            return nil
        } else {
            return UNNotificationSound(named: UNNotificationSoundName("\(name).aiff"))
        }
    }

    public func notify(transition: SessionTransition, isPanelVisible: Bool = false) {
        let settings = AppSettings.shared
        let snapshot = NotificationPolicy.SettingsSnapshot(
            notifyWaiting: settings.notifyWaiting,
            notifyCompleted: settings.notifyCompleted,
            minRunSecondsForCompletion: settings.minRunSecondsForCompletion,
            silenceWhilePanelOpen: settings.silenceWhilePanelOpen
        )

        let session: AgentSession
        switch transition {
        case .added(let s), .stateChanged(let s, _, _):
            session = s
        case .removed:
            return
        }

        guard NotificationPolicy.shouldNotify(
            session: session,
            transition: transition,
            settings: snapshot,
            muteRules: settings.muteRules,
            isPanelVisible: isPanelVisible,
            isNotificationsPaused: isPaused
        ) else {
            return
        }

        switch transition {
        case .added(let s):
            sendNotification(for: s, previousState: nil)
        case .stateChanged(let s, let fromState, _):
            sendNotification(for: s, previousState: fromState)
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
        content.title = NotificationFormatter.formatTitle(for: session)
        content.subtitle = NotificationFormatter.formatSubtitle(for: session)
        content.body = NotificationFormatter.formatBody(for: session)
        content.threadIdentifier = session.id
        let soundName = session.state == .waitingForUser ? AppSettings.shared.waitingSound : AppSettings.shared.completedSound
        content.sound = Self.notificationSound(name: soundName)
        content.userInfo = [
            "sessionId": session.id,
            "kind": session.kind.rawValue,
            "cwd": session.cwd ?? "",
            "entrypoint": session.entrypoint ?? ""
        ]

        if let cachedURL = IconManager.shared.cachedIconPNGURL(for: session.kind) {
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
            do {
                try FileManager.default.copyItem(at: cachedURL, to: tempURL)
                let attachment = try UNNotificationAttachment(identifier: "icon-\(session.kind.rawValue)", url: tempURL, options: nil)
                content.attachments = [attachment]
            } catch {
                NSLog("Failed to attach agent icon to notification: %@", error.localizedDescription)
            }
        }

        let request = UNNotificationRequest(
            identifier: "\(session.id)-\(Int(now.timeIntervalSince1970))",
            content: content,
            trigger: nil // immediate delivery
        )

        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                NSLog("Failed to deliver notification: %@", error.localizedDescription)
            }
        }
    }

    public func sendReminder(for session: AgentSession, index: Int) {
        let settings = AppSettings.shared
        guard !isPaused,
              settings.remindEnabled,
              settings.notifyWaiting else {
            return
        }

        if let rule = MuteRule.matchingRule(for: session.cwd, rules: settings.muteRules), rule.scope == .all {
            return
        }

        let now = Date()
        let content = UNMutableNotificationContent()
        content.title = NotificationFormatter.formatTitle(for: session)
        content.subtitle = NotificationFormatter.formatReminderSubtitle(for: session, now: now)
        content.body = NotificationFormatter.formatBody(for: session)
        content.threadIdentifier = session.id
        content.sound = Self.notificationSound(name: settings.waitingSound)
        content.userInfo = [
            "sessionId": session.id,
            "kind": session.kind.rawValue,
            "cwd": session.cwd ?? "",
            "entrypoint": session.entrypoint ?? ""
        ]

        if let cachedURL = IconManager.shared.cachedIconPNGURL(for: session.kind) {
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
            do {
                try FileManager.default.copyItem(at: cachedURL, to: tempURL)
                let attachment = try UNNotificationAttachment(identifier: "icon-\(session.kind.rawValue)", url: tempURL, options: nil)
                content.attachments = [attachment]
            } catch {
                NSLog("Failed to attach agent icon to notification: %@", error.localizedDescription)
            }
        }

        let reminderId = "\(session.id)-remind"
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [reminderId])

        let request = UNNotificationRequest(
            identifier: reminderId,
            content: content,
            trigger: nil
        )

        guard Bundle.main.bundleIdentifier != nil else { return }
        center.add(request) { error in
            if let error = error {
                NSLog("Failed to deliver reminder notification: %@", error.localizedDescription)
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

    // CLI sessions (Claude Code in a terminal, dsh) live in a terminal, not in a desktop app
    if (kind == .claudeCode && entrypoint == "cli") || kind == .dsh {
        activateTerminal()
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

private let terminalBundleIds = [
    "com.mitchellh.ghostty",
    "com.googlecode.iterm2",
    "dev.warp.Warp-Stable",
    "com.github.wez.wezterm",
    "net.kovidgoyal.kitty",
    "org.alacritty",
    "com.apple.Terminal"
]

/// Brings the terminal forward: a running one first, otherwise launches the first installed one.
@MainActor
private func activateTerminal() {
    for bundleId in terminalBundleIds {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first {
            app.activate()
            return
        }
    }

    let ws = NSWorkspace.shared
    for bundleId in terminalBundleIds {
        if let termURL = ws.urlForApplication(withBundleIdentifier: bundleId) {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            ws.openApplication(at: termURL, configuration: config, completionHandler: nil)
            return
        }
    }
}
