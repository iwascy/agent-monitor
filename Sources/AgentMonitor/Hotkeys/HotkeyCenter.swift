import Foundation
import AppKit
import Carbon
import Combine
import AgentMonitorCore

// MARK: - KeyCombo Display & Formatting

extension KeyCombo {
    public static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        return mods
    }

    public var displayString: String {
        var result = ""
        if (carbonModifiers & UInt32(controlKey)) != 0 { result += "⌃" }
        if (carbonModifiers & UInt32(optionKey)) != 0 { result += "⌥" }
        if (carbonModifiers & UInt32(shiftKey)) != 0 { result += "⇧" }
        if (carbonModifiers & UInt32(cmdKey)) != 0 { result += "⌘" }
        result += Self.keyName(for: keyCode)
        return result
    }

    public static func keyName(for keyCode: UInt32) -> String {
        // 常见特殊键映射
        switch Int(keyCode) {
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Space: return "Space"
        case kVK_Delete: return "⌫"
        case kVK_Escape: return "Esc"
        case kVK_ForwardDelete: return "⌦"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_Home: return "↖"
        case kVK_End: return "↘"
        case kVK_PageUp: return "⇞"
        case kVK_PageDown: return "⇟"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        default: break
        }

        // 使用 UCKeyTranslate 按当前键盘布局解析
        if let inputSource = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue() ??
                              TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
           let rawData = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData) {
            let data = unsafeBitCast(rawData, to: CFData.self)
            if let ptr = CFDataGetBytePtr(data) {
                let keyLayout = UnsafePointer<UCKeyboardLayout>(OpaquePointer(ptr))
                var keysDown: UInt32 = 0
                var chars = [UniChar](repeating: 0, count: 4)
                var length = 0
                let status = UCKeyTranslate(
                    keyLayout,
                    UInt16(keyCode),
                    UInt16(kUCKeyActionDisplay),
                    0,
                    UInt32(LMGetKbdType()),
                    OptionBits(kUCKeyTranslateNoDeadKeysBit),
                    &keysDown,
                    4,
                    &length,
                    &chars
                )
                if status == noErr && length > 0 {
                    let str = String(utf16CodeUnits: chars, count: length).uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
                    if !str.isEmpty {
                        return str
                    }
                }
            }
        }

        // Fallback 映射表兜底
        switch Int(keyCode) {
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        case kVK_ANSI_Equal: return "="
        case kVK_ANSI_Minus: return "-"
        case kVK_ANSI_RightBracket: return "]"
        case kVK_ANSI_LeftBracket: return "["
        case kVK_ANSI_Quote: return "'"
        case kVK_ANSI_Semicolon: return ";"
        case kVK_ANSI_Backslash: return "\\"
        case kVK_ANSI_Comma: return ","
        case kVK_ANSI_Slash: return "/"
        case kVK_ANSI_Period: return "."
        case kVK_ANSI_Grave: return "`"
        default: return "Key_\(keyCode)"
        }
    }
}

// MARK: - HotkeyCenter

@MainActor
public final class HotkeyCenter: ObservableObject {
    public static let shared = HotkeyCenter()

    @Published public private(set) var togglePanelConflict: Bool = false
    @Published public private(set) var jumpWaitingConflict: Bool = false

    public var sessionProvider: (() -> [AgentSession])?

    private var toggleHotKeyRef: EventHotKeyRef?
    private var jumpHotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var isHandlerInstalled: Bool = false
    private var isPaused: Bool = false

    private static let hotKeySignature: OSType = 0x414D4F4E // 'AMON'
    private static let toggleHotKeyID: UInt32 = 1
    private static let jumpHotKeyID: UInt32 = 2

    private var cancellables = Set<AnyCancellable>()

    public init() {
        installHandlerIfNeeded()
        bindSettings()
    }

    public func setup(sessionProvider: @escaping () -> [AgentSession]) {
        self.sessionProvider = sessionProvider
    }

    private func bindSettings() {
        AppSettings.shared.$hotkeyTogglePanel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.registerTogglePanel()
            }
            .store(in: &cancellables)

        AppSettings.shared.$hotkeyJumpWaiting
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.registerJumpWaiting()
            }
            .store(in: &cancellables)
    }

    // MARK: - Registration

    public func registerAll() {
        guard !isPaused else { return }
        registerTogglePanel()
        registerJumpWaiting()
    }

    public func registerTogglePanel() {
        if let ref = toggleHotKeyRef {
            UnregisterEventHotKey(ref)
            toggleHotKeyRef = nil
        }

        guard !isPaused else { return }
        guard let combo = AppSettings.shared.hotkeyTogglePanel else {
            togglePanelConflict = false
            return
        }

        let hkID = EventHotKeyID(signature: Self.hotKeySignature, id: Self.toggleHotKeyID)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            combo.keyCode,
            combo.carbonModifiers,
            hkID,
            GetApplicationEventTarget(),
            0,
            &ref
        )

        if status == noErr {
            toggleHotKeyRef = ref
            togglePanelConflict = false
        } else {
            toggleHotKeyRef = nil
            togglePanelConflict = true
        }
    }

    public func registerJumpWaiting() {
        if let ref = jumpHotKeyRef {
            UnregisterEventHotKey(ref)
            jumpHotKeyRef = nil
        }

        guard !isPaused else { return }
        guard let combo = AppSettings.shared.hotkeyJumpWaiting else {
            jumpWaitingConflict = false
            return
        }

        let hkID = EventHotKeyID(signature: Self.hotKeySignature, id: Self.jumpHotKeyID)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            combo.keyCode,
            combo.carbonModifiers,
            hkID,
            GetApplicationEventTarget(),
            0,
            &ref
        )

        if status == noErr {
            jumpHotKeyRef = ref
            jumpWaitingConflict = false
        } else {
            jumpHotKeyRef = nil
            jumpWaitingConflict = true
        }
    }

    // MARK: - Pause / Resume for Recording

    public func pause() {
        isPaused = true
        if let ref = toggleHotKeyRef {
            UnregisterEventHotKey(ref)
            toggleHotKeyRef = nil
        }
        if let ref = jumpHotKeyRef {
            UnregisterEventHotKey(ref)
            jumpHotKeyRef = nil
        }
        togglePanelConflict = false
        jumpWaitingConflict = false
    }

    public func resume() {
        isPaused = false
        registerAll()
    }

    // MARK: - Event Handling

    private func installHandlerIfNeeded() {
        guard !isHandlerInstalled else { return }
        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, eventRef, _) -> OSStatus in
                guard let eventRef = eventRef else { return noErr }
                var hkID = EventHotKeyID()
                let status = GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hkID
                )
                if status == noErr {
                    DispatchQueue.main.async {
                        HotkeyCenter.shared.handleHotKey(id: hkID.id)
                    }
                }
                return noErr
            },
            1,
            &eventSpec,
            nil,
            &eventHandlerRef
        )

        if status == noErr {
            isHandlerInstalled = true
        }
    }

    public func handleHotKey(id: UInt32) {
        guard !isPaused else { return }
        switch id {
        case Self.toggleHotKeyID:
            MenuBarExtraToggler.toggle()
        case Self.jumpHotKeyID:
            let sessions = sessionProvider?() ?? []
            if let target = Self.selectJumpWaitingTarget(from: sessions, muteRules: AppSettings.shared.muteRules) {
                SessionJumper.shared.jump(to: target)
            }
        default:
            break
        }
    }

    // MARK: - Selection Priority Logic

    public static func selectJumpWaitingTarget(from sessions: [AgentSession], muteRules: [MuteRule] = AppSettings.shared.muteRules) -> AgentSession? {
        let unmuted = sessions.filter { session in
            if let rule = MuteRule.matchingRule(for: session.cwd, rules: muteRules), rule.scope == .all {
                return false
            }
            return true
        }

        let waiting = unmuted.filter { $0.state == .waitingForUser }
        if !waiting.isEmpty {
            // waitingForUser 中 stateSince 最早的一个 (等待时间最长)
            return waiting.min(by: { $0.stateSince < $1.stateSince })
        }

        let completed = unmuted.filter { $0.state == .completed }
        if !completed.isEmpty {
            // completed 中 stateSince 最新的一个 (最近完成)
            return completed.max(by: { $0.stateSince < $1.stateSince })
        }

        return nil
    }
}
