// Captures menu bar, panel and notification screenshots into docs/screenshots/.
//
// Side effects while it runs (both are undone at the end):
// - temporarily switches the system light/dark appearance, then restores the original setting;
// - quits a running AgentMonitor, then relaunches build/AgentMonitor.app if it was running before.
//
// Note: on this macOS the menu bar follows the wallpaper, not the light/dark setting, so the
// "light" and "dark" menu bar captures can look identical. Glyph colour per appearance is covered
// by the MenuBarIconRenderer unit test instead.

import AppKit
import CoreGraphics
import Foundation

func runBash(_ cmd: String) -> String {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/bash")
    task.arguments = ["-c", cmd]
    let pipe = Pipe()
    task.standardOutput = pipe
    try? task.run()
    task.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

func setDarkMode(_ dark: Bool) {
    _ = runBash("osascript -e 'tell application \"System Events\" to tell appearance preferences to set dark mode to \(dark)'")
    Thread.sleep(forTimeInterval: 0.8)
}

func isDarkModeEnabled() -> Bool {
    runBash("osascript -e 'tell application \"System Events\" to tell appearance preferences to get dark mode'") == "true"
}

func killAgentMonitor() {
    _ = runBash("pkill -9 -x AgentMonitor || true")
    Thread.sleep(forTimeInterval: 0.5)
}

let projectRoot = FileManager.default.currentDirectoryPath

func launchApp(env: [String: String]) -> Process {
    killAgentMonitor()
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "\(projectRoot)/build/AgentMonitor.app/Contents/MacOS/AgentMonitor")
    var processEnv = ProcessInfo.processInfo.environment
    for (k, v) in env {
        processEnv[k] = v
    }
    task.environment = processEnv
    try! task.run()
    Thread.sleep(forTimeInterval: 1.2)
    return task
}

func getStatusItemRect(pid: pid_t) -> CGRect? {
    let app = AXUIElementCreateApplication(pid)
    var barVal: AnyObject?
    guard AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar" as CFString, &barVal) == .success,
          let bar = barVal else { return nil }

    var childrenVal: AnyObject?
    guard AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &childrenVal) == .success,
          let children = childrenVal as? [AXUIElement],
          let child = children.first else { return nil }

    var posVal: AnyObject?
    var sizeVal: AnyObject?
    AXUIElementCopyAttributeValue(child, kAXPositionAttribute as CFString, &posVal)
    AXUIElementCopyAttributeValue(child, kAXSizeAttribute as CFString, &sizeVal)

    var pos = CGPoint.zero
    var size = CGSize.zero
    if let pv = posVal { AXValueGetValue(pv as! AXValue, .cgPoint, &pos) }
    if let sv = sizeVal { AXValueGetValue(sv as! AXValue, .cgSize, &size) }
    return CGRect(origin: pos, size: size)
}

func clickAt(point: CGPoint) {
    let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
    let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
    down?.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.1)
    up?.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.5)
}

let fm = FileManager.default
let destDir = "\(projectRoot)/docs/screenshots"
try? fm.createDirectory(atPath: destDir, withIntermediateDirectories: true)

print("==> Starting automated screenshot captures...")

let originalDarkMode = isDarkModeEnabled()
let wasAgentMonitorRunning = !runBash("pgrep -x AgentMonitor || true").isEmpty

let menuStates = [
    ("idle", "idle"),
    ("running", "running"),
    ("completed", "completed"),
    ("waiting", "waiting"),
    ("paused", "paused")
]

for isDark in [false, true] {
    let modeName = isDark ? "dark" : "light"
    print("==> Switching to \(modeName) mode...")
    setDarkMode(isDark)

    // 1. Menu bar icon states
    for (stateName, stateEnv) in menuStates {
        let env = [
            "AGENT_MONITOR_MENU_STATE": stateEnv,
            "AGENT_MONITOR_COLOR_SCHEME": modeName
        ]
        let proc = launchApp(env: env)
        if let rect = getStatusItemRect(pid: proc.processIdentifier) {
            let captureX = Int(max(0, rect.origin.x - 6))
            let captureY = 0
            let captureW = Int(rect.size.width + 12)
            let captureH = 28
            let outPath = "\(destDir)/menubar-\(stateName)-\(modeName).png"
            _ = runBash("screencapture -R \(captureX),\(captureY),\(captureW),\(captureH) '\(outPath)'")
            print("Captured: menubar-\(stateName)-\(modeName).png")
        } else {
            print("Failed to find status item for \(stateName) in \(modeName)")
        }
        proc.terminate()
        killAgentMonitor()
    }

    // 2. Panel screenshots
    let panelConfigs: [(name: String, env: [String: String])] = [
        ("panel", [
            "AGENT_MONITOR_MOCK_DATA": "1"
        ]),
        ("panel-waiting", [
            "AGENT_MONITOR_MOCK_DATA": "1",
            "AGENT_MONITOR_FILTER": "waiting"
        ]),
        ("panel-idle-expanded", [
            "AGENT_MONITOR_MOCK_DATA": "1",
            "AGENT_MONITOR_IDLE_EXPANDED": "1"
        ]),
        ("panel-large", [
            "AGENT_MONITOR_MOCK_DATA": "large",
            "AGENT_MONITOR_IDLE_EXPANDED": "1"
        ]),
        ("panel-empty", [
            "AGENT_MONITOR_MOCK_DATA": "empty"
        ])
    ]

    for config in panelConfigs {
        var env = config.env
        env["AGENT_MONITOR_COLOR_SCHEME"] = modeName

        let proc = launchApp(env: env)
        if let rect = getStatusItemRect(pid: proc.processIdentifier) {
            let clickPt = CGPoint(x: rect.midX, y: rect.midY)
            clickAt(point: clickPt)
            Thread.sleep(forTimeInterval: 0.8)

            // Find the window
            var panelBounds: CGRect? = nil
            let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
            for w in list {
                let pid = w[kCGWindowOwnerPID as String] as? Int32 ?? 0
                if pid == proc.processIdentifier {
                    if let dict = w[kCGWindowBounds as String] as? [String: Any],
                       let x = dict["X"] as? Double,
                       let y = dict["Y"] as? Double,
                       let w = dict["Width"] as? Double,
                       let h = dict["Height"] as? Double {
                        panelBounds = CGRect(x: x, y: y, width: w, height: h)
                        break
                    }
                }
            }

            if let b = panelBounds {
                let outPath = "\(destDir)/\(config.name)-\(modeName).png"
                let captureX = Int(b.origin.x - 10)
                let captureY = Int(b.origin.y - 4)
                let captureW = Int(b.size.width + 20)
                let captureH = Int(b.size.height + 20)
                _ = runBash("screencapture -R \(captureX),\(captureY),\(captureW),\(captureH) '\(outPath)'")
                print("Captured: \(config.name)-\(modeName).png")
            } else {
                print("Failed to find panel window bounds for \(config.name)-\(modeName)")
            }
        }
        proc.terminate()
        killAgentMonitor()
    }

    // Settings pages capture (P2 requirement: 6 pages, light and dark modes)
    let settingsPages = ["general", "notification", "agents", "mute", "integration", "hotkey"]
    for page in settingsPages {
        var env: [String: String] = [
            "AGENT_MONITOR_OPEN_SETTINGS": "1",
            "AGENT_MONITOR_SETTINGS_TAB": page,
            "AGENT_MONITOR_COLOR_SCHEME": modeName
        ]
        let proc = launchApp(env: env)
        if let rect = getStatusItemRect(pid: proc.processIdentifier) {
            let clickPt = CGPoint(x: rect.midX, y: rect.midY)
            clickAt(point: clickPt)
            Thread.sleep(forTimeInterval: 1.0)

            var settingsBounds: CGRect? = nil
            let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
            for w in list {
                let pid = w[kCGWindowOwnerPID as String] as? Int32 ?? 0
                if pid == proc.processIdentifier {
                    if let dict = w[kCGWindowBounds as String] as? [String: Any],
                       let x = dict["X"] as? Double,
                       let y = dict["Y"] as? Double,
                       let width = dict["Width"] as? Double,
                       let height = dict["Height"] as? Double,
                       width >= 500 { // Settings window width is 600
                        settingsBounds = CGRect(x: x, y: y, width: width, height: height)
                        break
                    }
                }
            }

            if let b = settingsBounds {
                let outPath = "\(destDir)/settings-\(page)-\(modeName).png"
                let captureX = Int(b.origin.x - 10)
                let captureY = Int(b.origin.y - 4)
                let captureW = Int(b.size.width + 20)
                let captureH = Int(b.size.height + 20)
                _ = runBash("screencapture -R \(captureX),\(captureY),\(captureW),\(captureH) '\(outPath)'")
                print("Captured: settings-\(page)-\(modeName).png")
            } else {
                print("Failed to find settings window bounds for \(page)-\(modeName)")
            }
        }
        proc.terminate()
        killAgentMonitor()
    }
}

// Restore the user's original appearance and running app
setDarkMode(originalDarkMode)
if wasAgentMonitorRunning {
    _ = runBash("open '\(projectRoot)/build/AgentMonitor.app'")
}
print("==> All menu bar and panel captures completed.")
