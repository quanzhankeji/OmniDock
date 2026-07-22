import AppKit
import Carbon.HIToolbox

final class ShortcutRecorderView: NSControl {
    var recordedShortcut: RecordedShortcut? {
        didSet {
            if !isRecording {
                updateDisplay()
            }
        }
    }

    var onChange: ((RecordedShortcut?) -> Void)?

    override var acceptsFirstResponder: Bool {
        true
    }

    override var isEnabled: Bool {
        didSet {
            updateDisplay()
            updateAppearance()
        }
    }

    private let label = NSTextField(labelWithString: "")
    private var isRecording = false
    private var transientMessage: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else {
            return
        }
        beginRecording()
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }

        let keyCode = Int(event.keyCode)
        if keyCode == kVK_Escape {
            cancelRecording()
            return
        }

        if keyCode == kVK_Delete || keyCode == kVK_ForwardDelete {
            finishRecording(with: nil)
            return
        }

        if let reason = ShortcutRecorderValidation.recordingRejectionReason(
            keyCode: keyCode,
            modifierFlags: event.modifierFlags
        ) {
            showTransientMessage(reason)
            return
        }

        let shortcut = ShortcutRecorderValidation.normalizedShortcut(
            keyCode: keyCode,
            modifierFlags: event.modifierFlags
        )
        finishRecording(with: shortcut)
    }

    override func resignFirstResponder() -> Bool {
        if isRecording {
            cancelRecording()
        }
        return super.resignFirstResponder()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if isEnabled {
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateDisplay()
        updateAppearance()
    }

    private func setup() {
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.font = .monospacedSystemFont(ofSize: 12, weight: .medium)

        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        updateDisplay()
        updateAppearance()
    }

    private func beginRecording() {
        transientMessage = nil
        isRecording = true
        updateDisplay()
        updateAppearance()
        window?.makeFirstResponder(self)
    }

    private func cancelRecording() {
        isRecording = false
        transientMessage = nil
        updateDisplay()
        updateAppearance()
        if window?.firstResponder === self {
            window?.makeFirstResponder(nil)
        }
    }

    private func finishRecording(with shortcut: RecordedShortcut?) {
        isRecording = false
        transientMessage = nil
        recordedShortcut = shortcut
        updateDisplay()
        updateAppearance()
        onChange?(shortcut)
        if window?.firstResponder === self {
            window?.makeFirstResponder(nil)
        }
    }

    private func showTransientMessage(_ message: String) {
        transientMessage = message
        updateDisplay()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            guard let self, self.isRecording, self.transientMessage == message else {
                return
            }
            self.transientMessage = nil
            self.updateDisplay()
        }
    }

    private func updateDisplay() {
        if !isEnabled {
            label.stringValue = AppStrings.text(.hotkeyUnavailable)
        } else if let transientMessage {
            label.stringValue = transientMessage
        } else if isRecording {
            label.stringValue = AppStrings.text(.hotkeyRecording)
        } else if let recordedShortcut {
            label.stringValue = ShortcutFormatter.string(for: recordedShortcut)
        } else {
            label.stringValue = AppStrings.text(.hotkeyRecord)
        }
        let palette = OmniDockTheme.palette(for: effectiveAppearance)
        label.textColor = isEnabled ? palette.primaryText : palette.disabledText
    }

    private func updateAppearance() {
        layer?.cornerRadius = 6
        layer?.borderWidth = isRecording ? 1.5 : 1
        let palette = OmniDockTheme.palette(for: effectiveAppearance)
        layer?.borderColor = (isRecording ? palette.accent : palette.separator).cgColor
        layer?.backgroundColor = (isEnabled ? palette.surface : palette.raisedSurface).cgColor
    }
}

enum ShortcutFormatter {
    static func string(for shortcut: RecordedShortcut) -> String {
        let flags = NSEvent.ModifierFlags(rawValue: shortcut.modifierFlags)
            .intersection(.deviceIndependentFlagsMask)
        var symbols = ""
        if flags.contains(.control) {
            symbols += "⌃"
        }
        if flags.contains(.option) {
            symbols += "⌥"
        }
        if flags.contains(.shift) {
            symbols += "⇧"
        }
        if flags.contains(.command) {
            symbols += "⌘"
        }
        return symbols + keyName(for: shortcut.keyCode)
    }

    static func keyName(for keyCode: Int) -> String {
        keyNames[keyCode] ?? "Key \(keyCode)"
    }

    private static let keyNames: [Int: String] = [
        kVK_ANSI_A: "A",
        kVK_ANSI_B: "B",
        kVK_ANSI_C: "C",
        kVK_ANSI_D: "D",
        kVK_ANSI_E: "E",
        kVK_ANSI_F: "F",
        kVK_ANSI_G: "G",
        kVK_ANSI_H: "H",
        kVK_ANSI_I: "I",
        kVK_ANSI_J: "J",
        kVK_ANSI_K: "K",
        kVK_ANSI_L: "L",
        kVK_ANSI_M: "M",
        kVK_ANSI_N: "N",
        kVK_ANSI_O: "O",
        kVK_ANSI_P: "P",
        kVK_ANSI_Q: "Q",
        kVK_ANSI_R: "R",
        kVK_ANSI_S: "S",
        kVK_ANSI_T: "T",
        kVK_ANSI_U: "U",
        kVK_ANSI_V: "V",
        kVK_ANSI_W: "W",
        kVK_ANSI_X: "X",
        kVK_ANSI_Y: "Y",
        kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0",
        kVK_ANSI_1: "1",
        kVK_ANSI_2: "2",
        kVK_ANSI_3: "3",
        kVK_ANSI_4: "4",
        kVK_ANSI_5: "5",
        kVK_ANSI_6: "6",
        kVK_ANSI_7: "7",
        kVK_ANSI_8: "8",
        kVK_ANSI_9: "9",
        kVK_ANSI_Minus: "-",
        kVK_ANSI_Equal: "=",
        kVK_ANSI_LeftBracket: "[",
        kVK_ANSI_RightBracket: "]",
        kVK_ANSI_Backslash: "\\",
        kVK_ANSI_Semicolon: ";",
        kVK_ANSI_Quote: "'",
        kVK_ANSI_Grave: "`",
        kVK_ANSI_Comma: ",",
        kVK_ANSI_Period: ".",
        kVK_ANSI_Slash: "/",
        kVK_Space: "Space",
        kVK_Return: "Return",
        kVK_Tab: "Tab",
        kVK_Escape: "Esc",
        kVK_Delete: "Delete",
        kVK_ForwardDelete: "Forward Delete",
        kVK_Home: "Home",
        kVK_End: "End",
        kVK_PageUp: "Page Up",
        kVK_PageDown: "Page Down",
        kVK_LeftArrow: "←",
        kVK_RightArrow: "→",
        kVK_UpArrow: "↑",
        kVK_DownArrow: "↓",
        kVK_F1: "F1",
        kVK_F2: "F2",
        kVK_F3: "F3",
        kVK_F4: "F4",
        kVK_F5: "F5",
        kVK_F6: "F6",
        kVK_F7: "F7",
        kVK_F8: "F8",
        kVK_F9: "F9",
        kVK_F10: "F10",
        kVK_F11: "F11",
        kVK_F12: "F12",
        kVK_F13: "F13",
        kVK_F14: "F14",
        kVK_F15: "F15",
        kVK_F16: "F16",
        kVK_F17: "F17",
        kVK_F18: "F18",
        kVK_F19: "F19",
        kVK_F20: "F20"
    ]
}
