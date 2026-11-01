import AppKit

let args = CommandLine.arguments
let outputDir: URL
if args.count > 1 {
    outputDir = URL(fileURLWithPath: args[1])
} else {
    outputDir = URL(fileURLWithPath: "AppIcon.iconset")
}

let fm = FileManager.default
try fm.createDirectory(at: outputDir, withIntermediateDirectories: true)

let masterSize = NSSize(width: 1024, height: 1024)
let masterImage = NSImage(size: masterSize, flipped: true) { _ in
    guard let ctx = NSGraphicsContext.current?.cgContext else { return false }

    // macOS icon content rect: 824x824, corner radius: 185
    let contentRect = CGRect(x: 100, y: 100, width: 824, height: 824)
    let contentPath = CGPath(roundedRect: contentRect, cornerWidth: 185, cornerHeight: 185, transform: nil)

    ctx.saveGState()
    ctx.addPath(contentPath)
    ctx.setFillColor(NSColor(srgbRed: 0x1D / 255.0, green: 0x1D / 255.0, blue: 0x1F / 255.0, alpha: 1.0).cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // Inner icon: 16x16 vector filling 22/38 of the tile, the proportion of the original notification-tile design.
    // In 824 tile, width = 824 * (22/38) = 477.0526 pt.
    let iconBoxSize: CGFloat = 824.0 * (22.0 / 38.0)
    let scale = iconBoxSize / 16.0
    let originX = 100.0 + (824.0 - iconBoxSize) / 2.0
    let originY = 100.0 + (824.0 - iconBoxSize) / 2.0

    ctx.saveGState()
    ctx.translateBy(x: originX, y: originY)
    ctx.scaleBy(x: scale, y: scale)

    // Outline rect: x=1.5, y=3.2, w=11, h=10, rx=2.6, stroke-width=1.3, stroke=#FFFFFF
    let boxRect = CGRect(x: 1.5, y: 3.2, width: 11.0, height: 10.0)
    let boxPath = CGPath(roundedRect: boxRect, cornerWidth: 2.6, cornerHeight: 2.6, transform: nil)
    ctx.setLineWidth(1.3)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.setStrokeColor(NSColor.white.cgColor)
    ctx.addPath(boxPath)
    ctx.strokePath()

    // Two horizontal lines:
    // Line 1: (4.4, 7.1) -> (9.4, 7.1)
    ctx.move(to: CGPoint(x: 4.4, y: 7.1))
    ctx.addLine(to: CGPoint(x: 9.4, y: 7.1))
    // Line 2: (4.4, 9.9) -> (7.4, 9.9)
    ctx.move(to: CGPoint(x: 4.4, y: 9.9))
    ctx.addLine(to: CGPoint(x: 7.4, y: 9.9))
    ctx.strokePath()

    // Status dot circle: cx=12.9, cy=3.6, r=2.5, fill=#F0841C
    let dotRect = CGRect(x: 12.9 - 2.5, y: 3.6 - 2.5, width: 5.0, height: 5.0)
    ctx.setFillColor(NSColor(srgbRed: 0xF0 / 255.0, green: 0x84 / 255.0, blue: 0x1C / 255.0, alpha: 1.0).cgColor)
    ctx.fillEllipse(in: dotRect)

    ctx.restoreGState()

    return true
}

let iconSizes: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for (name, px) in iconSizes {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: px,
        pixelsHigh: px,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = NSSize(width: px, height: px)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    masterImage.draw(
        in: NSRect(x: 0, y: 0, width: px, height: px),
        from: NSRect(x: 0, y: 0, width: 1024, height: 1024),
        operation: .copy,
        fraction: 1.0
    )
    NSGraphicsContext.restoreGraphicsState()

    if let pngData = rep.representation(using: .png, properties: [:]) {
        let dest = outputDir.appendingPathComponent(name)
        try pngData.write(to: dest)
    }
}
print("Successfully generated iconset at \(outputDir.path)")
