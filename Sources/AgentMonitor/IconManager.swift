import AppKit
import AgentMonitorCore

@MainActor
public final class IconManager {
    public static let shared = IconManager()

    private struct CacheKey: Hashable {
        let kind: AgentKind
        let isDark: Bool
    }
    private var cache: [CacheKey: NSImage] = [:]

    private init() {}

    public func icon(for kind: AgentKind, isDark: Bool = false) -> NSImage {
        let key = CacheKey(kind: kind, isDark: isDark)
        if let cached = cache[key] {
            return cached
        }
        let image = loadIcon(for: kind, isDark: isDark)
        cache[key] = image
        return image
    }

    public func cachedIconPNGURL(for kind: AgentKind) -> URL? {
        let fm = FileManager.default
        let cachesDir = fm.urls(for: .cachesDirectory, in: .userDomainMask).first ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches")
        let appCachesDir = cachesDir.appendingPathComponent("com.cy.agentmonitor/icons")
        if !fm.fileExists(atPath: appCachesDir.path) {
            try? fm.createDirectory(at: appCachesDir, withIntermediateDirectories: true)
        }

        let fileURL = appCachesDir.appendingPathComponent("\(kind.rawValue).png")
        if fm.fileExists(atPath: fileURL.path) {
            return fileURL
        }

        let img = icon(for: kind, isDark: false)
        let pixelSize: CGFloat = 256
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(pixelSize),
            pixelsHigh: Int(pixelSize),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }

        rep.size = NSSize(width: pixelSize, height: pixelSize)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        img.draw(
            in: NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize),
            from: NSRect(origin: .zero, size: img.size),
            operation: .copy,
            fraction: 1.0
        )
        NSGraphicsContext.restoreGraphicsState()

        guard let pngData = rep.representation(using: .png, properties: [:]) else { return nil }
        do {
            try pngData.write(to: fileURL)
            return fileURL
        } catch {
            return nil
        }
    }

    private func loadIcon(for kind: AgentKind, isDark: Bool) -> NSImage {
        let ws = NSWorkspace.shared

        switch kind {
        case .claudeCode:
            if let appURL = ws.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop") ?? URL(string: "file:///Applications/Claude.app"),
               FileManager.default.fileExists(atPath: appURL.path) {
                return ws.icon(forFile: appURL.path)
            }

        case .codex:
            let resourceDir = URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources")
            let preferredName = isDark ? "icon-codex-dark-color.png" : "icon-codex-light.png"
            let preferredURL = resourceDir.appendingPathComponent(preferredName)
            if let img = NSImage(contentsOf: preferredURL) {
                return img
            }
            let fallbackName = isDark ? "icon-codex-light.png" : "icon-codex-dark-color.png"
            let fallbackURL = resourceDir.appendingPathComponent(fallbackName)
            if let img = NSImage(contentsOf: fallbackURL) {
                return img
            }
            if let appURL = ws.urlForApplication(withBundleIdentifier: "com.openai.codex") ?? ws.urlForApplication(withBundleIdentifier: "com.openai.chat") ?? URL(string: "file:///Applications/ChatGPT.app"),
               FileManager.default.fileExists(atPath: appURL.path) {
                return ws.icon(forFile: appURL.path)
            }

        case .antigravity:
            if let appURL = ws.urlForApplication(withBundleIdentifier: "com.google.antigravity") ?? URL(string: "file:///Applications/Antigravity.app"),
               FileManager.default.fileExists(atPath: appURL.path) {
                return ws.icon(forFile: appURL.path)
            }

        case .dsh:
            if let dshIcon = loadDshIcon() {
                return dshIcon
            }
        }

        return fallbackBadge(for: kind)
    }

    private func loadDshIcon() -> NSImage? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let binPath = home.appendingPathComponent(".local/bin/dsh").path

        var dshDir: URL? = nil
        if let target = try? fm.destinationOfSymbolicLink(atPath: binPath) {
            let fullPath = URL(fileURLWithPath: binPath).deletingLastPathComponent().appendingPathComponent(target).standardized
            dshDir = fullPath.deletingLastPathComponent().deletingLastPathComponent()
        }
        if dshDir == nil {
            dshDir = home.appendingPathComponent(".local/lib/node_modules/@deepseek-ai/dsh")
        }

        guard let root = dshDir else { return nil }
        let svgURL = root.appendingPathComponent("node_modules/@deepseek-ai/dsh-web-frontend/dist/favicon.svg")
        guard fm.fileExists(atPath: svgURL.path),
              let svgData = try? Data(contentsOf: svgURL) else {
            return nil
        }

        // Render dsh logo on white rounded tile
        let size = NSSize(width: 64, height: 64)
        let image = NSImage(size: size)
        image.lockFocus()

        let bounds = NSRect(origin: .zero, size: size)
        let cornerRadius: CGFloat = 14.0
        let bgPath = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: cornerRadius, yRadius: cornerRadius)
        NSColor.white.setFill()
        bgPath.fill()
        NSColor(white: 0.85, alpha: 1.0).setStroke()
        bgPath.lineWidth = 1.0
        bgPath.stroke()

        if var svgString = String(data: svgData, encoding: .utf8) {
            svgString = svgString.replacingOccurrences(of: "currentColor", with: "#4D6BFE")
            if let modifiedData = svgString.data(using: .utf8),
               let svgImage = NSImage(data: modifiedData) {
                let iconRect = bounds.insetBy(dx: 8, dy: 8)
                svgImage.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1.0)
            }
        }

        image.unlockFocus()
        return image
    }

    private func fallbackBadge(for kind: AgentKind) -> NSImage {
        let size = NSSize(width: 64, height: 64)
        let image = NSImage(size: size)
        image.lockFocus()

        let bounds = NSRect(origin: .zero, size: size)
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 14, yRadius: 14)

        let bgColor: NSColor
        switch kind {
        case .claudeCode:
            bgColor = NSColor(red: 0.85, green: 0.44, blue: 0.28, alpha: 1.0) // Claude terra cotta
        case .codex:
            bgColor = NSColor(red: 0.06, green: 0.65, blue: 0.52, alpha: 1.0) // OpenAI green
        case .dsh:
            bgColor = NSColor(red: 0.30, green: 0.42, blue: 1.00, alpha: 1.0) // DeepSeek blue
        case .antigravity:
            bgColor = NSColor(red: 0.26, green: 0.52, blue: 0.96, alpha: 1.0) // Google blue
        }

        bgColor.setFill()
        path.fill()

        let text = kind.shortCode as NSString
        let font = NSFont.systemFont(ofSize: 24, weight: .bold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]
        let textSize = text.size(withAttributes: attributes)
        let textRect = NSRect(
            x: (size.width - textSize.width) / 2,
            y: (size.height - textSize.height) / 2,
            width: textSize.width,
            height: textSize.height
        )
        text.draw(in: textRect, withAttributes: attributes)

        image.unlockFocus()
        return image
    }
}
