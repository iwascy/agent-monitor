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

    public init(sessionStore: SessionStore) {
        self.sessionStore = sessionStore
        self.isNotificationsPaused = notifier.isPaused
        self.isLaunchAtLogin = SMAppService.mainApp.status == .enabled

        sessionStore.onSessionsUpdated = { [weak self] updated in
            Task { @MainActor in
                self?.sessions = updated
            }
        }

        sessionStore.onTransition = { [weak self] transition in
            Task { @MainActor in
                self?.notifier.notify(transition: transition)
            }
        }

        sessionStore.start()

        // After initial scan finishes, allow notifications for subsequent changes
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            self.notifier.isInitialScan = false
        }
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
        isNotificationsPaused = notifier.isPaused
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
