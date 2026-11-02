import AppKit
import ApplicationServices
import Foundation
import UserNotifications

@MainActor
public final class FocusStrategies {
    public static let shared = FocusStrategies()

    private var deniedAppleScriptHosts: Set<String> = []
    private var hasNotifiedAccessibilityPermission = false

    public init() {}

    nonisolated public static func normalizeTitle(_ raw: String) -> String {
        var str = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = str.first {
            let isAlphanumeric = first.isLetter || first.isNumber
            let isCJK = ("\u{4e00}"..."\u{9fff}").contains(first)
                || ("\u{3400}"..."\u{4dbf}").contains(first)
                || ("\u{20000}"..."\u{2a6df}").contains(first)
                || ("\u{f900}"..."\u{faff}").contains(first)
            if isAlphanumeric || isCJK {
                break
            }
            str.removeFirst()
        }
        let collapsed = str.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public func focusTerminal(host: HostInfo, titleHint: String?, cwd: String?) {
        let bundleId = host.app.bundleIdentifier ?? ""

        // 1. AppleScript for iTerm2 and Apple Terminal if tty is known
        if let tty = host.tty, !tty.isEmpty, shouldAttemptAppleScript(for: bundleId) {
            let script: String?
            if bundleId == "com.googlecode.iterm2" {
                let escapedTTY = escapeAppleScriptString(tty)
                script = """
                tell application id "com.googlecode.iterm2"
                    repeat with w in windows
                        repeat with t in tabs of w
                            repeat with s in sessions of t
                                if tty of s is "\(escapedTTY)" then
                                    select s
                                    select t
                                    tell w to select
                                    activate
                                    return true
                                end if
                            end repeat
                        end repeat
                    end repeat
                    return false
                end tell
                """
            } else if bundleId == "com.apple.Terminal" {
                let escapedTTY = escapeAppleScriptString(tty)
                script = """
                tell application id "com.apple.Terminal"
                    repeat with w in windows
                        repeat with t in tabs of w
                            if tty of t is "\(escapedTTY)" then
                                set selected tab of w to t
                                set index of w to 1
                                activate
                                return true
                            end if
                        end repeat
                    end repeat
                    return false
                end tell
                """
            } else {
                script = nil
            }

            if let scriptText = script {
                let success = runAppleScriptWithTimeout(scriptText, timeout: 2.0, bundleId: bundleId)
                if success {
                    return
                }
            }
        }

        // 2. Window title matching via AX
        if AXIsProcessTrusted() {
            if matchAndFocusWindow(app: host.app, titleHint: titleHint, cwd: cwd) {
                return
            }
        } else {
            notifyAccessibilityPermissionIfNeeded()
        }

        // 3. Fallback: activate app
        host.app.activate()
    }

    public func focusEditor(bundleId: String, folder: URL) {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.open([folder], withApplicationAt: appURL, configuration: config, completionHandler: nil)
        } else {
            activateAppByBundleId(bundleId)
        }
    }

    public func activateAppByBundleId(_ bundleId: String) {
        if bundleId == "com.openai.codex" || bundleId == "com.openai.chat" {
            let candidates = ["com.openai.codex", "com.openai.chat"]
            for id in candidates {
                if let running = NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
                    running.activate()
                    return
                }
            }
            for id in candidates {
                if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                    let config = NSWorkspace.OpenConfiguration()
                    config.activates = true
                    NSWorkspace.shared.openApplication(at: appURL, configuration: config, completionHandler: nil)
                    return
                }
            }
            let fallbackPath = "/Applications/ChatGPT.app"
            if FileManager.default.fileExists(atPath: fallbackPath) {
                let appURL = URL(fileURLWithPath: fallbackPath)
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                NSWorkspace.shared.openApplication(at: appURL, configuration: config, completionHandler: nil)
                return
            }
        }

        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first {
            running.activate()
        } else if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: appURL, configuration: config, completionHandler: nil)
        }
    }

    public func matchAndFocusWindow(app: NSRunningApplication, titleHint: String?, cwd: String?) -> Bool {
        guard let win = findMatchingWindow(app: app, titleHint: titleHint, cwd: cwd) else {
            return false
        }
        AXUIElementSetAttributeValue(win, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(win, kAXRaiseAction as CFString)
        app.activate()
        return true
    }

    public func findMatchingWindow(app: NSRunningApplication, titleHint: String?, cwd: String?) -> AXUIElement? {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var windowsVal: AnyObject?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsVal) == .success,
              let windows = windowsVal as? [AXUIElement], !windows.isEmpty else {
            return nil
        }

        let normalizedTitleHint = titleHint.map { Self.normalizeTitle($0) } ?? ""
        let cwdLast = cwd.map { ($0 as NSString).lastPathComponent.lowercased() } ?? ""

        var exactMatch: AXUIElement?
        var containsTitleMatch: AXUIElement?
        var containsCwdMatch: AXUIElement?

        for win in windows {
            var titleVal: AnyObject?
            guard AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &titleVal) == .success,
                  let rawWinTitle = titleVal as? String else {
                continue
            }
            let normWinTitle = Self.normalizeTitle(rawWinTitle)

            if !normalizedTitleHint.isEmpty && normWinTitle == normalizedTitleHint {
                exactMatch = win
                break
            }
            if containsTitleMatch == nil && !normalizedTitleHint.isEmpty && normWinTitle.contains(normalizedTitleHint) {
                containsTitleMatch = win
            }
            if containsCwdMatch == nil && !cwdLast.isEmpty && normWinTitle.contains(cwdLast) {
                containsCwdMatch = win
            }
        }

        return exactMatch ?? containsTitleMatch ?? containsCwdMatch
    }

    public func getMatchedWindowTitle(app: NSRunningApplication, titleHint: String?, cwd: String?) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        guard let win = findMatchingWindow(app: app, titleHint: titleHint, cwd: cwd) else { return nil }
        var titleVal: AnyObject?
        if AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &titleVal) == .success,
           let title = titleVal as? String, !title.isEmpty {
            return title
        }
        return nil
    }

    private func shouldAttemptAppleScript(for bundleId: String) -> Bool {
        return !deniedAppleScriptHosts.contains(bundleId)
    }

    private func escapeAppleScriptString(_ str: String) -> String {
        return str.replacingOccurrences(of: "\\", with: "\\\\")
                  .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func runAppleScriptWithTimeout(_ source: String, timeout: TimeInterval, bundleId: String) -> Bool {
        final class ResultBox: @unchecked Sendable {
            var success = false
            var wasDenied = false
        }
        let box = ResultBox()
        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            var errorInfo: NSDictionary?
            let appleScript = NSAppleScript(source: source)
            let resultDesc = appleScript?.executeAndReturnError(&errorInfo)
            if let error = errorInfo {
                let code = (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? 0
                if code == -1743 { // errAEEventNotPermitted
                    box.wasDenied = true
                }
            } else if let result = resultDesc, result.booleanValue {
                box.success = true
            }
            group.leave()
        }

        let waitResult = group.wait(timeout: .now() + timeout)
        if box.wasDenied {
            deniedAppleScriptHosts.insert(bundleId)
        }
        return waitResult == .success && box.success
    }

    private func notifyAccessibilityPermissionIfNeeded() {
        guard !hasNotifiedAccessibilityPermission else { return }
        hasNotifiedAccessibilityPermission = true

        let content = UNMutableNotificationContent()
        content.title = "需要辅助功能权限"
        content.body = "授权后，Agent Monitor 可以直接跳到会话所在的终端窗口。"
        content.sound = .default
        content.userInfo = ["action": "openIntegrationSettings"]

        let request = UNNotificationRequest(identifier: "am-accessibility-prompt", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}
