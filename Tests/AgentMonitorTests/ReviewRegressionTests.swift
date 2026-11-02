import AppKit
import Carbon
import Foundation
import Synchronization
import Testing
import UserNotifications
import AgentMonitorCore
@testable import AgentMonitor

@Suite("v2 review regressions")
@MainActor
struct ReviewRegressionTests {
    @Test("AppleScript deadline returns before execution finishes and records a late denial")
    func testScriptDeadlineAndLateDenial() async throws {
        let release = DispatchSemaphore(value: 0)
        let strategies = FocusStrategies(appleScriptTimeout: .milliseconds(50)) { _ in
            _ = release.wait(timeout: .now() + 2)
            return .init(success: false, wasDenied: true)
        }
        defer { release.signal() }

        let start = ContinuousClock.now
        let success = await strategies.runAppleScriptWithTimeout("ignored", bundleId: "test.terminal")
        #expect(!success)
        #expect(start.duration(to: .now) < .seconds(1))
        #expect(strategies.shouldAttemptAppleScript(for: "test.terminal"))

        release.signal()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while strategies.shouldAttemptAppleScript(for: "test.terminal"), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!strategies.shouldAttemptAppleScript(for: "test.terminal"))
    }

    @Test("A successful AppleScript completes without waiting for the deadline")
    func testScriptSuccess() async {
        let strategies = FocusStrategies(appleScriptTimeout: .seconds(2)) { _ in
            .init(success: true, wasDenied: false)
        }
        let start = ContinuousClock.now
        #expect(await strategies.runAppleScriptWithTimeout("ignored", bundleId: "test.terminal"))
        #expect(start.duration(to: .now) < .seconds(1))
    }

    @Test("Jump descriptions execute off the main thread and cache empty results too")
    func testDescriptionBackgroundAndCache() async {
        let calls = Mutex(0)
        let jumper = SessionJumper { _ in
            #expect(!Thread.isMainThread)
            calls.withLock { $0 += 1 }
            return nil
        }
        let session = AgentSession(id: "test", kind: .codex, title: "Test", state: .running)
        #expect(await jumper.describeTarget(for: session) == nil)
        #expect(await jumper.describeTarget(for: session) == nil)
        #expect(calls.withLock { $0 } == 1)
    }

    @Test("Cold notification settings requests wait for the startup action and retain the target tab")
    func testColdSettingsRequest() {
        var activations = 0
        var opens = 0
        let manager = SettingsWindowManager { activations += 1 }
        manager.openSettings(tab: .integration)
        #expect(activations == 0)
        #expect(manager.selectedTab == .integration)

        manager.installOpenSettingsAction { opens += 1 }
        #expect(activations == 1)
        #expect(opens == 1)
        #expect(manager.selectedTab == .integration)
        manager.installOpenSettingsAction { opens += 1 }
        #expect(opens == 1)
        manager.openSettings(tab: .general)
        #expect(opens == 2)
        #expect(activations == 2)
        #expect(manager.selectedTab == .general)
    }

    @Test("Changing conflicting or swapped hotkeys releases both old registrations first")
    func testHotkeyConflictRecovery() {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "am.test.hotkeys.\(UUID().uuidString)")!)
        let a = KeyCombo(keyCode: UInt32(kVK_ANSI_A), carbonModifiers: UInt32(controlKey | optionKey))
        let b = KeyCombo(keyCode: UInt32(kVK_ANSI_B), carbonModifiers: a.carbonModifiers)
        let c = KeyCombo(keyCode: UInt32(kVK_ANSI_C), carbonModifiers: a.carbonModifiers)
        var registered: [EventHotKeyRef: KeyCombo] = [:]
        var nextRef = 1
        let center = HotkeyCenter(settings: settings, registerHotKey: { combo, _ in
            guard !registered.values.contains(combo) else { return nil }
            let ref = EventHotKeyRef(bitPattern: nextRef)!
            nextRef += 1
            registered[ref] = combo
            return ref
        }, unregisterHotKey: { ref in
            registered.removeValue(forKey: ref)
        })
        defer { center.pause() }

        settings.hotkeyTogglePanel = a
        settings.hotkeyJumpWaiting = b
        center.registerAll()
        #expect(!center.togglePanelConflict && !center.jumpWaitingConflict)
        settings.hotkeyTogglePanel = b
        center.registerAll()
        #expect(center.togglePanelConflict || center.jumpWaitingConflict)
        settings.hotkeyJumpWaiting = c
        center.registerAll()
        #expect(!center.togglePanelConflict && !center.jumpWaitingConflict)
        #expect(registered.count == 2)
        settings.hotkeyTogglePanel = c
        settings.hotkeyJumpWaiting = b
        center.registerAll()
        #expect(!center.togglePanelConflict && !center.jumpWaitingConflict)
        #expect(registered.count == 2)
    }

    @Test("Unavailable named notification sounds fall back to the default sound")
    func testNotificationSoundFallback() {
        #expect(Notifier.notificationSound(name: "none") == nil)
        #expect(Notifier.notificationSound(name: "default")?.isEqual(UNNotificationSound.default) == true)
        #expect(Notifier.notificationSound(name: "Glass")?.isEqual(UNNotificationSound.default) == true)
    }
}
