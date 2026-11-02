import AppKit
import SwiftUI

public enum SettingsTab: Hashable, Sendable {
    case general
    case notification
    case agents
    case mute
    case integration
    case hotkey
}

@MainActor
public final class SettingsWindowManager: ObservableObject {
    public static let shared = SettingsWindowManager()

    @Published public var selectedTab: SettingsTab = .general
    private var openSettingsAction: (() -> Void)?
    private var hasPendingRequest = false
    private let activateApp: () -> Void

    init(activateApp: @escaping () -> Void = {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }) {
        self.activateApp = activateApp
        if let tabEnv = ProcessInfo.processInfo.environment["AGENT_MONITOR_SETTINGS_TAB"]?.lowercased() {
            switch tabEnv {
            case "general": selectedTab = .general
            case "notification": selectedTab = .notification
            case "agents": selectedTab = .agents
            case "mute": selectedTab = .mute
            case "integration": selectedTab = .integration
            case "hotkey": selectedTab = .hotkey
            default: break
            }
        }
    }

    public func openSettings(tab: SettingsTab? = nil) {
        if let tab = tab {
            selectedTab = tab
        }
        hasPendingRequest = true
        openPendingSettings()
    }

    public func installOpenSettingsAction(_ action: @escaping () -> Void) {
        openSettingsAction = action
        openPendingSettings()
    }

    private func openPendingSettings() {
        guard hasPendingRequest, let action = openSettingsAction else { return }
        hasPendingRequest = false
        activateApp()
        action()
    }
}
