import Foundation
import SwiftUI
import ServiceManagement
import AgentMonitorCore

@MainActor
public final class MonitorViewModel: ObservableObject {
    @Published public private(set) var sessions: [AgentSession] = []
    @Published public private(set) var isNotificationsPaused: Bool = false
    @Published public private(set) var isLaunchAtLogin: Bool = false

    @Published public var hoveredSessionId: String? = nil
    @Published public var isIdleExpanded: Bool = false
    @Published public var filterState: SessionState? = nil

    private let sessionStore: SessionStore
    private let notifier = Notifier.shared
    private var pauseExpiryTimer: DispatchSourceTimer?

    public init(sessionStore: SessionStore) {
        self.sessionStore = sessionStore
        self.isLaunchAtLogin = SMAppService.mainApp.status == .enabled

        sessionStore.onSessionsUpdated = { [weak self] updated in
            Task { @MainActor in
                self?.sessions = updated
                self?.checkPauseExpiry()
            }
        }

        sessionStore.onTransition = { [weak self] transition in
            Task { @MainActor in
                self?.notifier.notify(transition: transition)
            }
        }

        notifier.onNotificationClicked = { [weak self] sessionId in
            Task { @MainActor in
                self?.markAsRead(id: sessionId)
            }
        }

        updatePauseState()
        sessionStore.start()
    }

    public func markAsRead(id: String) {
        sessionStore.markAsRead(id: id)
        sessions = sessionStore.currentSessions
    }

    public func markAllAsRead() {
        sessionStore.markAllAsRead()
        sessions = sessionStore.currentSessions
    }

    public func togglePauseNotifications() {
        notifier.togglePause(hours: 1.0)
        updatePauseState()
    }

    private func checkPauseExpiry() {
        if isNotificationsPaused && !notifier.isPaused {
            updatePauseState()
        }
    }

    private func updatePauseState() {
        isNotificationsPaused = notifier.isPaused
        pauseExpiryTimer?.cancel()
        pauseExpiryTimer = nil

        if let until = notifier.pauseUntil {
            let delay = max(0.1, until.timeIntervalSinceNow)
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + delay)
            timer.setEventHandler { [weak self] in
                self?.isNotificationsPaused = self?.notifier.isPaused ?? false
                self?.pauseExpiryTimer?.cancel()
                self?.pauseExpiryTimer = nil
            }
            timer.resume()
            self.pauseExpiryTimer = timer
        }
    }

    public func setLaunchAtLogin(_ enable: Bool) {
        do {
            if enable {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            isLaunchAtLogin = SMAppService.mainApp.status == .enabled
        } catch {
            NSLog("Failed to update launch at login: %@", error.localizedDescription)
            isLaunchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
