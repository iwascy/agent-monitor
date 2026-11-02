import AppKit

public struct MenuBarIconRenderer {
    public static func size(
        highestState: SessionState?,
        waitingCount: Int,
        isPaused: Bool,
        isOverdue: Bool = false
    ) -> NSSize {
        var width: CGFloat = 16.0
        if waitingCount > 0 {
            let font = NSFont.systemFont(ofSize: 10.5, weight: .bold)
            let text = "\(waitingCount)" as NSString
            let textSize = text.size(withAttributes: [.font: font])
            let badgeWidth = max(16.0, ceil(textSize.width) + 8.0)
            width += 5.0 + badgeWidth
        }
        if isPaused {
            width += 5.0 + 13.0
        }
        return NSSize(width: width, height: 16.0)
    }

    public static func isTemplate(
        highestState: SessionState?,
        waitingCount: Int
    ) -> Bool {
        let hasColor = (dotColor(for: highestState) != nil || waitingCount > 0)
        return !hasColor
    }

    public static func dotColor(for state: SessionState?) -> NSColor? {
        guard let state = state else { return nil }
        switch state {
        case .waitingForUser:
            return .systemOrange
        case .completed:
            return .systemGreen
        case .running:
            return .systemBlue
        case .idle:
            return nil
        }
    }

    public static func image(
        highestState: SessionState?,
        waitingCount: Int,
        isPaused: Bool,
        isOverdue: Bool = false
    ) -> NSImage {
        let iconSize = size(highestState: highestState, waitingCount: waitingCount, isPaused: isPaused, isOverdue: isOverdue)
        let template = isTemplate(highestState: highestState, waitingCount: waitingCount)
        let dot = dotColor(for: highestState)

        let image = NSImage(size: iconSize, flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }

            let strokeColor: NSColor = template ? .black : .labelColor

            // 1. Draw 16pt main icon
            ctx.saveGState()
            ctx.setLineWidth(1.5)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.setStrokeColor(strokeColor.cgColor)

            // Rounded rectangle: x=1.5, y=3.2, w=11, h=10, rx=2.6
            let boxRect = CGRect(x: 1.5, y: 3.2, width: 11.0, height: 10.0)
            let boxPath = CGPath(roundedRect: boxRect, cornerWidth: 2.6, cornerHeight: 2.6, transform: nil)
            ctx.addPath(boxPath)
            ctx.strokePath()

            // Horizontal lines:
            // Line 1: (4.4, 7.1) -> (9.4, 7.1)
            ctx.move(to: CGPoint(x: 4.4, y: 7.1))
            ctx.addLine(to: CGPoint(x: 9.4, y: 7.1))
            // Line 2: (4.4, 9.9) -> (7.4, 9.9)
            ctx.move(to: CGPoint(x: 4.4, y: 9.9))
            ctx.addLine(to: CGPoint(x: 7.4, y: 9.9))
            ctx.strokePath()

            // Status dot: cx=12.9, cy=3.6, r=2.7, with 1pt transparent cutout
            if let dot = dot {
                ctx.saveGState()
                ctx.setBlendMode(.clear)
                let cutoutRect = CGRect(x: 12.9 - (2.7 + 1.0), y: 3.6 - (2.7 + 1.0), width: (2.7 + 1.0) * 2.0, height: (2.7 + 1.0) * 2.0)
                ctx.fillEllipse(in: cutoutRect)
                ctx.restoreGState()

                let dotRect = CGRect(x: 12.9 - 2.7, y: 3.6 - 2.7, width: 5.4, height: 5.4)
                ctx.setFillColor(dot.cgColor)
                ctx.fillEllipse(in: dotRect)
            }
            ctx.restoreGState()

            var currentX: CGFloat = 16.0

            // 2. Draw Badge (if waitingCount > 0)
            if waitingCount > 0 {
                currentX += 5.0
                let font = NSFont.systemFont(ofSize: 10.5, weight: .bold)
                let text = "\(waitingCount)" as NSString
                let textSize = text.size(withAttributes: [.font: font])
                let badgeWidth = max(16.0, ceil(textSize.width) + 8.0)
                let badgeRect = CGRect(x: currentX, y: (16.0 - 15.0) / 2.0, width: badgeWidth, height: 15.0)

                ctx.saveGState()
                let badgeColor: NSColor
                if isOverdue {
                    badgeColor = NSColor(srgbRed: 0xD7 / 255.0, green: 0, blue: 0x15 / 255.0, alpha: 1.0)
                } else {
                    let srgbOrange = NSColor.systemOrange.usingColorSpace(.sRGB) ?? NSColor.systemOrange
                    badgeColor = NSColor(
                        srgbRed: srgbOrange.redComponent * 0.65,
                        green: srgbOrange.greenComponent * 0.65,
                        blue: srgbOrange.blueComponent * 0.65,
                        alpha: 1.0
                    )
                }
                ctx.setFillColor(badgeColor.cgColor)
                let badgePath = CGPath(roundedRect: badgeRect, cornerWidth: 7.5, cornerHeight: 7.5, transform: nil)
                ctx.addPath(badgePath)
                ctx.fillPath()

                let textAttrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: NSColor.white
                ]
                let textRect = CGRect(
                    x: badgeRect.origin.x + (badgeWidth - textSize.width) / 2.0,
                    y: badgeRect.origin.y + (15.0 - textSize.height) / 2.0,
                    width: textSize.width,
                    height: textSize.height
                )
                text.draw(in: textRect, withAttributes: textAttrs)
                ctx.restoreGState()

                currentX += badgeWidth
            }

            // 3. Draw Slashed Bell (if isPaused)
            if isPaused {
                currentX += 5.0
                let bellY: CGFloat = (16.0 - 13.0) / 2.0

                ctx.saveGState()
                ctx.translateBy(x: currentX, y: bellY)
                let scale: CGFloat = 13.0 / 16.0
                ctx.scaleBy(x: scale, y: scale)

                ctx.setLineWidth(1.5)
                ctx.setLineCap(.round)
                ctx.setLineJoin(.round)
                ctx.setStrokeColor(strokeColor.cgColor)

                let bellPath = CGMutablePath()
                bellPath.move(to: CGPoint(x: 5.0, y: 4.2))
                bellPath.addArc(
                    center: CGPoint(x: 8.00465, y: 6.18294),
                    radius: 3.6,
                    startAngle: -146.577 * .pi / 180,
                    endAngle: -2.913 * .pi / 180,
                    clockwise: false
                )
                bellPath.addLine(to: CGPoint(x: 11.6, y: 8.4))
                bellPath.addLine(to: CGPoint(x: 12.9, y: 10.6))
                bellPath.addLine(to: CGPoint(x: 6.5, y: 10.6))

                bellPath.move(to: CGPoint(x: 4.4, y: 6.6))
                bellPath.addLine(to: CGPoint(x: 4.4, y: 8.4))
                bellPath.addLine(to: CGPoint(x: 3.1, y: 10.6))

                ctx.addPath(bellPath)
                ctx.strokePath()

                // Slash line from (2.5, 2.5) to (13.5, 13.5)
                ctx.move(to: CGPoint(x: 2.5, y: 2.5))
                ctx.addLine(to: CGPoint(x: 13.5, y: 13.5))
                ctx.strokePath()

                ctx.restoreGState()
                currentX += 13.0
            }

            return true
        }

        image.isTemplate = template
        return image
    }
}
