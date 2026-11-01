import SwiftUI
import AgentMonitorCore

extension SessionState {
    public var tint: Color {
        switch self {
        case .waitingForUser:
            return .orange
        case .completed:
            return .green
        case .running:
            return .blue
        case .idle:
            return .gray
        }
    }

    public var title: String {
        switch self {
        case .waitingForUser:
            return "等你回复"
        case .completed:
            return "已完成"
        case .running:
            return "运行中"
        case .idle:
            return "空闲"
        }
    }

    public var shortTitle: String {
        switch self {
        case .waitingForUser:
            return "等你"
        case .completed:
            return "已完成"
        case .running:
            return "运行中"
        case .idle:
            return "空闲"
        }
    }
}

public struct StatusStyle {
    public static func formattedTime(session: AgentSession) -> String {
        switch session.state {
        case .running:
            let elapsed = max(0, Int(Date().timeIntervalSince(session.stateSince)))
            let m = elapsed / 60
            let s = elapsed % 60
            return String(format: "%d:%02d", m, s)
        case .waitingForUser:
            let diff = max(0, Int(Date().timeIntervalSince(session.stateSince)))
            let m = diff / 60
            if m < 1 {
                return "刚刚"
            } else if m < 60 {
                return "\(m) 分钟"
            } else {
                let h = m / 60
                return "\(h) 小时"
            }
        case .completed, .idle:
            let diff = max(0, Int(Date().timeIntervalSince(session.lastActivity)))
            let m = diff / 60
            if m < 1 {
                return "刚刚"
            } else if m < 60 {
                return "\(m) 分钟前"
            } else {
                let h = m / 60
                return "\(h) 小时前"
            }
        }
    }
}

extension AgentSession {
    public var formattedTime: String {
        StatusStyle.formattedTime(session: self)
    }
}

/// Fallback property wrapper for SwiftUI.State to avoid CLT compiler bug where @State attempts to resolve missing SwiftUIMacros plugin.
@propertyWrapper
public struct LocalState<Value>: DynamicProperty {
    private var state: State<Value>

    public init(wrappedValue: Value) {
        self.state = State(initialValue: wrappedValue)
    }

    public var wrappedValue: Value {
        get { state.wrappedValue }
        nonmutating set { state.wrappedValue = newValue }
    }

    public var projectedValue: Binding<Value> {
        state.projectedValue
    }
}
