import Testing
import Foundation
import Carbon
import AppKit
import AgentMonitorCore
@testable import AgentMonitor

@Suite("Hotkey & Keyboard Navigation Tests")
@MainActor
struct HotkeyTests {

    private final class MockAdapter: AgentAdapter, @unchecked Sendable {
        let kind: AgentKind = .claudeCode
        var watchPaths: [URL] { [] }
        var sessions: [AgentSession] = []
        func scan() throws -> [AgentSession] { sessions }
    }

    private func makeSession(
        id: String,
        state: SessionState,
        stateSince: Date = Date(),
        cwd: String? = nil
    ) -> AgentSession {
        AgentSession(
            id: id,
            kind: .claudeCode,
            title: "Session \(id)",
            cwd: cwd,
            state: state,
            stateSince: stateSince
        )
    }

    // MARK: - 1. Key Combo Mapping & Display Tests

    @Test("KeyCombo displayString formats modifiers in ⌃⌥⇧⌘ order and resolves key names")
    func testKeyComboFormatting() {
        // ⌃⌥A
        let toggle = KeyCombo(keyCode: UInt32(kVK_ANSI_A), carbonModifiers: UInt32(controlKey | optionKey))
        #expect(toggle.displayString == "⌃⌥A")

        // ⌘↩
        let enter = KeyCombo(keyCode: UInt32(kVK_Return), carbonModifiers: UInt32(cmdKey))
        #expect(enter.displayString == "⌘↩")

        // ⇧⌘⌫
        let delete = KeyCombo(keyCode: UInt32(kVK_Delete), carbonModifiers: UInt32(shiftKey | cmdKey))
        #expect(delete.displayString == "⇧⌘⌫")

        // ⌃⌥⇧⌘Esc
        let allModsEsc = KeyCombo(
            keyCode: UInt32(kVK_Escape),
            carbonModifiers: UInt32(controlKey | optionKey | shiftKey | cmdKey)
        )
        #expect(allModsEsc.displayString == "⌃⌥⇧⌘Esc")

        // 箭头键
        let down = KeyCombo(keyCode: UInt32(kVK_DownArrow), carbonModifiers: 0)
        #expect(down.displayString == "↓")

        let up = KeyCombo(keyCode: UInt32(kVK_UpArrow), carbonModifiers: 0)
        #expect(up.displayString == "↑")

        // 默认面板切换热键
        #expect(AppSettings.defaultTogglePanelHotkey.displayString == "⌃⌥A")
    }

    @Test("KeyCombo.carbonModifiers converts NSEvent modifier flags correctly")
    func testCarbonModifiersConversion() {
        let cmdOnly = KeyCombo.carbonModifiers(from: .command)
        #expect(cmdOnly == UInt32(cmdKey))

        let ctrlOpt = KeyCombo.carbonModifiers(from: [.control, .option])
        #expect(ctrlOpt == UInt32(controlKey | optionKey))

        let all = KeyCombo.carbonModifiers(from: [.control, .option, .shift, .command])
        #expect(all == UInt32(controlKey | optionKey | shiftKey | cmdKey))
    }

    // MARK: - 2. Selection Navigation & Boundary Tests

    @Test("Keyboard selection boundaries and navigation")
    func testSelectionBoundaries() {
        let store = SessionStore(adapters: [])
        let vm = MonitorViewModel(sessionStore: store)

        // 空列表
        #expect(vm.visibleSessionIDs.isEmpty)
        vm.selectNextSession()
        #expect(vm.keyboardSelectionID == nil)
        vm.selectPreviousSession()
        #expect(vm.keyboardSelectionID == nil)

        // 注入 3 个不同状态的 session
        let sWaiting = makeSession(id: "s1", state: .waitingForUser)
        let sDone = makeSession(id: "s2", state: .completed)
        let sRunning = makeSession(id: "s3", state: .running)
        vm.updateSessionsManually([sWaiting, sDone, sRunning])

        #expect(vm.visibleSessionIDs == ["s1", "s2", "s3"])

        // 初始向下：选中第一个
        vm.selectNextSession()
        #expect(vm.keyboardSelectionID == "s1")

        // 移到第二个
        vm.selectNextSession()
        #expect(vm.keyboardSelectionID == "s2")

        // 移到第三个
        vm.selectNextSession()
        #expect(vm.keyboardSelectionID == "s3")

        // 边界：再次向下，停止在末尾，不越界也不循环
        vm.selectNextSession()
        #expect(vm.keyboardSelectionID == "s3")

        // 向上移动
        vm.selectPreviousSession()
        #expect(vm.keyboardSelectionID == "s2")

        vm.selectPreviousSession()
        #expect(vm.keyboardSelectionID == "s1")

        // 边界：再次向上，停止在开头，不越界也不循环
        vm.selectPreviousSession()
        #expect(vm.keyboardSelectionID == "s1")

        // 清空选中后直接向上：选中最后一个
        vm.keyboardSelectionID = nil
        vm.selectPreviousSession()
        #expect(vm.keyboardSelectionID == "s3")
    }

    @Test("Mark current selection as read and advance to next")
    func testMarkCurrentSelectionAsReadAndAdvance() {
        let store = SessionStore(adapters: [])
        let vm = MonitorViewModel(sessionStore: store)

        let sWaiting = makeSession(id: "s1", state: .waitingForUser)
        let sDone = makeSession(id: "s2", state: .completed)
        let sRunning = makeSession(id: "s3", state: .running)

        vm.updateSessionsManually([sWaiting, sDone, sRunning])

        // 选中已完成的 s2
        vm.keyboardSelectionID = "s2"
        vm.markCurrentSelectionAsReadAndAdvance()

        // 确认 s2 被标为已读（状态从 completed 转为 idle），选中项自动移到了下一项 s3
        #expect(vm.sessions.first(where: { $0.id == "s2" })?.state == .idle)
        #expect(vm.keyboardSelectionID == "s3")
    }

    @Test("Digit filter and escape key handling")
    func testDigitFilterAndEscape() {
        let store = SessionStore(adapters: [])
        let vm = MonitorViewModel(sessionStore: store)

        let sWaiting = makeSession(id: "s1", state: .waitingForUser)
        let sDone = makeSession(id: "s2", state: .completed)
        vm.updateSessionsManually([sWaiting, sDone])

        // 按 1 筛选「等你回复」
        vm.keyboardSelectionID = "s1"
        vm.handleDigitFilter(1)
        #expect(vm.filterState == .waitingForUser)
        #expect(vm.keyboardSelectionID == nil) // 切换后选中清空

        // 再次按 1 取消筛选
        vm.handleDigitFilter(1)
        #expect(vm.filterState == nil)
        #expect(vm.keyboardSelectionID == nil)

        // 按 3（running），当前没有 running 会话，应被忽略
        vm.handleDigitFilter(3)
        #expect(vm.filterState == nil)

        // esc 处理：有筛选时清除筛选并返回 true
        vm.handleDigitFilter(2)
        #expect(vm.filterState == .completed)
        let handled = vm.handleEscape()
        #expect(handled == true)
        #expect(vm.filterState == nil)

        // esc 处理：无筛选时返回 false
        let handledAgain = vm.handleEscape()
        #expect(handledAgain == false)
    }

    // MARK: - 3. jumpWaiting Selection Priority Tests

    @Test("jumpWaiting selects earliest waiting session first")
    func testJumpWaitingEarliestWaitingPriority() {
        let now = Date()
        let wOld = makeSession(id: "wOld", state: .waitingForUser, stateSince: now.addingTimeInterval(-300))
        let wNew = makeSession(id: "wNew", state: .waitingForUser, stateSince: now.addingTimeInterval(-60))
        let done = makeSession(id: "done", state: .completed, stateSince: now.addingTimeInterval(-10))
        let running = makeSession(id: "running", state: .running, stateSince: now)

        let target = HotkeyCenter.selectJumpWaitingTarget(from: [done, wNew, running, wOld], muteRules: [])
        // 应选出等待时间最长（stateSince 最早）的 wOld
        #expect(target?.id == "wOld")
    }

    @Test("jumpWaiting selects latest completed session when no waiting sessions exist")
    func testJumpWaitingLatestCompletedFallback() {
        let now = Date()
        let doneOld = makeSession(id: "doneOld", state: .completed, stateSince: now.addingTimeInterval(-500))
        let doneNew = makeSession(id: "doneNew", state: .completed, stateSince: now.addingTimeInterval(-30))
        let running = makeSession(id: "running", state: .running, stateSince: now)
        let idle = makeSession(id: "idle", state: .idle, stateSince: now)

        let target = HotkeyCenter.selectJumpWaitingTarget(from: [idle, doneOld, running, doneNew], muteRules: [])
        // 没有 waiting 时，选出最近完成的 doneNew
        #expect(target?.id == "doneNew")
    }

    @Test("jumpWaiting respects mute rules with scope == .all")
    func testJumpWaitingRespectsMuteRules() {
        let now = Date()
        let mutedWaiting = makeSession(
            id: "mutedWaiting",
            state: .waitingForUser,
            stateSince: now.addingTimeInterval(-300),
            cwd: "/Users/test/muted-project"
        )
        let normalWaiting = makeSession(
            id: "normalWaiting",
            state: .waitingForUser,
            stateSince: now.addingTimeInterval(-60),
            cwd: "/Users/test/normal-project"
        )

        let rule = MuteRule(path: "/Users/test/muted-project", scope: .all)

        let target = HotkeyCenter.selectJumpWaitingTarget(
            from: [mutedWaiting, normalWaiting],
            muteRules: [rule]
        )
        // mutedWaiting 命中全静音，应被排除，选出 normalWaiting
        #expect(target?.id == "normalWaiting")
    }

    @Test("jumpWaiting returns nil when no waiting or completed sessions exist")
    func testJumpWaitingReturnsNilWhenNoneAvailable() {
        let now = Date()
        let running = makeSession(id: "r1", state: .running, stateSince: now)
        let idle = makeSession(id: "i1", state: .idle, stateSince: now)

        #expect(HotkeyCenter.selectJumpWaitingTarget(from: [], muteRules: []) == nil)
        #expect(HotkeyCenter.selectJumpWaitingTarget(from: [running, idle], muteRules: []) == nil)
    }

    // MARK: - 4. Keypad Enter and Filter Selection Cleared Tests

    @Test("Keypad Enter (keyCode 76) triggers activation")
    func testKeypadEnterActivatesSelection() {
        let store = SessionStore(adapters: [])
        let vm = MonitorViewModel(sessionStore: store)
        let s1 = makeSession(id: "s1", state: .waitingForUser)
        vm.updateSessionsManually([s1])

        vm.keyboardSelectionID = "s1"

        let keypadEnterEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 76
        )!

        let handled = vm.handleKeyEvent(keypadEnterEvent)
        #expect(handled == true)
    }

    @Test("Disappeared selection when filtered clears keyboardSelectionID")
    func testFilterClearsSelectedID() {
        let store = SessionStore(adapters: [])
        let vm = MonitorViewModel(sessionStore: store)
        let s1 = makeSession(id: "s1", state: .waitingForUser)
        let s2 = makeSession(id: "s2", state: .completed)
        vm.updateSessionsManually([s1, s2])

        vm.keyboardSelectionID = "s2"
        #expect(vm.keyboardSelectionID == "s2")

        // 切换为 waiting 过滤，s2 被过滤掉，keyboardSelectionID 应被清空
        vm.filterState = .waitingForUser
        #expect(vm.keyboardSelectionID == nil)
    }

    @Test("KeyRecorderView captures Command key combinations during recording")
    func testKeyRecorderInterceptsCommand() {
        let view = KeyRecorderNSView()
        _ = view.becomeFirstResponder()
        #expect(view.isRecording == true)

        let cmdWEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "w",
            charactersIgnoringModifiers: "w",
            isARepeat: false,
            keyCode: UInt16(kVK_ANSI_W)
        )!

        let handled = view.performKeyEquivalent(with: cmdWEvent)
        #expect(handled == true)
        #expect(view.isRecording == false)
        #expect(view.keyCombo?.keyCode == UInt32(kVK_ANSI_W))
    }
}
