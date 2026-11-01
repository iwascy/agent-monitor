import SwiftUI

// MARK: - Pulsing Dot View (1.8s pulse ring animation)
struct PulsingDotView: View {
    var body: some View {
        PhaseAnimator([false, true]) { isPulsing in
            ZStack {
                Circle()
                    .stroke(Color.blue.opacity(isPulsing ? 0 : 0.6), lineWidth: 1.5)
                    .frame(width: 6, height: 6)
                    .scaleEffect(isPulsing ? 2.6 : 1.0)
                Circle()
                    .fill(Color.blue)
                    .frame(width: 6, height: 6)
            }
        } animation: { _ in
            .easeOut(duration: 1.8)
        }
    }
}
