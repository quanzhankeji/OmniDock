import XCTest
@testable import OmniDockCore

final class SettingsStoreTests: XCTestCase {
    func testDefaultsAreEnabled() {
        let defaults = isolatedDefaults()
        let store = SettingsStore(defaults: defaults, livePreviewLimitProvider: { 8 })

        XCTAssertTrue(store.showDockPreviews)
        XCTAssertTrue(store.liveDockPreviewsEnabled)
        XCTAssertEqual(store.livePreviewWindowLimit, 6)
        XCTAssertEqual(store.livePreviewWindowLimitMaximum, 8)
        XCTAssertTrue(store.toggleAppVisibilityOnDockClick)
        XCTAssertFalse(store.minimizeWindowsOnDockClickInsteadOfHide)
        XCTAssertTrue(store.hotkeysEnabled)
        XCTAssertEqual(store.appLanguage, .system)
        XCTAssertFalse(store.permissionOnboardingCompleted)
        XCTAssertFalse(store.permissionOnboardingSkipped)
        XCTAssertTrue(store.pendingPermissionFeatures.isEmpty)
        XCTAssertNil(store.lastPermissionRefreshRelaunchAttemptAt)
        XCTAssertTrue(store.appHotkeyBindings.isEmpty)
    }

    func testPersistsToggleValues() {
        let defaults = isolatedDefaults()
        let store = SettingsStore(defaults: defaults, livePreviewLimitProvider: { 8 })

        store.showDockPreviews = false
        store.liveDockPreviewsEnabled = false
        store.livePreviewWindowLimit = 4
        store.toggleAppVisibilityOnDockClick = false
        store.minimizeWindowsOnDockClickInsteadOfHide = true
        store.hotkeysEnabled = false
        store.appLanguage = .en
        store.permissionOnboardingCompleted = true
        store.permissionOnboardingSkipped = true
        store.pendingPermissionFeatures = [.dockClick, .dockPreview]
        let relaunchDate = Date(timeIntervalSince1970: 1_700_000_000)
        store.lastPermissionRefreshRelaunchAttemptAt = relaunchDate
        store.appHotkeyBindings = [
            AppHotkeyBinding(
                appName: "Notes",
                bundleURLString: "file:///Applications/Notes.app",
                bundleIdentifier: "com.apple.Notes",
                keyCode: 45,
                modifierFlags: 1_048_576
            )
        ]

        let reloaded = SettingsStore(defaults: defaults, livePreviewLimitProvider: { 8 })
        XCTAssertFalse(reloaded.showDockPreviews)
        XCTAssertFalse(reloaded.liveDockPreviewsEnabled)
        XCTAssertEqual(reloaded.livePreviewWindowLimit, 4)
        XCTAssertFalse(reloaded.toggleAppVisibilityOnDockClick)
        XCTAssertTrue(reloaded.minimizeWindowsOnDockClickInsteadOfHide)
        XCTAssertFalse(reloaded.hotkeysEnabled)
        XCTAssertEqual(reloaded.appLanguage, .en)
        XCTAssertTrue(reloaded.permissionOnboardingCompleted)
        XCTAssertTrue(reloaded.permissionOnboardingSkipped)
        XCTAssertEqual(reloaded.pendingPermissionFeatures, [.dockClick, .dockPreview])
        XCTAssertEqual(reloaded.lastPermissionRefreshRelaunchAttemptAt, relaunchDate)
        XCTAssertEqual(reloaded.appHotkeyBindings.count, 1)
        XCTAssertEqual(reloaded.appHotkeyBindings.first?.appName, "Notes")
        XCTAssertEqual(reloaded.appHotkeyBindings.first?.recordedShortcut, RecordedShortcut(keyCode: 45, modifierFlags: 1_048_576))
    }

    func testMigratesLegacyMinimizePreference() {
        let defaults = isolatedDefaults()
        defaults.set(false, forKey: "minimizeOnRepeatedDockClick")

        let store = SettingsStore(defaults: defaults)

        XCTAssertFalse(store.toggleAppVisibilityOnDockClick)
    }

    func testNewDockClickPreferenceWinsOverLegacyValue() {
        let defaults = isolatedDefaults()
        defaults.set(false, forKey: "minimizeOnRepeatedDockClick")
        defaults.set(true, forKey: "toggleAppVisibilityOnDockClick")

        let store = SettingsStore(defaults: defaults)

        XCTAssertTrue(store.toggleAppVisibilityOnDockClick)
    }

    func testLivePreviewWindowLimitUsesDeviceMaximum() {
        let defaults = isolatedDefaults()
        let store = SettingsStore(defaults: defaults, livePreviewLimitProvider: { 3 })

        XCTAssertEqual(store.livePreviewWindowLimit, 3)

        store.livePreviewWindowLimit = 20
        XCTAssertEqual(store.livePreviewWindowLimit, 3)

        store.livePreviewWindowLimit = -2
        XCTAssertEqual(store.livePreviewWindowLimit, 0)
    }

    func testEnablesPermissionBackedDefaultsAfterOnboarding() {
        let defaults = isolatedDefaults()
        let store = SettingsStore(defaults: defaults, livePreviewLimitProvider: { 8 })

        store.showDockPreviews = false
        store.liveDockPreviewsEnabled = false
        store.toggleAppVisibilityOnDockClick = false
        store.hotkeysEnabled = false
        store.permissionOnboardingSkipped = true

        store.enablePermissionBackedDefaultsAfterOnboarding()

        XCTAssertTrue(store.showDockPreviews)
        XCTAssertTrue(store.liveDockPreviewsEnabled)
        XCTAssertTrue(store.toggleAppVisibilityOnDockClick)
        XCTAssertTrue(store.hotkeysEnabled)
        XCTAssertTrue(store.permissionOnboardingCompleted)
        XCTAssertFalse(store.permissionOnboardingSkipped)
    }

    private func isolatedDefaults() -> UserDefaults {
        let name = "OmniDockTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }
}
