import SwiftUI
import AppKit
import AgentMonitorCore

public struct MenuBarLabelView: View {
    @ObservedObject var viewModel: MonitorViewModel

    public init(viewModel: MonitorViewModel) {
        self.viewModel = viewModel
    }

    private var highestState: SessionState? {
        let active = viewModel.sessions
        if active.contains(where: { $0.state == .waitingForUser }) {
            return .waitingForUser
        }
        if active.contains(where: { $0.state == .completed }) {
            return .completed
        }
        if active.contains(where: { $0.state == .running }) {
            return .running
        }
        return nil
    }

    private var waitingCount: Int {
        viewModel.sessions.filter { $0.state == .waitingForUser }.count
    }

    private var dotColor: Color? {
        guard let state = highestState else { return nil }
        switch state {
        case .waitingForUser:
            return Color(red: 0.94, green: 0.52, blue: 0.11) // #F0841C
        case .completed:
            return Color(red: 0.20, green: 0.78, blue: 0.35) // #34C759
        case .running:
            return Color(red: 0.04, green: 0.52, blue: 1.0)  // #0A84FF
        case .idle:
            return nil
        }
    }

    public var body: some View {
        HStack(spacing: 4) {
            // Self-drawn 16pt template icon
            ZStack {
                // Outline rect and inner lines
                AgentMonitorIconShape()
                    .stroke(Color.primary, lineWidth: 1.3)
                    .frame(width: 16, height: 16)

                // Top-right status dot
                if let color = dotColor {
                    Circle()
                        .fill(color)
                        .frame(width: 4.8, height: 4.8)
                        .offset(x: 5.2, y: -4.8)
                }
            }
            .frame(width: 16, height: 16)

            // Waiting badge: #C2410C background, white text, 10.5pt bold, capsule shape, height 15pt
            if waitingCount > 0 {
                Text("\(waitingCount)")
                    .font(.system(size: 10.5, weight: .bold))
                    .monospacedDigit()
                    .foregroundColor(.white)
                    .padding(.horizontal, 4.5)
                    .frame(minWidth: 16)
                    .frame(height: 15)
                    .background(Color(red: 0.76, green: 0.25, blue: 0.05)) // #C2410C
                    .clipShape(Capsule())
            }

            // Slashed bell when notifications are paused
            if viewModel.isNotificationsPaused {
                Image(systemName: "bell.slash")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.primary)
            }
        }
    }
}

struct AgentMonitorIconShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()

        // Rounded rect: x=1.5, y=3.2, w=11, h=10, rx=2.6
        let boxRect = CGRect(x: 1.5, y: 3.2, width: 11, height: 10)
        path.addRoundedRect(in: boxRect, cornerSize: CGSize(width: 2.6, height: 2.6))

        // Two horizontal lines: (4.4, 7.1) -> (9.4, 7.1), (4.4, 9.9) -> (7.4, 9.9)
        path.move(to: CGPoint(x: 4.4, y: 7.1))
        path.addLine(to: CGPoint(x: 9.4, y: 7.1))

        path.move(to: CGPoint(x: 4.4, y: 9.9))
        path.addLine(to: CGPoint(x: 7.4, y: 9.9))

        return path
    }
}
