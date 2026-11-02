import SwiftUI
import AppKit
import Carbon
import AgentMonitorCore

public struct KeyRecorderView: NSViewRepresentable {
    @Binding public var keyCombo: KeyCombo?
    public var onChange: ((KeyCombo?) -> Void)?

    public init(keyCombo: Binding<KeyCombo?>, onChange: ((KeyCombo?) -> Void)? = nil) {
        self._keyCombo = keyCombo
        self.onChange = onChange
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    public func makeNSView(context: Context) -> KeyRecorderNSView {
        let view = KeyRecorderNSView()
        view.coordinator = context.coordinator
        view.keyCombo = keyCombo
        return view
    }

    public func updateNSView(_ nsView: KeyRecorderNSView, context: Context) {
        context.coordinator.parent = self
        if !nsView.isRecording {
            nsView.keyCombo = keyCombo
            nsView.needsDisplay = true
        }
    }

    @MainActor
    public final class Coordinator {
        var parent: KeyRecorderView

        init(_ parent: KeyRecorderView) {
            self.parent = parent
        }

        func updateCombo(_ combo: KeyCombo?) {
            parent.keyCombo = combo
            parent.onChange?(combo)
        }
    }
}

@MainActor
public final class KeyRecorderNSView: NSView {
    weak var coordinator: KeyRecorderView.Coordinator?
    private var windowObservers: [NSObjectProtocol] = []

    public var isRecording: Bool = false {
        didSet {
            updateAccessibility()
            needsDisplay = true
        }
    }

    public var keyCombo: KeyCombo? {
        didSet {
            updateAccessibility()
            needsDisplay = true
        }
    }

    override public var acceptsFirstResponder: Bool { true }

    override public init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupAccessibility()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupAccessibility()
    }

    isolated deinit {
        for obs in windowObservers {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    private func setupAccessibility() {
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        updateAccessibility()
    }

    private func updateAccessibility() {
        if isRecording {
            setAccessibilityLabel("快捷键录制中")
            setAccessibilityValue("请按快捷键")
        } else {
            setAccessibilityLabel("快捷键")
            setAccessibilityValue(keyCombo?.displayString ?? "未设置")
        }
    }

    override public var intrinsicContentSize: NSSize {
        let width: CGFloat = keyCombo != nil ? 90 : 80
        return NSSize(width: max(width, 76), height: 24)
    }

    public func cancelRecording() {
        guard isRecording else { return }
        isRecording = false
        HotkeyCenter.shared.resume()
        window?.makeFirstResponder(nil)
    }

    override public func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        cancelRecording()
        removeWindowObservers()
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        setupWindowObservers()
    }

    private func setupWindowObservers() {
        removeWindowObservers()
        guard let win = window else { return }

        let center = NotificationCenter.default
        let obs1 = center.addObserver(forName: NSWindow.didResignKeyNotification, object: win, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.cancelRecording()
            }
        }
        let obs2 = center.addObserver(forName: NSWindow.willCloseNotification, object: win, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.cancelRecording()
            }
        }
        windowObservers = [obs1, obs2]
    }

    private func removeWindowObservers() {
        for obs in windowObservers {
            NotificationCenter.default.removeObserver(obs)
        }
        windowObservers.removeAll()
    }

    override public func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok && !isRecording {
            isRecording = true
            HotkeyCenter.shared.pause()
        }
        return ok
    }

    override public func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok && isRecording {
            isRecording = false
            HotkeyCenter.shared.resume()
        }
        return ok
    }

    override public func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else {
            return super.performKeyEquivalent(with: event)
        }
        keyDown(with: event)
        return true
    }

    override public func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)

        // 处于非录制态且存在快捷键时，检查是否点击了右侧清除小叉号 ✕
        if !isRecording && keyCombo != nil {
            let clearRect = NSRect(x: bounds.maxX - 22, y: 0, width: 22, height: bounds.height)
            if clearRect.contains(location) {
                keyCombo = nil
                coordinator?.updateCombo(nil)
                return
            }
        }

        if !isRecording {
            _ = window?.makeFirstResponder(self)
        }
    }

    override public func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }

        // 1. Esc: 取消录制
        if event.keyCode == 53 {
            isRecording = false
            HotkeyCenter.shared.resume()
            window?.makeFirstResponder(nil)
            return
        }

        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])

        // 2. ⌫ 或 ⌦ 且无修饰键：清除
        if (event.keyCode == 51 || event.keyCode == 117) && flags.isEmpty {
            keyCombo = nil
            coordinator?.updateCombo(nil)
            isRecording = false
            HotkeyCenter.shared.resume()
            window?.makeFirstResponder(nil)
            return
        }

        // 3. 修饰键必须包含 ⌘、⌃、⌥ 之一
        let hasPrimaryModifier = flags.contains(.command) || flags.contains(.option) || flags.contains(.control)
        if hasPrimaryModifier {
            let carbonMods = KeyCombo.carbonModifiers(from: flags)
            let combo = KeyCombo(keyCode: UInt32(event.keyCode), carbonModifiers: carbonMods)
            keyCombo = combo
            coordinator?.updateCombo(combo)
            isRecording = false
            HotkeyCenter.shared.resume()
            window?.makeFirstResponder(nil)
            return
        }

        // 否则忽略
    }

    override public func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let cornerRadius: CGFloat = 6.0
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: cornerRadius, yRadius: cornerRadius)

        // 背景
        NSColor.controlBackgroundColor.setFill()
        path.fill()

        // 边框描边
        if isRecording {
            let borderPath = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: cornerRadius, yRadius: cornerRadius)
            borderPath.lineWidth = 2.0
            NSColor.controlAccentColor.setStroke()
            borderPath.stroke()
        } else {
            let borderPath = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: cornerRadius, yRadius: cornerRadius)
            borderPath.lineWidth = 1.0
            NSColor.separatorColor.setStroke()
            borderPath.stroke()
        }

        // 文本与清除按钮
        let textFont = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center

        if isRecording {
            let text = "请按快捷键…"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: textFont,
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraphStyle
            ]
            let str = NSAttributedString(string: text, attributes: attrs)
            let size = str.size()
            let rect = NSRect(
                x: (bounds.width - size.width) / 2,
                y: (bounds.height - size.height) / 2,
                width: size.width,
                height: size.height
            )
            str.draw(in: rect)
        } else if let combo = keyCombo {
            // 显示快捷键
            let text = combo.displayString
            paragraphStyle.alignment = .left
            let attrs: [NSAttributedString.Key: Any] = [
                .font: textFont,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraphStyle
            ]
            let str = NSAttributedString(string: text, attributes: attrs)
            let size = str.size()
            let textRect = NSRect(
                x: 8,
                y: (bounds.height - size.height) / 2,
                width: size.width,
                height: size.height
            )
            str.draw(in: textRect)

            // 清除小叉号 ✕
            let clearStyle = NSMutableParagraphStyle()
            clearStyle.alignment = .center
            let clearAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: NSColor.tertiaryLabelColor,
                .paragraphStyle: clearStyle
            ]
            let clearStr = NSAttributedString(string: "✕", attributes: clearAttrs)
            let clearSize = clearStr.size()
            let clearRect = NSRect(
                x: bounds.maxX - clearSize.width - 7,
                y: (bounds.height - clearSize.height) / 2,
                width: clearSize.width,
                height: clearSize.height
            )
            clearStr.draw(in: clearRect)
        } else {
            let text = "点击录制"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: textFont,
                .foregroundColor: NSColor.tertiaryLabelColor,
                .paragraphStyle: paragraphStyle
            ]
            let str = NSAttributedString(string: text, attributes: attrs)
            let size = str.size()
            let rect = NSRect(
                x: (bounds.width - size.width) / 2,
                y: (bounds.height - size.height) / 2,
                width: size.width,
                height: size.height
            )
            str.draw(in: rect)
        }
    }
}
