import AppKit
import Carbon.HIToolbox
import XCTest
@testable import OmniDockCore

final class AppHotkeyBindingTests: XCTestCase {
    func testRecordedShortcutDecodesExistingStoredShape() throws {
        let data = Data(#"{"keyCode":45,"modifierFlags":1048576}"#.utf8)
        let shortcut = try JSONDecoder().decode(RecordedShortcut.self, from: data)

        XCTAssertEqual(shortcut.keyCode, 45)
        XCTAssertEqual(shortcut.modifierFlags, 1_048_576)
    }

    func testAppHotkeyBindingDecodesExistingAssignmentShape() throws {
        let id = UUID()
        let data = Data("""
        {
            "id":"\(id.uuidString)",
            "appName":"Notes",
            "bundleURLString":"file:///Applications/Notes.app",
            "bundleIdentifier":"com.apple.Notes",
            "keyCode":45,
            "modifierFlags":1048576,
            "isEnabled":true
        }
        """.utf8)

        let binding = try JSONDecoder().decode(AppHotkeyBinding.self, from: data)

        XCTAssertEqual(binding.id, id)
        XCTAssertEqual(binding.recordedShortcut, RecordedShortcut(keyCode: 45, modifierFlags: 1_048_576))
    }

    func testFormatsShortcutSymbols() {
        let shortcut = RecordedShortcut(
            keyCode: kVK_ANSI_N,
            modifierFlags: flags([.control, .option, .command])
        )

        XCTAssertEqual(ShortcutFormatter.string(for: shortcut), "⌃⌥⌘N")
    }

    func testDetectsDuplicateShortcuts() {
        let first = AppHotkeyBinding(
            appName: "Notes",
            bundleURLString: "file:///Applications/Notes.app",
            bundleIdentifier: "com.apple.Notes",
            keyCode: 45,
            modifierFlags: 1
        )
        let second = AppHotkeyBinding(
            appName: "Safari",
            bundleURLString: "file:///Applications/Safari.app",
            bundleIdentifier: "com.apple.Safari"
        )

        XCTAssertTrue(AppHotkeyConflictChecker.containsDuplicate(
            RecordedShortcut(keyCode: 45, modifierFlags: 1),
            in: [first, second],
            excluding: second.id
        ))
    }

    func testIgnoresDisabledAssignmentsForDuplicateDetection() {
        let disabled = AppHotkeyBinding(
            appName: "Notes",
            bundleURLString: "file:///Applications/Notes.app",
            bundleIdentifier: "com.apple.Notes",
            keyCode: 45,
            modifierFlags: 1,
            isEnabled: false
        )

        XCTAssertFalse(AppHotkeyConflictChecker.containsDuplicate(
            RecordedShortcut(keyCode: 45, modifierFlags: 1),
            in: [disabled]
        ))
    }

    func testRejectsBrowserTabNavigationShortcuts() {
        XCTAssertNotNil(HotkeyShortcutPolicy.rejectionReason(for: RecordedShortcut(
            keyCode: kVK_Tab,
            modifierFlags: flags([.control])
        ), systemShortcuts: []))
        XCTAssertNotNil(HotkeyShortcutPolicy.rejectionReason(for: RecordedShortcut(
            keyCode: kVK_Tab,
            modifierFlags: flags([.control, .shift])
        ), systemShortcuts: []))
        XCTAssertNotNil(HotkeyShortcutPolicy.rejectionReason(for: RecordedShortcut(
            keyCode: kVK_RightArrow,
            modifierFlags: flags([.command, .option])
        ), systemShortcuts: []))
        XCTAssertNotNil(HotkeyShortcutPolicy.rejectionReason(for: RecordedShortcut(
            keyCode: kVK_ANSI_RightBracket,
            modifierFlags: flags([.command, .shift])
        ), systemShortcuts: []))
        XCTAssertNotNil(HotkeyShortcutPolicy.rejectionReason(for: RecordedShortcut(
            keyCode: kVK_ANSI_1,
            modifierFlags: flags([.command])
        ), systemShortcuts: []))
    }

    func testRejectsCommonApplicationMenuShortcuts() {
        XCTAssertNotNil(HotkeyShortcutPolicy.rejectionReason(for: RecordedShortcut(
            keyCode: kVK_ANSI_N,
            modifierFlags: flags([.command])
        ), systemShortcuts: []))
        XCTAssertNotNil(HotkeyShortcutPolicy.rejectionReason(for: RecordedShortcut(
            keyCode: kVK_ANSI_W,
            modifierFlags: flags([.command])
        ), systemShortcuts: []))
        XCTAssertNotNil(HotkeyShortcutPolicy.rejectionReason(for: RecordedShortcut(
            keyCode: kVK_ANSI_O,
            modifierFlags: flags([.command])
        ), systemShortcuts: []))
        XCTAssertNotNil(HotkeyShortcutPolicy.rejectionReason(for: RecordedShortcut(
            keyCode: kVK_ANSI_N,
            modifierFlags: flags([.command, .shift])
        ), systemShortcuts: []))
    }

    func testRejectsSystemShortcutConflicts() {
        let shortcut = RecordedShortcut(
            keyCode: kVK_ANSI_N,
            modifierFlags: flags([.command, .option])
        )

        XCTAssertNotNil(HotkeyShortcutPolicy.rejectionReason(
            for: shortcut,
            systemShortcuts: [shortcut]
        ))
    }

    func testAllowsNonBrowserNavigationShortcut() {
        XCTAssertNil(HotkeyShortcutPolicy.rejectionReason(for: RecordedShortcut(
            keyCode: kVK_ANSI_N,
            modifierFlags: flags([.control, .option, .command])
        ), systemShortcuts: []))
    }

    func testSystemHotkeyConflictCheckerConvertsCarbonModifiers() {
        let shortcut = SystemHotkeyConflictChecker.shortcut(
            keyCode: kVK_ANSI_N,
            carbonModifiers: UInt32(cmdKey | optionKey)
        )

        XCTAssertEqual(shortcut, RecordedShortcut(
            keyCode: kVK_ANSI_N,
            modifierFlags: flags([.command, .option])
        ))
    }

    func testRecorderValidationRejectsBareKey() {
        XCTAssertNotNil(ShortcutRecorderValidation.rejectionReason(for: RecordedShortcut(
            keyCode: kVK_ANSI_N,
            modifierFlags: flags([])
        ), systemShortcuts: []))
    }

    func testRecorderValidationRejectsModifierOnlyKey() {
        XCTAssertNotNil(ShortcutRecorderValidation.recordingRejectionReason(
            keyCode: kVK_Command,
            modifierFlags: [.command]
        ))
    }

    func testRecorderValidationRejectsShiftOnlyShortcut() {
        XCTAssertNotNil(ShortcutRecorderValidation.rejectionReason(for: RecordedShortcut(
            keyCode: kVK_ANSI_N,
            modifierFlags: flags([.shift])
        ), systemShortcuts: []))
    }

    func testRecorderValidationRejectsFunctionModifierOnRegularKey() {
        XCTAssertNotNil(ShortcutRecorderValidation.recordingRejectionReason(
            keyCode: kVK_ANSI_N,
            modifierFlags: [.command, .function]
        ))
    }

    func testRecorderValidationAllowsFunctionKeysAsPrimaryKey() {
        XCTAssertNil(ShortcutRecorderValidation.recordingRejectionReason(
            keyCode: kVK_F1,
            modifierFlags: [.command, .function]
        ))
    }

    func testRecorderValidationRejectsCapsLockState() {
        XCTAssertNotNil(ShortcutRecorderValidation.recordingRejectionReason(
            keyCode: kVK_ANSI_N,
            modifierFlags: [.command, .capsLock]
        ))
    }

    func testRecorderValidationRejectsBrowserTabNavigationShortcut() {
        XCTAssertNotNil(ShortcutRecorderValidation.rejectionReason(for: RecordedShortcut(
            keyCode: kVK_Tab,
            modifierFlags: flags([.control])
        ), systemShortcuts: []))
    }

    func testRecorderValidationRejectsSystemShortcutConflicts() {
        let shortcut = RecordedShortcut(
            keyCode: kVK_ANSI_N,
            modifierFlags: flags([.command, .option])
        )

        XCTAssertNotNil(ShortcutRecorderValidation.rejectionReason(
            for: shortcut,
            systemShortcuts: [shortcut]
        ))
    }

    func testRecorderValidationRejectsDuplicates() {
        let existing = AppHotkeyBinding(
            appName: "Notes",
            bundleURLString: "file:///Applications/Notes.app",
            bundleIdentifier: "com.apple.Notes",
            keyCode: kVK_ANSI_N,
            modifierFlags: flags([.command])
        )

        XCTAssertNotNil(ShortcutRecorderValidation.rejectionReason(
            for: RecordedShortcut(keyCode: kVK_ANSI_N, modifierFlags: flags([.command])),
            existingBindings: [existing],
            systemShortcuts: []
        ))
    }

    func testRecorderValidationAllowsSingleRealModifierForRegularKey() {
        XCTAssertNil(ShortcutRecorderValidation.rejectionReason(for: RecordedShortcut(
            keyCode: kVK_ANSI_P,
            modifierFlags: flags([.option])
        ), systemShortcuts: []))

        XCTAssertNil(ShortcutRecorderValidation.rejectionReason(for: RecordedShortcut(
            keyCode: kVK_ANSI_P,
            modifierFlags: flags([.control])
        ), systemShortcuts: []))
    }

    func testRecorderValidationAllowsMultipleRealModifiersForRegularKey() {
        XCTAssertNil(ShortcutRecorderValidation.rejectionReason(for: RecordedShortcut(
            keyCode: kVK_ANSI_N,
            modifierFlags: flags([.control, .option])
        ), systemShortcuts: []))
    }

    func testHotkeyGuidanceVisibilityFollowsGlobalSwitch() {
        XCTAssertTrue(HotkeyGuidancePresentation.isVisible(hotkeysEnabled: true))
        XCTAssertFalse(HotkeyGuidancePresentation.isVisible(hotkeysEnabled: false))
        XCTAssertEqual(
            HotkeyGuidancePresentation.message,
            ShortcutRecorderValidation.regularKeyMinimumModifierMessage
        )
        XCTAssertTrue(HotkeyGuidancePresentation.message.contains("⌘ Command"))
        XCTAssertTrue(HotkeyGuidancePresentation.message.contains("⌃ Control"))
        XCTAssertTrue(HotkeyGuidancePresentation.message.contains("⌥ Option"))
        XCTAssertTrue(HotkeyGuidancePresentation.message.contains("⇧ Shift"))
    }

    func testRowWarningSuppressesSharedMinimumModifierGuidance() {
        let reason = ShortcutRecorderValidation.rejectionReason(for: RecordedShortcut(
            keyCode: kVK_ANSI_N,
            modifierFlags: flags([.shift])
        ), systemShortcuts: [])

        XCTAssertEqual(reason, ShortcutRecorderValidation.regularKeyMinimumModifierMessage)
        XCTAssertNil(HotkeyRowWarningPresentation.visibleWarning(reason))
    }

    func testRowWarningKeepsSpecificShortcutWarnings() {
        let shortcut = RecordedShortcut(
            keyCode: kVK_ANSI_P,
            modifierFlags: flags([.control, .option])
        )
        let duplicate = AppHotkeyBinding(
            appName: "Notes",
            bundleURLString: "file:///Applications/Notes.app",
            bundleIdentifier: "com.apple.Notes",
            keyCode: shortcut.keyCode,
            modifierFlags: shortcut.modifierFlags
        )

        let duplicateReason = ShortcutRecorderValidation.rejectionReason(
            for: shortcut,
            existingBindings: [duplicate],
            systemShortcuts: []
        )
        let systemReason = ShortcutRecorderValidation.rejectionReason(
            for: shortcut,
            systemShortcuts: [shortcut]
        )
        let registrationReason = AppStrings.text(.hotkeyRegistrationOccupied)

        XCTAssertEqual(HotkeyRowWarningPresentation.visibleWarning(duplicateReason), duplicateReason)
        XCTAssertEqual(HotkeyRowWarningPresentation.visibleWarning(systemReason), systemReason)
        XCTAssertEqual(HotkeyRowWarningPresentation.visibleWarning(registrationReason), registrationReason)
    }

    @MainActor
    func testRegistrationFailureUsesOccupiedMessageForExistingHotkeyStatus() {
        let failure = CarbonHotkeyRegistry.RegistrationFailure(
            binding: AppHotkeyBinding(
                appName: "Notes",
                bundleURLString: "file:///Applications/Notes.app",
                bundleIdentifier: "com.apple.Notes"
            ),
            status: OSStatus(eventHotKeyExistsErr)
        )

        XCTAssertEqual(failure.message, AppStrings.text(.hotkeyRegistrationOccupied))
    }

    @MainActor
    func testRegistrationStatusStoreStoresAndClearsWarnings() {
        let id = UUID()
        let store = AppHotkeyRegistrationStatusStore()

        store.replaceWarnings([id: "冲突"])
        XCTAssertEqual(store.warning(for: id), "冲突")

        store.clearWarning(for: id)
        XCTAssertNil(store.warning(for: id))
    }

    @MainActor
    func testCarbonModifierFlagMapping() {
        let shortcut = RecordedShortcut(
            keyCode: kVK_ANSI_N,
            modifierFlags: flags([.command, .option, .control, .shift])
        )

        XCTAssertEqual(
            CarbonHotkeyRegistry.carbonModifierFlags(for: shortcut.modifierFlags),
            UInt32(cmdKey | optionKey | controlKey | shiftKey)
        )
    }

    func testHotkeyLaunchesWhenAppIsNotRunning() {
        XCTAssertEqual(
            AppHotkeyDecisionResolver.decision(
                isRunning: false,
                isTopmost: false,
                isHidden: false,
                unminimizedNormalWindowCount: 0
            ),
            .launchApplication
        )
    }

    func testHotkeyLaunchDecisionWinsWhenSavedAppIsNotRunning() {
        let binding = AppHotkeyBinding(
            appName: "Finder",
            bundleURLString: "file:///System/Library/CoreServices/Finder.app",
            bundleIdentifier: "com.apple.finder",
            keyCode: kVK_ANSI_F,
            modifierFlags: flags([.option])
        )

        XCTAssertNotNil(binding.bundleURL)
        XCTAssertEqual(
            AppHotkeyDecisionResolver.decision(
                isRunning: false,
                isTopmost: true,
                isHidden: false,
                unminimizedNormalWindowCount: 2,
                onscreenNormalWindowCount: 2
            ),
            .launchApplication
        )
    }

    func testHotkeyBringsForwardBackgroundApp() {
        XCTAssertEqual(
            AppHotkeyDecisionResolver.decision(
                isRunning: true,
                isTopmost: false,
                isHidden: false,
                unminimizedNormalWindowCount: 1
            ),
            .bringApplicationToFront
        )
    }

    func testHotkeyOpensWindowForRunningAppWithoutNormalWindows() {
        XCTAssertEqual(
            AppHotkeyDecisionResolver.decision(
                isRunning: true,
                isTopmost: true,
                isHidden: false,
                normalWindowCount: 0,
                unminimizedNormalWindowCount: 0,
                onscreenNormalWindowCount: 0
            ),
            .openApplicationWindow
        )
    }

    func testHotkeyRestoresMinimizedWindowWithoutCreatingNewWindow() {
        XCTAssertEqual(
            AppHotkeyDecisionResolver.decision(
                isRunning: true,
                isTopmost: false,
                isHidden: false,
                normalWindowCount: 1,
                unminimizedNormalWindowCount: 0,
                onscreenNormalWindowCount: 0
            ),
            .bringApplicationToFront
        )
    }

    func testHotkeyBringsForwardHiddenApp() {
        XCTAssertEqual(
            AppHotkeyDecisionResolver.decision(
                isRunning: true,
                isTopmost: true,
                isHidden: true,
                unminimizedNormalWindowCount: 1
            ),
            .bringApplicationToFront
        )
    }

    func testHotkeyHidesTopmostVisibleApp() {
        XCTAssertEqual(
            AppHotkeyDecisionResolver.decision(
                isRunning: true,
                isTopmost: true,
                isHidden: false,
                unminimizedNormalWindowCount: 1
            ),
            .hideApplication
        )
    }

    func testNewWindowMenuPolicyPrefersExplicitWindowTitles() {
        XCTAssertEqual(
            NewWindowMenuItemPolicy.match(title: "New Window", commandCharacter: nil, commandModifiers: nil),
            .preferredTitle
        )
        XCTAssertEqual(
            NewWindowMenuItemPolicy.match(title: "New Finder Window", commandCharacter: nil, commandModifiers: nil),
            .preferredTitle
        )
        XCTAssertEqual(
            NewWindowMenuItemPolicy.match(title: "新建窗口", commandCharacter: nil, commandModifiers: nil),
            .preferredTitle
        )
    }

    func testNewWindowMenuPolicyUsesSafeCommandNAsFallback() {
        XCTAssertEqual(
            NewWindowMenuItemPolicy.match(title: "New Document", commandCharacter: "n", commandModifiers: 0),
            .commandN
        )
        XCTAssertNil(NewWindowMenuItemPolicy.match(title: "Open", commandCharacter: "O", commandModifiers: 0))
    }

    func testNewWindowMenuPolicyRejectsUnsafeNewMenuItems() {
        XCTAssertNil(NewWindowMenuItemPolicy.match(title: "New Tab", commandCharacter: "T", commandModifiers: 0))
        XCTAssertNil(NewWindowMenuItemPolicy.match(title: "New Folder", commandCharacter: "N", commandModifiers: 0))
        XCTAssertNil(NewWindowMenuItemPolicy.match(title: "New Private Window", commandCharacter: "N", commandModifiers: 0))
        XCTAssertNil(NewWindowMenuItemPolicy.match(title: "新建标签页", commandCharacter: "T", commandModifiers: 0))
        XCTAssertNil(NewWindowMenuItemPolicy.match(title: "新建文件夹", commandCharacter: "N", commandModifiers: 0))
    }

    private func flags(_ flags: NSEvent.ModifierFlags) -> UInt {
        flags.rawValue
    }
}
