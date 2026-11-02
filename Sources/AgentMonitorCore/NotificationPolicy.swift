import Foundation

public struct NotificationPolicy {
    public struct SettingsSnapshot: Equatable, Sendable {
        public var notifyWaiting: Bool
        public var notifyCompleted: Bool
        public var minRunSecondsForCompletion: Int
        public var silenceWhilePanelOpen: Bool

        public init(
            notifyWaiting: Bool = true,
            notifyCompleted: Bool = true,
            minRunSecondsForCompletion: Int = 10,
            silenceWhilePanelOpen: Bool = true
        ) {
            self.notifyWaiting = notifyWaiting
            self.notifyCompleted = notifyCompleted
            self.minRunSecondsForCompletion = minRunSecondsForCompletion
            self.silenceWhilePanelOpen = silenceWhilePanelOpen
        }
    }

    public static func shouldNotify(
        session: AgentSession,
        transition: SessionTransition,
        settings: SettingsSnapshot,
        muteRules: [MuteRule] = [],
        isPanelVisible: Bool = false,
        isNotificationsPaused: Bool = false
    ) -> Bool {
        // 1. Pause notifications (bell)
        if isNotificationsPaused {
            return false
        }

        // 2. Silence while panel is open
        if isPanelVisible && settings.silenceWhilePanelOpen {
            return false
        }

        // 3. Mute rules
        if let rule = MuteRule.matchingRule(for: session.cwd, rules: muteRules) {
            switch rule.scope {
            case .all:
                return false
            case .completedOnly:
                switch transition {
                case .added(let s) where s.state == .completed:
                    return false
                case .stateChanged(_, _, to: .completed):
                    return false
                default:
                    break
                }
            }
        }

        // 4. State notifications
        switch transition {
        case .added(let s):
            if s.state == .waitingForUser {
                return settings.notifyWaiting
            } else if s.state == .completed {
                guard settings.notifyCompleted else { return false }
                if settings.minRunSecondsForCompletion > 0 {
                    let duration = s.completedDuration ?? 0
                    return duration >= Double(settings.minRunSecondsForCompletion)
                }
                return true
            }
            return false

        case .stateChanged(let s, _, let to):
            if to == .waitingForUser {
                return settings.notifyWaiting
            } else if to == .completed {
                guard settings.notifyCompleted else { return false }
                if settings.minRunSecondsForCompletion > 0 {
                    let duration = s.completedDuration ?? 0
                    return duration >= Double(settings.minRunSecondsForCompletion)
                }
                return true
            }
            return false

        case .removed:
            return false
        }
    }
}
