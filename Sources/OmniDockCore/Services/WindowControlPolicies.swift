import AppKit
import ApplicationServices

enum WindowActivationPolicy {
    static func options(allWindows: Bool) -> NSApplication.ActivationOptions {
        var options: NSApplication.ActivationOptions = [.activateIgnoringOtherApps]
        if allWindows {
            options.insert(.activateAllWindows)
        }
        return options
    }
}

enum ApplicationHidePolicy {
    static func shouldRevealDesktop(
        targetProcessIdentifier: pid_t,
        visibleWindowOwnerProcessIdentifiers: [pid_t]
    ) -> Bool {
        let owners = Set(visibleWindowOwnerProcessIdentifiers)
        return owners == [targetProcessIdentifier]
    }

    static func shouldRetryHide(isHidden: Bool, onscreenNormalWindowCount: Int) -> Bool {
        !isHidden && onscreenNormalWindowCount > 0
    }

    static func isDesktopRevealActive(
        isOwnerRunning: Bool,
        isOwnerHidden: Bool,
        visibleWindowOwnerProcessIdentifiers: [pid_t]
    ) -> Bool {
        isOwnerRunning
            && !isOwnerHidden
            && visibleWindowOwnerProcessIdentifiers.isEmpty
    }
}

enum DesktopRevealResolution: Equatable {
    case none
    case restore
    case switchApplication(previousOwnerProcessIdentifier: pid_t)
}

struct DesktopRevealState {
    private(set) var ownerProcessIdentifier: pid_t?
    private(set) var shortcut: ShowDesktopShortcut?

    mutating func begin(
        for processIdentifier: pid_t,
        shortcut: ShowDesktopShortcut? = nil
    ) {
        ownerProcessIdentifier = processIdentifier
        self.shortcut = shortcut
    }

    mutating func resolve(for processIdentifier: pid_t) -> DesktopRevealResolution {
        guard let ownerProcessIdentifier else {
            return .none
        }
        self.ownerProcessIdentifier = nil
        shortcut = nil
        if ownerProcessIdentifier == processIdentifier {
            return .restore
        }
        return .switchApplication(previousOwnerProcessIdentifier: ownerProcessIdentifier)
    }

    mutating func invalidate() {
        ownerProcessIdentifier = nil
        shortcut = nil
    }
}

struct ShowDesktopShortcut: Equatable {
    let keyCode: CGKeyCode
    let flags: CGEventFlags
}

enum ShowDesktopShortcutResolver {
    #if !APP_STORE
    // com.apple.symbolichotkeys uses identifier 36 for Show Desktop.
    private static let symbolicHotKeyIdentifier = "36"
    private static let preferenceKey = "AppleSymbolicHotKeys" as CFString
    private static let preferenceDomain = "com.apple.symbolichotkeys" as CFString
    #endif

    static func currentShortcut() -> ShowDesktopShortcut? {
        #if APP_STORE
        return nil
        #else
        let preferences = CFPreferencesCopyValue(
            preferenceKey,
            preferenceDomain,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        return shortcut(from: preferences)
        #endif
    }

    static func shortcut(from rawPreferences: Any?) -> ShowDesktopShortcut? {
        guard let preferences = rawPreferences as? [String: Any],
              let entry = preferences["36"] as? [String: Any],
              boolValue(entry["enabled"]) == true,
              let value = entry["value"] as? [String: Any],
              value["type"] as? String == "standard",
              let parameters = value["parameters"] as? [Any],
              parameters.count >= 3,
              let rawKeyCode = unsignedInteger(parameters[1], maximum: UInt64(UInt16.max - 1)),
              let rawFlags = unsignedInteger(parameters[2], maximum: UInt64(UInt32.max))
        else {
            return nil
        }

        let allowedFlags: CGEventFlags = [
            .maskAlphaShift,
            .maskShift,
            .maskControl,
            .maskAlternate,
            .maskCommand,
            .maskNumericPad,
            .maskHelp,
            .maskSecondaryFn
        ]
        guard rawFlags & ~allowedFlags.rawValue == 0 else {
            return nil
        }

        return ShowDesktopShortcut(
            keyCode: CGKeyCode(rawKeyCode),
            flags: CGEventFlags(rawValue: rawFlags)
        )
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        if let bool = value as? Bool {
            return bool
        }
        return (value as? NSNumber)?.boolValue
    }

    private static func unsignedInteger(_ value: Any?, maximum: UInt64) -> UInt64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else {
            return nil
        }

        let doubleValue = number.doubleValue
        guard doubleValue.isFinite,
              doubleValue >= 0,
              doubleValue.rounded(.towardZero) == doubleValue,
              doubleValue <= Double(maximum)
        else {
            return nil
        }
        return number.uint64Value
    }
}

struct WindowCloseCandidate: Equatable {
    let index: Int
    let windowID: CGWindowID?
    let title: String?
}

struct WindowFocusCandidate: Equatable {
    let index: Int
    let windowID: CGWindowID?
    let title: String?
}

enum WindowFocusMatchPolicy {
    static func matchingIndex(
        in candidates: [WindowFocusCandidate],
        title: String?,
        windowID: CGWindowID?
    ) -> Int? {
        if let windowID,
           let exactMatch = candidates.first(where: { $0.windowID == windowID }) {
            return exactMatch.index
        }

        // A nonmatching identifier is stale when the application exposes other
        // identifiers. Falling back in that case can raise a different window.
        if windowID != nil, candidates.contains(where: { $0.windowID != nil }) {
            return nil
        }

        let normalizedTitle = DockTitleMatcher.normalized(title)
        if !normalizedTitle.isEmpty {
            let titleMatches = candidates.filter {
                DockTitleMatcher.normalized($0.title) == normalizedTitle
            }
            if titleMatches.count == 1 {
                return titleMatches[0].index
            }
        }

        return candidates.count == 1 ? candidates[0].index : nil
    }
}

enum WindowCloseMatchPolicy {
    static func matchingIndex(
        in candidates: [WindowCloseCandidate],
        title: String?,
        windowID: CGWindowID?
    ) -> Int? {
        if let windowID,
           let exactMatch = candidates.first(where: { $0.windowID == windowID }) {
            return exactMatch.index
        }

        if windowID != nil, candidates.contains(where: { $0.windowID != nil }) {
            return nil
        }

        let normalizedTitle = DockTitleMatcher.normalized(title)
        if !normalizedTitle.isEmpty {
            let matches = candidates.filter {
                DockTitleMatcher.normalized($0.title) == normalizedTitle
            }
            if matches.count == 1 {
                return matches[0].index
            }
        }

        return candidates.count == 1 ? candidates[0].index : nil
    }
}

struct WindowCloseVerificationTarget: Equatable {
    let windowID: CGWindowID?
    let title: String?
}

enum WindowCloseVerificationDecision: Equatable {
    case success
    case retry
    case failure
}

enum WindowCloseVerificationPolicy {
    static func targetIsPresent(
        _ target: WindowCloseVerificationTarget,
        in candidates: [WindowCloseCandidate]
    ) -> Bool {
        if let windowID = target.windowID {
            return candidates.contains { $0.windowID == windowID }
        }

        let normalizedTitle = DockTitleMatcher.normalized(target.title)
        if !normalizedTitle.isEmpty {
            return candidates.contains {
                DockTitleMatcher.normalized($0.title) == normalizedTitle
            }
        }

        // A title-less target was safe to close only through the single-window
        // fallback, so any remaining normal window is conservatively the target.
        return !candidates.isEmpty
    }

    static func decision(
        querySucceeded: Bool = true,
        targetIsPresent: Bool,
        blockingDialogAppeared: Bool,
        attemptsRemaining: Int
    ) -> WindowCloseVerificationDecision {
        if !querySucceeded {
            return attemptsRemaining > 0 ? .retry : .failure
        }
        if blockingDialogAppeared {
            return .failure
        }
        if !targetIsPresent {
            return .success
        }
        return attemptsRemaining > 0 ? .retry : .failure
    }
}

struct BulkWindowCandidate: Equatable {
    let index: Int
    let windowID: CGWindowID?
    let title: String?
    let frame: CGRect
}

enum BulkWindowDeduplicationPolicy {
    private struct FallbackIdentity: Hashable {
        let title: String
        let frame: WindowFrameKey
    }

    static func uniqueIndices(in candidates: [BulkWindowCandidate]) -> [Int] {
        var seenWindowIDs = Set<CGWindowID>()
        var seenFallbackIdentities = Set<FallbackIdentity>()

        return candidates.compactMap { candidate in
            if let windowID = candidate.windowID {
                return seenWindowIDs.insert(windowID).inserted ? candidate.index : nil
            }

            let title = DockTitleMatcher.normalized(candidate.title)
            guard !title.isEmpty, !candidate.frame.isEmpty else {
                return candidate.index
            }

            let identity = FallbackIdentity(
                title: title,
                frame: WindowFrameKey(candidate.frame)
            )
            return seenFallbackIdentities.insert(identity).inserted ? candidate.index : nil
        }
    }
}

struct NewWindowMenuItemSearchResult {
    let element: AXUIElement
    let match: NewWindowMenuItemMatch
}

enum NewWindowMenuItemMatch: Int, Equatable {
    case preferredTitle = 0
    case commandN = 1
}

enum NewWindowMenuItemPolicy {
    static func match(title: String?, commandCharacter: String?, commandModifiers: Int?) -> NewWindowMenuItemMatch? {
        let normalizedTitle = DockTitleMatcher.normalized(title)
        guard !normalizedTitle.isEmpty,
              !isRejectedTitle(normalizedTitle)
        else {
            return nil
        }

        if isPreferredTitle(normalizedTitle) {
            return .preferredTitle
        }

        let normalizedCommand = commandCharacter?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        if normalizedCommand == "N", commandModifiers == 0 {
            return .commandN
        }

        return nil
    }

    private static func isPreferredTitle(_ title: String) -> Bool {
        if title.contains("new") && title.contains("window") {
            return true
        }

        if title.contains("新建") || title.contains("新增") {
            return title.contains("窗口")
                || title.contains("视窗")
                || title.contains("視窗")
        }

        return false
    }

    private static func isRejectedTitle(_ title: String) -> Bool {
        let rejectedPhrases = [
            "new tab",
            "new folder",
            "tab group",
            "private",
            "incognito",
            "标签",
            "標籤",
            "页签",
            "頁籤",
            "分頁",
            "文件夹",
            "資料夾",
            "资料夹",
            "檔案夾",
            "隐私",
            "隱私",
            "私密",
            "无痕",
            "無痕"
        ]
        return rejectedPhrases.contains { title.contains($0) }
    }
}
