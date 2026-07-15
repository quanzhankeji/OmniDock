import AppKit
import Carbon.HIToolbox

public enum HotkeyShortcutPolicy {
    public static func rejectionReason(
        for shortcut: RecordedShortcut,
        systemShortcuts: Set<RecordedShortcut> = SystemHotkeyConflictChecker.enabledSystemShortcuts()
    ) -> String? {
        if isCommonApplicationMenuShortcut(shortcut) {
            return AppStrings.text(.hotkeyCommonMenu)
        }
        if isBrowserTabNavigationShortcut(shortcut) {
            return AppStrings.text(.hotkeyBrowserTab)
        }
        if SystemHotkeyConflictChecker.containsConflict(shortcut, systemShortcuts: systemShortcuts) {
            return AppStrings.text(.hotkeySystemConflict)
        }
        return nil
    }

    public static func isBrowserTabNavigationShortcut(_ shortcut: RecordedShortcut) -> Bool {
        let flags = normalizedFlags(shortcut.modifierFlags)
        let keyCode = shortcut.keyCode

        if keyCode == kVK_Tab {
            return flags == [.control] || flags == [.control, .shift]
        }

        if keyCode == kVK_ANSI_LeftBracket || keyCode == kVK_ANSI_RightBracket {
            return flags == [.command, .shift]
        }

        if keyCode == kVK_LeftArrow || keyCode == kVK_RightArrow {
            return flags == [.command, .option]
        }

        if keyCode == kVK_PageUp || keyCode == kVK_PageDown {
            return flags == [.control]
                || flags == [.control, .shift]
                || flags == [.command, .shift]
        }

        if commandNumberKeyCodes.contains(keyCode) {
            return flags == [.command]
        }

        return false
    }

    public static func isCommonApplicationMenuShortcut(_ shortcut: RecordedShortcut) -> Bool {
        let flags = normalizedFlags(shortcut.modifierFlags)
            .intersection([.command, .control, .option, .shift])
        let nonShiftFlags = flags.subtracting(.shift)
        return nonShiftFlags == [.command] && !functionKeyCodes.contains(shortcut.keyCode)
    }

    private static let commandNumberKeyCodes: Set<Int> = [
        kVK_ANSI_1,
        kVK_ANSI_2,
        kVK_ANSI_3,
        kVK_ANSI_4,
        kVK_ANSI_5,
        kVK_ANSI_6,
        kVK_ANSI_7,
        kVK_ANSI_8,
        kVK_ANSI_9
    ]

    private static let functionKeyCodes: Set<Int> = [
        kVK_F1,
        kVK_F2,
        kVK_F3,
        kVK_F4,
        kVK_F5,
        kVK_F6,
        kVK_F7,
        kVK_F8,
        kVK_F9,
        kVK_F10,
        kVK_F11,
        kVK_F12,
        kVK_F13,
        kVK_F14,
        kVK_F15,
        kVK_F16,
        kVK_F17,
        kVK_F18,
        kVK_F19,
        kVK_F20
    ]

    private static func normalizedFlags(_ rawValue: UInt) -> NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: rawValue).intersection(.deviceIndependentFlagsMask)
    }
}
