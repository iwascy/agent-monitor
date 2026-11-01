// Captures accessibility panel screenshots (reduce transparency & increase contrast) into docs/screenshots/a11y/.
//
// Toggles each accessibility setting on, takes the screenshot, then puts the setting back to the value it had
// before the run. Aborts without capturing if a checkbox can't be found, so it never reports a fake restore.

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

func launchApp(env: [String: String]) -> Process {
    killAgentMonitor()
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/Users/cy/code/agent-monitor/build/AgentMonitor.app/Contents/MacOS/AgentMonitor")
    var processEnv = ProcessInfo.processInfo.environment
    for (k, v) in env {
        processEnv[k] = v
    }
    task.environment = processEnv
    try! task.run()
    Thread.sleep(forTimeInterval: 1.5)
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
    Thread.sleep(forTimeInterval: 0.8)
}

func openAccessibilityDisplay() {
    _ = runBash("open 'x-apple.systempreferences:com.apple.preference.universalaccess?Seeing_Display'")
    Thread.sleep(forTimeInterval: 1.2)
}

func closeSystemSettings() {
    _ = runBash("osascript -e 'tell application \"System Settings\" to quit'")
    Thread.sleep(forTimeInterval: 0.5)
}

func getCheckboxValue(name: String) -> Int {
    let script = """
    tell application "System Events"
        tell process "System Settings"
            set cb to checkbox "\(name)" of group 1 of scroll area 1 of group 1 of group 3 of splitter group 1 of group 1 of window 1
            return value of cb as integer
        end tell
    end tell
    """
    let res = runBash("osascript -e '\(script)' 2>/dev/null || echo '-1'")
    return Int(res) ?? -1
}

func setCheckbox(name: String, target: Bool) {
    let targetVal = target ? 1 : 0
    let currentVal = getCheckboxValue(name: name)
    if currentVal != targetVal && currentVal != -1 {
        let script = """
        tell application "System Events"
            tell process "System Settings"
                set cb to checkbox "\(name)" of group 1 of scroll area 1 of group 1 of group 3 of splitter group 1 of group 1 of window 1
                click cb
            end tell
        end tell
        """
        _ = runBash("osascript -e '\(script)'")
        Thread.sleep(forTimeInterval: 0.8)
    }
}

let fm = FileManager.default
let destDir = "/Users/cy/code/agent-monitor/docs/screenshots/a11y"
try? fm.createDirectory(atPath: destDir, withIntermediateDirectories: true)

print("==> Starting accessibility screenshot captures...")

let originalDarkMode = isDarkModeEnabled()
let wasAgentMonitorRunning = !runBash("pgrep -x AgentMonitor || true").isEmpty

// Ensure light mode for accessibility screenshots per specification
setDarkMode(false)
openAccessibilityDisplay()

// The checkbox labels follow the system language; try each known spelling
let reduceTransparencyNames = ["降低透明度", "減少透明度", "減低透明度", "Reduce transparency"]
let increaseContrastNames = ["增强对比度", "增加對比", "增加對比度", "Increase contrast"]

func resolveCheckbox(_ candidates: [String]) -> (name: String, value: Int)? {
    for name in candidates {
        let value = getCheckboxValue(name: name)
        if value == 0 || value == 1 { return (name, value) }
    }
    return nil
}

guard let reduceTrans = resolveCheckbox(reduceTransparencyNames),
      let contrast = resolveCheckbox(increaseContrastNames) else {
    print("Error: could not find the accessibility checkboxes in System Settings; nothing was changed.")
    closeSystemSettings()
    setDarkMode(originalDarkMode)
    exit(1)
}
print("Initial settings: \(reduceTrans.name)=\(reduceTrans.value), \(contrast.name)=\(contrast.value)")

func capturePanel(outPath: String) {
    let proc = launchApp(env: [
        "AGENT_MONITOR_MOCK_DATA": "1",
        "AGENT_MONITOR_COLOR_SCHEME": "light"
    ])
    if let rect = getStatusItemRect(pid: proc.processIdentifier) {
        let clickPt = CGPoint(x: rect.midX, y: rect.midY)
        clickAt(point: clickPt)

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
            let captureX = Int(b.origin.x - 10)
            let captureY = Int(b.origin.y - 4)
            let captureW = Int(b.size.width + 20)
            let captureH = Int(b.size.height + 20)
            _ = runBash("screencapture -R \(captureX),\(captureY),\(captureW),\(captureH) '\(outPath)'")
            print("Captured: \(outPath)")
        } else {
            print("Failed to find panel window bounds for \(outPath)")
        }
    }
    proc.terminate()
    killAgentMonitor()
}

// Start from both settings off so each capture shows only one effect
setCheckbox(name: reduceTrans.name, target: false)
setCheckbox(name: contrast.name, target: false)

// 1. Capture Reduce Transparency
setCheckbox(name: reduceTrans.name, target: true)
capturePanel(outPath: "\(destDir)/panel-reduce-transparency.png")
setCheckbox(name: reduceTrans.name, target: false)

// 2. Capture Increase Contrast
setCheckbox(name: contrast.name, target: true)
capturePanel(outPath: "\(destDir)/panel-increase-contrast.png")
setCheckbox(name: contrast.name, target: false)

// Put both settings back to what the user had before the run
setCheckbox(name: reduceTrans.name, target: reduceTrans.value == 1)
setCheckbox(name: contrast.name, target: contrast.value == 1)

let finalReduceTrans = getCheckboxValue(name: reduceTrans.name)
let finalContrast = getCheckboxValue(name: contrast.name)
let restored = finalReduceTrans == reduceTrans.value && finalContrast == contrast.value
print("Final settings: \(reduceTrans.name)=\(finalReduceTrans), \(contrast.name)=\(finalContrast) (expected \(reduceTrans.value), \(contrast.value))")

closeSystemSettings()
setDarkMode(originalDarkMode)

if wasAgentMonitorRunning {
    _ = runBash("open /Users/cy/code/agent-monitor/build/AgentMonitor.app")
}

if !restored {
    print("Warning: accessibility settings differ from their original values; check System Settings › Accessibility › Display.")
    exit(1)
}
print("==> Accessibility captures completed and settings restored.")
