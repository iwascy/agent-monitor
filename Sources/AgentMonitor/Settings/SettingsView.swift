import SwiftUI
import AppKit
import AgentMonitorCore

public struct SettingsView: View {
    public let sessionStore: SessionStore?
    @ObservedObject private var manager = SettingsWindowManager.shared

    public init(sessionStore: SessionStore? = nil) {
        self.sessionStore = sessionStore
    }

    public var body: some View {
        TabView(selection: $manager.selectedTab) {
            GeneralSettingsView()
                .tabItem {
                    Label("通用", systemImage: "gearshape")
                }
                .tag(SettingsTab.general)

            NotificationSettingsView()
                .tabItem {
                    Label("通知", systemImage: "bell")
                }
                .tag(SettingsTab.notification)

            AgentSettingsView(sessionStore: sessionStore)
                .tabItem {
                    Label("Agent", systemImage: "square.grid.2x2")
                }
                .tag(SettingsTab.agents)

            MuteSettingsView()
                .tabItem {
                    Label("静音", systemImage: "bell.slash")
                }
                .tag(SettingsTab.mute)

            IntegrationSettingsView(sessionStore: sessionStore)
                .tabItem {
                    Label("集成", systemImage: "powerplug")
                }
                .tag(SettingsTab.integration)

            HotkeySettingsView()
                .tabItem {
                    Label("快捷键", systemImage: "keyboard")
                }
                .tag(SettingsTab.hotkey)
        }
        .frame(width: 600)
        .fixedSize(horizontal: true, vertical: false)
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        .onDisappear {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
