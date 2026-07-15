import Foundation

public struct RecordedShortcut: Codable, Equatable, Hashable {
    public let keyCode: Int
    public let modifierFlags: UInt

    public init(keyCode: Int, modifierFlags: UInt) {
        self.keyCode = keyCode
        self.modifierFlags = modifierFlags
    }
}

public struct AppHotkeyBinding: Codable, Equatable, Identifiable {
    public let id: UUID
    public var appName: String
    public var bundleURLString: String
    public var bundleIdentifier: String?
    public var keyCode: Int?
    public var modifierFlags: UInt?
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        appName: String,
        bundleURLString: String,
        bundleIdentifier: String?,
        keyCode: Int? = nil,
        modifierFlags: UInt? = nil,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.appName = appName
        self.bundleURLString = bundleURLString
        self.bundleIdentifier = bundleIdentifier
        self.keyCode = keyCode
        self.modifierFlags = modifierFlags
        self.isEnabled = isEnabled
    }

    public var recordedShortcut: RecordedShortcut? {
        guard let keyCode, let modifierFlags else {
            return nil
        }
        return RecordedShortcut(keyCode: keyCode, modifierFlags: modifierFlags)
    }

    public var bundleURL: URL? {
        if let url = URL(string: bundleURLString), url.scheme != nil {
            return url
        }
        return URL(fileURLWithPath: bundleURLString)
    }

    public mutating func updateRecordedShortcut(_ shortcut: RecordedShortcut?) {
        keyCode = shortcut?.keyCode
        modifierFlags = shortcut?.modifierFlags
    }
}

public enum AppHotkeyConflictChecker {
    public static func containsDuplicate(
        _ shortcut: RecordedShortcut,
        in bindings: [AppHotkeyBinding],
        excluding excludedID: UUID? = nil
    ) -> Bool {
        bindings.contains { binding in
            binding.id != excludedID
                && binding.isEnabled
                && binding.recordedShortcut == shortcut
        }
    }
}

public enum AppHotkeyDecision: Equatable {
    case launchApplication
    case openApplicationWindow
    case bringApplicationToFront
    case hideApplication
}

public enum AppHotkeyDecisionResolver {
    public static func decision(
        isRunning: Bool,
        isTopmost: Bool,
        isHidden: Bool,
        normalWindowCount: Int? = nil,
        unminimizedNormalWindowCount: Int,
        onscreenNormalWindowCount: Int? = nil
    ) -> AppHotkeyDecision {
        guard isRunning else {
            return .launchApplication
        }

        if normalWindowCount == 0 {
            return .openApplicationWindow
        }

        switch WindowFiltering.dockIconClickAction(
            isTopmost: isTopmost,
            isHidden: isHidden,
            unminimizedNormalWindowCount: unminimizedNormalWindowCount,
            onscreenNormalWindowCount: onscreenNormalWindowCount
        ) {
        case .bringApplicationToFront:
            return .bringApplicationToFront
        case .hideApplication:
            return .hideApplication
        case .minimizeApplicationWindows:
            return .hideApplication
        }
    }
}
