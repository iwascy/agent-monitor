import SwiftUI
import AppKit
import AgentMonitorCore

public struct SettingsView: View {
    public let sessionStore: SessionStore?

    public init(sessionStore: SessionStore? = nil) {
        self.sessionStore = sessionStore
    }

    public var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("通用", systemImage: "gearshape")
                }

            NotificationSettingsView()
                .tabItem {
                    Label("通知", systemImage: "bell")
                }

            AgentSettingsView(sessionStore: sessionStore)
                .tabItem {
                    Label("Agent", systemImage: "square.grid.2x2")
                }

            MuteSettingsView()
                .tabItem {
                    Label("静音", systemImage: "bell.slash")
                }

            IntegrationSettingsView()
                .tabItem {
                    Label("集成", systemImage: "powerplug")
                }

            HotkeySettingsView()
                .tabItem {
                    Label("快捷键", systemImage: "keyboard")
                }
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
