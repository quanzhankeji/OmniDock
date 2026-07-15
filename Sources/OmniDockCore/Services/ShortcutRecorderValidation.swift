import AppKit
import Carbon.HIToolbox

enum ShortcutRecorderValidation {
    static var regularKeyMinimumModifierMessage: String {
        AppStrings.text(.hotkeyGuidance)
    }

    private static let allowedModifierFlags: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
    private static let modifierOnlyKeyCodes: Set<Int> = [
        kVK_Command,
        kVK_RightCommand,
        kVK_Shift,
        kVK_RightShift,
        kVK_Option,
        kVK_RightOption,
        kVK_Control,
        kVK_RightControl,
        kVK_CapsLock,
        kVK_Function
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

    static func normalizedShortcut(keyCode: Int, modifierFlags: NSEvent.ModifierFlags) -> RecordedShortcut {
        let normalizedFlags = modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .intersection(allowedModifierFlags)
        return RecordedShortcut(keyCode: keyCode, modifierFlags: normalizedFlags.rawValue)
    }

    static func recordingRejectionReason(keyCode: Int, modifierFlags: NSEvent.ModifierFlags) -> String? {
        if modifierOnlyKeyCodes.contains(keyCode) {
            return AppStrings.text(.hotkeyNeedsRegularKey)
        }

        if modifierFlags.contains(.capsLock) {
            return AppStrings.text(.hotkeyCapsLock)
        }

        if modifierFlags.contains(.function), !functionKeyCodes.contains(keyCode) {
            return AppStrings.text(.hotkeyFnUnsupported)
        }

        return minimumModifierRejectionReason(for: normalizedShortcut(
            keyCode: keyCode,
            modifierFlags: modifierFlags
        ))
    }

    static func rejectionReason(
        for shortcut: RecordedShortcut,
        existingBindings: [AppHotkeyBinding] = [],
        excluding excludedID: UUID? = nil,
        systemShortcuts: Set<RecordedShortcut> = SystemHotkeyConflictChecker.enabledSystemShortcuts()
    ) -> String? {
        if let reason = unsupportedStoredModifierRejectionReason(for: shortcut) {
            return reason
        }

        if modifierOnlyKeyCodes.contains(shortcut.keyCode) {
            return AppStrings.text(.hotkeyNeedsRegularKey)
        }

        if let reason = minimumModifierRejectionReason(for: shortcut) {
            return reason
        }

        if let reason = HotkeyShortcutPolicy.rejectionReason(
            for: shortcut,
            systemShortcuts: systemShortcuts
        ) {
            return reason
        }

        if AppHotkeyConflictChecker.containsDuplicate(
            shortcut,
            in: existingBindings,
            excluding: excludedID
        ) {
            return AppStrings.text(.hotkeyDuplicate)
        }

        return nil
    }

    private static func unsupportedStoredModifierRejectionReason(for shortcut: RecordedShortcut) -> String? {
        let flags = NSEvent.ModifierFlags(rawValue: shortcut.modifierFlags)
            .intersection(.deviceIndependentFlagsMask)
        if flags.contains(.capsLock) {
            return AppStrings.text(.hotkeyCapsLock)
        }
        if flags.contains(.function), !functionKeyCodes.contains(shortcut.keyCode) {
            return AppStrings.text(.hotkeyFnUnsupported)
        }
        return nil
    }

    static func minimumModifierRejectionReason(for shortcut: RecordedShortcut) -> String? {
        let flags = NSEvent.ModifierFlags(rawValue: shortcut.modifierFlags)
            .intersection(.deviceIndependentFlagsMask)
        let requiredModifiers = flags.intersection([.command, .control, .option])
        guard !requiredModifiers.isEmpty else {
            return regularKeyMinimumModifierMessage
        }
        return nil
    }
}
