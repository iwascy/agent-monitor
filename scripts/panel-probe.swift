// Drives the panel through the accessibility (AX) tree and reports what it looks like after each step.
//
// Usage:
//   swift scripts/panel-probe.swift [options] [label ...]
//
// Each label presses the first button whose AX description ends with it (e.g. "运行中", "全部标为已读",
// "空闲 · 2 个会话"), then prints the panel window size. Pass no labels to only open the panel.
//
// Options:
//   --mock <1|large|empty>   AGENT_MONITOR_MOCK_DATA (default 1); "real" uses live sessions
//   --filter <state>         AGENT_MONITOR_FILTER at launch
//   --idle-expanded          AGENT_MONITOR_IDLE_EXPANDED=1
//   --scheme <light|dark>    AGENT_MONITOR_COLOR_SCHEME (default light)
//   --tree                   print the AX tree after each step
//   --shots <dir>            save a screenshot after each step as <dir>/step-<n>.png
//
// Side effects: quits a running AgentMonitor and relaunches build/AgentMonitor.app afterwards if it was running.
// Needs Accessibility (and Screen Recording for --shots) permission for the terminal running it.

import AppKit
import ApplicationServices
import Foundation

let appBinary = "/Users/cy/code/agent-monitor/build/AgentMonitor.app/Contents/MacOS/AgentMonitor"

func runBash(_ cmd: String) -> String {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/bash")
    task.arguments = ["-c", cmd]
    let pipe = Pipe()
    task.standardOutput = pipe
    try? task.run()
    task.waitUntilExit()
    return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(e, name as CFString, &value) == .success ? value : nil
}

func children(_ e: AXUIElement) -> [AXUIElement] {
    attr(e, kAXChildrenAttribute) as? [AXUIElement] ?? []
}

func label(_ e: AXUIElement) -> String {
    for key in [kAXDescriptionAttribute, kAXTitleAttribute, kAXValueAttribute] {
        if let s = attr(e, key) as? String, !s.isEmpty { return s }
    }
    return ""
}

func frame(_ e: AXUIElement) -> CGRect {
    var pos = CGPoint.zero
    var size = CGSize.zero
    if let v = attr(e, kAXPositionAttribute) { AXValueGetValue(v as! AXValue, .cgPoint, &pos) }
    if let v = attr(e, kAXSizeAttribute) { AXValueGetValue(v as! AXValue, .cgSize, &size) }
    return CGRect(origin: pos, size: size)
}

func find(_ e: AXUIElement, where match: (AXUIElement) -> Bool) -> AXUIElement? {
    if match(e) { return e }
    for c in children(e) {
        if let hit = find(c, where: match) { return hit }
    }
    return nil
}

func dumpTree(_ e: AXUIElement, depth: Int = 0) {
    let role = attr(e, kAXRoleAttribute) as? String ?? "?"
    let f = frame(e)
    print(String(repeating: "  ", count: depth + 1) + "\(role) \"\(label(e).prefix(50))\" [\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))]")
    for c in children(e) { dumpTree(c, depth: depth + 1) }
}

// MARK: - Arguments

var env = ["AGENT_MONITOR_MOCK_DATA": "1", "AGENT_MONITOR_COLOR_SCHEME": "light"]
var showTree = false
var shotsDir: String?
var steps: [String] = []
var args = CommandLine.arguments.dropFirst().makeIterator()
while let arg = args.next() {
    switch arg {
    case "--mock":
        let v = args.next()!
        if v == "real" { env["AGENT_MONITOR_MOCK_DATA"] = nil } else { env["AGENT_MONITOR_MOCK_DATA"] = v }
    case "--filter": env["AGENT_MONITOR_FILTER"] = args.next()!
    case "--idle-expanded": env["AGENT_MONITOR_IDLE_EXPANDED"] = "1"
    case "--scheme": env["AGENT_MONITOR_COLOR_SCHEME"] = args.next()!
    case "--tree": showTree = true
    case "--shots": shotsDir = args.next()!
    default: steps.append(arg)
    }
}

guard AXIsProcessTrusted() else {
    print("error: grant Accessibility permission to this terminal (System Settings > Privacy & Security > Accessibility)")
    exit(1)
}

// MARK: - Launch and open the panel

let wasRunning = !runBash("pgrep -x AgentMonitor || true").isEmpty
_ = runBash("pkill -9 -x AgentMonitor || true")
Thread.sleep(forTimeInterval: 0.5)

let proc = Process()
proc.executableURL = URL(fileURLWithPath: appBinary)
var procEnv = ProcessInfo.processInfo.environment
for (k, v) in env { procEnv[k] = v }
proc.environment = procEnv
try! proc.run()
Thread.sleep(forTimeInterval: 1.2)

let app = AXUIElementCreateApplication(proc.processIdentifier)

func cleanup() {
    proc.terminate()
    _ = runBash("pkill -9 -x AgentMonitor || true")
    if wasRunning { _ = runBash("open /Users/cy/code/agent-monitor/build/AgentMonitor.app") }
}

guard let extrasBar = attr(app, "AXExtrasMenuBar"), let statusItem = children(extrasBar as! AXUIElement).first else {
    print("error: status item not found")
    cleanup()
    exit(1)
}
// AXPress on the status item does not open a MenuBarExtra window, so post a real click on it
let itemCenter = CGPoint(x: frame(statusItem).midX, y: frame(statusItem).midY)
for type in [CGEventType.leftMouseDown, .leftMouseUp] {
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: itemCenter, mouseButton: .left)?.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.1)
}
Thread.sleep(forTimeInterval: 1.0)

func panelWindow() -> AXUIElement? {
    (attr(app, kAXWindowsAttribute) as? [AXUIElement])?.first { frame($0).height > 40 }
}

func report(step: Int, title: String) {
    guard let window = panelWindow() else {
        print("[\(step)] \(title): panel window not found")
        return
    }
    let f = frame(window)
    print("[\(step)] \(title): window \(Int(f.width))x\(Int(f.height))")
    if showTree { dumpTree(window) }
    if let dir = shotsDir {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = "\(dir)/step-\(step).png"
        _ = runBash("screencapture -x -R \(Int(f.minX) - 10),\(Int(f.minY) - 4),\(Int(f.width) + 20),\(Int(f.height) + 20) '\(path)'")
        print("    screenshot: \(path)")
    }
}

report(step: 0, title: "open")

// MARK: - Steps

for (i, step) in steps.enumerated() {
    guard let window = panelWindow(),
          let button = find(window, where: { attr($0, kAXRoleAttribute) as? String == kAXButtonRole && label($0).hasSuffix(step) }) else {
        print("[\(i + 1)] press \"\(step)\": no button found")
        continue
    }
    AXUIElementPerformAction(button, kAXPressAction as CFString)
    Thread.sleep(forTimeInterval: 1.2)
    report(step: i + 1, title: "press \"\(label(button))\"")
}

cleanup()
