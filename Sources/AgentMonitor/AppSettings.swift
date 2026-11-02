import Foundation
import Combine
import Carbon
import AgentMonitorCore

@MainActor
public final class AppSettings: ObservableObject {
    public static let shared = AppSettings()

    private let defaults: UserDefaults

    public static let defaultTogglePanelHotkey = KeyCombo(
        keyCode: UInt32(kVK_ANSI_A),
        carbonModifiers: UInt32(controlKey | optionKey)
    )

    @Published public var activityWindowHours: Int {
        didSet { defaults.set(activityWindowHours, forKey: "am.activityWindowHours") }
    }

    @Published public var idleExpandedByDefault: Bool {
        didSet { defaults.set(idleExpandedByDefault, forKey: "am.idleExpandedByDefault") }
    }

    @Published public var showUsage: Bool {
        didSet { defaults.set(showUsage, forKey: "am.showUsage") }
    }

    @Published public var showWaitingCountInMenuBar: Bool {
        didSet { defaults.set(showWaitingCountInMenuBar, forKey: "am.showWaitingCount") }
    }

    @Published public var notifyWaiting: Bool {
        didSet { defaults.set(notifyWaiting, forKey: "am.notifyWaiting") }
    }

    @Published public var notifyCompleted: Bool {
        didSet { defaults.set(notifyCompleted, forKey: "am.notifyCompleted") }
    }

    @Published public var waitingSound: String {
        didSet { defaults.set(waitingSound, forKey: "am.waitingSound") }
    }

    @Published public var completedSound: String {
        didSet { defaults.set(completedSound, forKey: "am.completedSound") }
    }

    @Published public var minRunSecondsForCompletion: Int {
        didSet { defaults.set(minRunSecondsForCompletion, forKey: "am.minRunSeconds") }
    }

    @Published public var remindEnabled: Bool {
        didSet { defaults.set(remindEnabled, forKey: "am.remindEnabled") }
    }

    @Published public var remindAfterMinutes: Int {
        didSet { defaults.set(remindAfterMinutes, forKey: "am.remindAfterMinutes") }
    }

    @Published public var remindMaxCount: Int {
        didSet { defaults.set(remindMaxCount, forKey: "am.remindMaxCount") }
    }

    @Published public var overdueBadgeRed: Bool {
        didSet { defaults.set(overdueBadgeRed, forKey: "am.overdueBadgeRed") }
    }

    @Published public var silenceWhilePanelOpen: Bool {
        didSet { defaults.set(silenceWhilePanelOpen, forKey: "am.silenceWhilePanelOpen") }
    }

    @Published public var disabledAgents: Set<AgentKind> {
        didSet {
            let array = disabledAgents.map { $0.rawValue }
            defaults.set(array, forKey: "am.disabledAgents")
        }
    }

    @Published public var muteRules: [MuteRule] {
        didSet {
            if let data = try? JSONEncoder().encode(muteRules) {
                defaults.set(data, forKey: "am.muteRules")
            }
        }
    }

    @Published public var hotkeyTogglePanel: KeyCombo? {
        didSet {
            if let combo = hotkeyTogglePanel, let data = try? JSONEncoder().encode(combo) {
                defaults.set(data, forKey: "am.hotkey.toggle")
            } else {
                defaults.removeObject(forKey: "am.hotkey.toggle")
            }
        }
    }

    @Published public var hotkeyJumpWaiting: KeyCombo? {
        didSet {
            if let combo = hotkeyJumpWaiting, let data = try? JSONEncoder().encode(combo) {
                defaults.set(data, forKey: "am.hotkey.jump")
            } else {
                defaults.removeObject(forKey: "am.hotkey.jump")
            }
        }
    }

    public init(defaults: UserDefaults? = nil) {
        let isMock = ProcessInfo.processInfo.environment["AGENT_MONITOR_MOCK_DATA"] != nil
        let resolvedDefaults: UserDefaults
        if let custom = defaults {
            resolvedDefaults = custom
        } else if isMock {
            let mockDefaults = UserDefaults(suiteName: "am.mock") ?? .standard
            mockDefaults.removePersistentDomain(forName: "am.mock")
            resolvedDefaults = mockDefaults
        } else {
            resolvedDefaults = .standard
        }
        self.defaults = resolvedDefaults

        self.activityWindowHours = resolvedDefaults.object(forKey: "am.activityWindowHours") as? Int ?? 6
        self.idleExpandedByDefault = resolvedDefaults.bool(forKey: "am.idleExpandedByDefault")
        self.showUsage = resolvedDefaults.object(forKey: "am.showUsage") as? Bool ?? true
        self.showWaitingCountInMenuBar = resolvedDefaults.object(forKey: "am.showWaitingCount") as? Bool ?? true
        self.notifyWaiting = resolvedDefaults.object(forKey: "am.notifyWaiting") as? Bool ?? true
        self.notifyCompleted = resolvedDefaults.object(forKey: "am.notifyCompleted") as? Bool ?? true
        self.waitingSound = resolvedDefaults.string(forKey: "am.waitingSound") ?? "default"
        self.completedSound = resolvedDefaults.string(forKey: "am.completedSound") ?? "default"
        self.minRunSecondsForCompletion = resolvedDefaults.object(forKey: "am.minRunSeconds") as? Int ?? 10
        self.remindEnabled = resolvedDefaults.object(forKey: "am.remindEnabled") as? Bool ?? true
        self.remindAfterMinutes = resolvedDefaults.object(forKey: "am.remindAfterMinutes") as? Int ?? 5
        self.remindMaxCount = resolvedDefaults.object(forKey: "am.remindMaxCount") as? Int ?? 2
        self.overdueBadgeRed = resolvedDefaults.object(forKey: "am.overdueBadgeRed") as? Bool ?? true
        self.silenceWhilePanelOpen = resolvedDefaults.object(forKey: "am.silenceWhilePanelOpen") as? Bool ?? true

        if let rawArray = resolvedDefaults.stringArray(forKey: "am.disabledAgents") {
            self.disabledAgents = Set(rawArray.compactMap { AgentKind(rawValue: $0) })
        } else {
            self.disabledAgents = []
        }

        if let data = resolvedDefaults.data(forKey: "am.muteRules"),
           let rules = try? JSONDecoder().decode([MuteRule].self, from: data) {
            self.muteRules = rules
        } else {
            self.muteRules = []
        }

        if let data = resolvedDefaults.data(forKey: "am.hotkey.toggle"),
           let combo = try? JSONDecoder().decode(KeyCombo.self, from: data) {
            self.hotkeyTogglePanel = combo
        } else if resolvedDefaults.object(forKey: "am.hotkey.toggle") == nil {
            self.hotkeyTogglePanel = AppSettings.defaultTogglePanelHotkey
        } else {
            self.hotkeyTogglePanel = nil
        }

        if let data = resolvedDefaults.data(forKey: "am.hotkey.jump"),
           let combo = try? JSONDecoder().decode(KeyCombo.self, from: data) {
            self.hotkeyJumpWaiting = combo
        } else {
            self.hotkeyJumpWaiting = nil
        }
    }
}
