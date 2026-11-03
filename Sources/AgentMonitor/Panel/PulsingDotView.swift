import SwiftUI

// Draw the pulse without an implicit animation transaction: PhaseAnimator can animate
// the dot's position while MenuBarExtra restores and lays out its window on wake.
struct PulsingDotView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
            Canvas { context, size in
                let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.8) / 1.8
                let eased = 1 - pow(1 - phase, 3)
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                if !reduceMotion {
                    let diameter = 6 + 9.6 * eased
                    let ring = CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter)
                    context.stroke(Path(ellipseIn: ring), with: .color(.blue.opacity(0.6 * (1 - eased))), lineWidth: 1.5)
                }
                context.fill(Path(ellipseIn: CGRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6)), with: .color(.blue))
            }
            .frame(width: 18, height: 18)
        }
        .frame(width: 6, height: 6)
        .transaction { $0.animation = nil }
        .accessibilityHidden(true)
    }
}
