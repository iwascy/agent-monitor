import SwiftUI

/// Thin overlay thumb that lives in the panel's side gutter, outside the rows, and only shows while scrolling or hovered.
struct CustomScrollIndicator: View {
    let metrics: ScrollMetrics
    /// Space at the bottom of the track covered by the floating button, so the thumb never slides under it
    let bottomInset: CGFloat
    let isScrolling: Bool
    let onScrollTo: (CGFloat) -> Void

    @LocalState private var isHovered = false
    @LocalState private var isDragging = false
    @LocalState private var dragStartOffset: CGFloat? = nil

    static let gutterWidth: CGFloat = 10

    var body: some View {
        let maxOffset = metrics.maxOffset
        if maxOffset > 2 {
            GeometryReader { geo in
                let verticalPadding: CGFloat = 6
                let track = max(10, geo.size.height - bottomInset - verticalPadding * 2)
                let thumbHeight = max(28, track * metrics.visibleFraction)
                let maxTravel = max(1, track - thumbHeight)
                let progress = min(1, max(0, metrics.offset / maxOffset))
                let thumbTop = verticalPadding + progress * maxTravel
                let active = isHovered || isDragging

                ZStack(alignment: .top) {
                    // Track hit area: click above/below the thumb pages the list
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { location in
                            if location.y < thumbTop {
                                onScrollTo(max(0, metrics.offset - metrics.visibleHeight * 0.8))
                            } else if location.y > thumbTop + thumbHeight {
                                onScrollTo(min(maxOffset, metrics.offset + metrics.visibleHeight * 0.8))
                            }
                        }

                    Capsule()
                        .fill(Color.primary.opacity(active ? 0.35 : 0.2))
                        .frame(width: active ? 5 : 3, height: thumbHeight)
                        .offset(y: thumbTop)
                        .animation(.snappy(duration: 0.15), value: active)
                        .allowsHitTesting(false)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            isDragging = true
                            if dragStartOffset == nil { dragStartOffset = metrics.offset }
                            let start = dragStartOffset ?? metrics.offset
                            let target = start + value.translation.height * maxOffset / maxTravel
                            onScrollTo(min(maxOffset, max(0, target)))
                        }
                        .onEnded { _ in
                            dragStartOffset = nil
                            isDragging = false
                        }
                )
            }
            .frame(width: Self.gutterWidth)
            .onHover { isHovered = $0 }
            .opacity(isScrolling || isDragging || isHovered ? 1 : 0)
            .animation(.easeOut(duration: 0.25), value: isScrolling || isDragging || isHovered)
        }
    }
}

struct ScrollMetrics: Equatable {
    var offset: CGFloat = 0
    var maxOffset: CGFloat = 0
    /// Height of the viewport the content is actually visible in (container minus insets)
    var visibleHeight: CGFloat = 0
    var visibleFraction: CGFloat = 1
}
