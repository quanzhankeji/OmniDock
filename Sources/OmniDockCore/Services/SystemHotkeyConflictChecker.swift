import AppKit
import Carbon.HIToolbox

public enum SystemHotkeyConflictChecker {
    public static func containsConflict(
        _ shortcut: RecordedShortcut,
        systemShortcuts: Set<RecordedShortcut> = enabledSystemShortcuts()
    ) -> Bool {
        systemShortcuts.contains(normalizedShortcut(shortcut))
    }

    public static func enabledSystemShortcuts() -> Set<RecordedShortcut> {
        var unmanagedArray: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanagedArray) == noErr,
              let array = unmanagedArray?.takeRetainedValue() as? [[String: Any]]
        else {
            return []
        }

        return Set(array.compactMap { item in
            guard isEnabled(item[kHISymbolicHotKeyEnabled as String]),
                  let keyCode = intValue(item[kHISymbolicHotKeyCode as String]),
                  let modifiers = intValue(item[kHISymbolicHotKeyModifiers as String])
            else {
                return nil
            }
            return shortcut(keyCode: keyCode, carbonModifiers: UInt32(modifiers))
        })
    }

    public static func shortcut(keyCode: Int, carbonModifiers: UInt32) -> RecordedShortcut {
        var flags = NSEvent.ModifierFlags()
        if carbonModifiers & UInt32(cmdKey) != 0 {
            flags.insert(.command)
        }
        if carbonModifiers & UInt32(optionKey) != 0 {
            flags.insert(.option)
        }
        if carbonModifiers & UInt32(controlKey) != 0 {
            flags.insert(.control)
        }
        if carbonModifiers & UInt32(shiftKey) != 0 {
            flags.insert(.shift)
        }
        return RecordedShortcut(keyCode: keyCode, modifierFlags: flags.rawValue)
    }

    private static func normalizedShortcut(_ shortcut: RecordedShortcut) -> RecordedShortcut {
        let flags = NSEvent.ModifierFlags(rawValue: shortcut.modifierFlags)
            .intersection(.deviceIndependentFlagsMask)
            .intersection([.command, .control, .option, .shift])
        return RecordedShortcut(keyCode: shortcut.keyCode, modifierFlags: flags.rawValue)
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            return number.intValue
        }
        return value as? Int
    }

    private static func isEnabled(_ value: Any?) -> Bool {
        if let number = value as? NSNumber {
            return number.boolValue
        }
        return value as? Bool ?? false
    }
}
