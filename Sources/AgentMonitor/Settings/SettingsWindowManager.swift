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
    public var openSettingsAction: (() -> Void)?

    private init() {}

    public func openSettings(tab: SettingsTab? = nil) {
        if let tab = tab {
            selectedTab = tab
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let action = openSettingsAction {
            action()
        } else if #available(macOS 14.0, *) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        } else {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }
}
