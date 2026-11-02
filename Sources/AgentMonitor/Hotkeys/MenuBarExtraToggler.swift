import AppKit

@MainActor
public enum MenuBarExtraToggler {
    public static func toggle() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows {
            let className = String(describing: type(of: window))
            if className.contains("NSStatusBarWindow") {
                if let button = findStatusBarButton(in: window.contentView) {
                    button.performClick(nil)
                    return
                }
            }
        }
        // Fallback: search in NSStatusBar.system
        for window in NSApp.windows {
            if let button = findStatusBarButton(in: window.contentView) {
                button.performClick(nil)
                return
            }
        }
    }

    private static func findStatusBarButton(in view: NSView?) -> NSButton? {
        guard let view = view else { return nil }
        if let button = view as? NSButton, String(describing: type(of: button)).contains("NSStatusBarButton") {
            return button
        }
        for sub in view.subviews {
            if let found = findStatusBarButton(in: sub) {
                return found
            }
        }
        return nil
    }
}
