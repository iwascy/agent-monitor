import Foundation
import AppKit
import UserNotifications
import AgentMonitorCore

@MainActor
public final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    public static let shared = Notifier()

    public var pauseUntil: Date? = nil
    public var onNotificationClicked: (@Sendable (String) -> Void)?
    public var sessionProvider: (@Sendable (String) -> AgentSession?)?
    public var parentTitle: ((String) -> String?)?

    #if DEBUG
    public var onNotificationSent: (@MainActor (UNNotificationRequest) -> Void)?
    #endif

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
            // 系统音目录不在通知声音的搜索路径中，使用默认音作为回退。
            return .default
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
        case .removed(let id):
            removeWaitingNotifications(for: id)
            return
        }

        if case .stateChanged(let s, let fromState, let toState) = transition,
           fromState == .waitingForUser,
           toState != .waitingForUser {
            removeWaitingNotifications(for: s.id)
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
        case .added(let session):
            // .added only notifies if state is waitingForUser (avoids false alerts on new/idle sessions)
            if session.state == .waitingForUser {
                sendNotification(for: session, previousState: nil)
            }
        case .stateChanged(let session, let fromState, let toState):
            if toState == .completed {
                // 子代理完成不发通知（只在主会话完成时通知）
                if session.parentId != nil { return }
                sendNotification(for: session, previousState: fromState)
            } else if toState == .waitingForUser {
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

        let parentTitleText = session.parentId.flatMap { parentTitle?($0) }
        let content = UNMutableNotificationContent()
        content.title = NotificationFormatter.formatTitle(for: session, parentTitle: parentTitleText)
        content.subtitle = NotificationFormatter.formatSubtitle(for: session)
        content.body = NotificationFormatter.formatBody(for: session)
        content.threadIdentifier = session.id
        let soundName = session.state == .waitingForUser ? AppSettings.shared.waitingSound : AppSettings.shared.completedSound
        content.sound = Self.notificationSound(name: soundName)
        content.userInfo = [
            "sessionId": session.id,
            "kind": session.kind.rawValue,
            "cwd": session.cwd ?? "",
            "entrypoint": session.entrypoint ?? "",
            "originator": session.originator ?? ""
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

        let identifier = session.state == .waitingForUser
            ? "\(session.id)-waiting"
            : "\(session.id)-\(Int(now.timeIntervalSince1970))"

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil // immediate delivery
        )

        #if DEBUG
        onNotificationSent?(request)
        #endif

        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                NSLog("Failed to deliver notification: %@", error.localizedDescription)
            }
        }
    }

    private func removeWaitingNotifications(for sessionId: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [
            "\(sessionId)-waiting",
            "\(sessionId)-remind"
        ])
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
            "entrypoint": session.entrypoint ?? "",
            "originator": session.originator ?? ""
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
        let action = userInfo["action"] as? String
        let sessionId = userInfo["sessionId"] as? String
        let kindRaw = userInfo["kind"] as? String
        let entrypoint = userInfo["entrypoint"] as? String
        let originator = userInfo["originator"] as? String
        let cwd = userInfo["cwd"] as? String

        Task { @MainActor in
            if let act = action, act == "openIntegrationSettings" {
                SettingsWindowManager.shared.openSettings(tab: .integration)
                return
            }

            guard let sid = sessionId else { return }

            let sessionToJump: AgentSession
            if let existing = self.sessionProvider?(sid) {
                sessionToJump = existing
            } else {
                let kind = kindRaw.flatMap { AgentKind(rawValue: $0) } ?? .claudeCode
                sessionToJump = AgentSession(
                    id: sid,
                    kind: kind,
                    title: "",
                    cwd: cwd,
                    state: .idle,
                    entrypoint: entrypoint,
                    originator: originator
                )
            }
            SessionJumper.shared.jump(to: sessionToJump) {
                self.onNotificationClicked?(sid)
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
