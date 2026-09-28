import XCTest
@testable import OmniDockCore

final class PermissionFeatureGateTests: XCTestCase {
    func testFeaturePermissionRequirements() {
        XCTAssertEqual(PermissionFeature.dockClick.requiredPermissions, [.accessibility, .inputMonitoring])
        XCTAssertEqual(PermissionFeature.dockPreview.requiredPermissions, [.accessibility])
        XCTAssertEqual(PermissionFeature.windowCycle.requiredPermissions, [.accessibility, .inputMonitoring])
        XCTAssertEqual(PermissionFeature.hotkeys.requiredPermissions, [.accessibility])
        XCTAssertEqual(PermissionFeature.windowPlacement.requiredPermissions, [.accessibility, .inputMonitoring])
        XCTAssertEqual(
            PermissionFeature.finderExtension.requiredPermissions,
            [.finderExtension, .folderAccess]
        )
    }

    func testMissingPermissionsForFeature() {
        let snapshot = PermissionSnapshot(
            accessibility: true,
            screenRecording: false,
            inputMonitoring: false
        )

        XCTAssertEqual(PermissionFeatureGate.missingPermissions(for: .dockClick, in: snapshot), [.inputMonitoring])
        XCTAssertTrue(PermissionFeatureGate.missingPermissions(for: .dockPreview, in: snapshot).isEmpty)
        XCTAssertTrue(PermissionFeatureGate.missingPermissions(for: .hotkeys, in: snapshot).isEmpty)
    }

    func testAllPermissionCombinationsKeepPreferencesAndGateRuntimeIndependently() {
        let store = SettingsStore(defaults: isolatedDefaults(), livePreviewLimitProvider: { 8 })
        for feature in PermissionFeature.allCases { setEnabled(feature, in: store, to: true) }
        store.showCommandTabPreviews = true
        store.liveDockPreviewsEnabled = false
        for bits in 0..<32 {
            let snapshot = PermissionSnapshot(
                accessibility: bits & 1 != 0,
                screenRecording: bits & 2 != 0,
                inputMonitoring: bits & 4 != 0,
                finderExtension: bits & 8 != 0,
                folderAccess: bits & 16 != 0
            )
            for feature in PermissionFeature.allCases {
                let state = PermissionFeatureGate.availability(for: feature, settings: store, snapshot: snapshot)
                XCTAssertEqual(state.canRun, PermissionFeatureGate.isSatisfied(for: feature, in: snapshot))
                if state.canRun, feature == .dockPreview || feature == .windowCycle {
                    XCTAssertEqual(state, snapshot.screenRecording ? .available : .metadataOnly)
                }
            }
            XCTAssertTrue(store.showDockPreviews)
            XCTAssertTrue(store.showCommandTabPreviews)
            XCTAssertTrue(store.windowCycleEnabled)
            XCTAssertTrue(store.toggleAppVisibilityOnDockClick)
            XCTAssertTrue(store.hotkeysEnabled)
            XCTAssertTrue(store.finderExtensionEnabled)
            XCTAssertTrue(store.windowPlacementEnabled)
            XCTAssertFalse(store.liveDockPreviewsEnabled)
        }
    }

    func testUserCanDisableUnavailableFeaturesWithoutReenablingAfterPermissionRestoration() {
        let store = SettingsStore(defaults: isolatedDefaults(), livePreviewLimitProvider: { 8 })
        let denied = PermissionSnapshot(accessibility: false, screenRecording: false, inputMonitoring: false)
        let granted = PermissionSnapshot(
            accessibility: true, screenRecording: true, inputMonitoring: true,
            finderExtension: true, folderAccess: true
        )
        for feature in PermissionFeature.allCases {
            store.showDockPreviews = true
            setEnabled(feature, in: store, to: true)
            XCTAssertFalse(PermissionFeatureGate.availability(for: feature, settings: store, snapshot: denied).canRun)
            setEnabled(feature, in: store, to: false)
            XCTAssertEqual(PermissionFeatureGate.availability(for: feature, settings: store, snapshot: granted), .disabled)
        }
    }

    func testLegacyPendingIntentIsRestoredOnlyOnceWithoutEnablingRelatedOptions() {
        let store = SettingsStore(defaults: isolatedDefaults(), livePreviewLimitProvider: { 8 })
        for feature in PermissionFeature.allCases { setEnabled(feature, in: store, to: false) }
        store.liveDockPreviewsEnabled = false
        store.showCommandTabPreviews = false
        store.pendingPermissionFeatures = Set(PermissionFeature.allCases)

        PermissionFeatureGate.restorePendingPreferences(in: store)

        XCTAssertTrue(store.showDockPreviews)
        XCTAssertTrue(store.windowCycleEnabled)
        XCTAssertTrue(store.toggleAppVisibilityOnDockClick)
        XCTAssertTrue(store.hotkeysEnabled)
        XCTAssertTrue(store.finderExtensionEnabled)
        XCTAssertTrue(store.windowPlacementEnabled)
        XCTAssertFalse(store.liveDockPreviewsEnabled)
        XCTAssertFalse(store.showCommandTabPreviews)
        XCTAssertTrue(store.pendingPermissionFeatures.isEmpty)
        store.showDockPreviews = false
        store.hotkeysEnabled = false
        PermissionFeatureGate.restorePendingPreferences(in: store)
        XCTAssertFalse(store.showDockPreviews)
        XCTAssertFalse(store.hotkeysEnabled)
    }

    func testNoPendingIntentLeavesPreferencesUnchanged() {
        let store = SettingsStore(defaults: isolatedDefaults(), livePreviewLimitProvider: { 8 })
        store.showDockPreviews = false
        store.windowCycleEnabled = true
        PermissionFeatureGate.restorePendingPreferences(in: store)
        XCTAssertFalse(store.showDockPreviews)
        XCTAssertTrue(store.windowCycleEnabled)
    }

    func testAllOnboardingPermissionsGrantedRequiresEveryPermission() {
        XCTAssertTrue(PermissionFeatureGate.allOnboardingPermissionsGranted(in: PermissionSnapshot(
            accessibility: true, screenRecording: true, inputMonitoring: true,
            finderExtension: true, folderAccess: true
        )))
        XCTAssertFalse(PermissionFeatureGate.allOnboardingPermissionsGranted(in: PermissionSnapshot(
            accessibility: true, screenRecording: false, inputMonitoring: true,
            finderExtension: true, folderAccess: true
        )))
    }

    private func setEnabled(_ feature: PermissionFeature, in store: SettingsStore, to enabled: Bool) {
        switch feature {
        case .dockClick: store.toggleAppVisibilityOnDockClick = enabled
        case .dockPreview: store.showDockPreviews = enabled
        case .windowCycle: store.windowCycleEnabled = enabled
        case .hotkeys: store.hotkeysEnabled = enabled
        case .finderExtension: store.finderExtensionEnabled = enabled
        case .windowPlacement: store.windowPlacementEnabled = enabled
        }
    }

    func testPermissionMonitorRecoveryRequiresAnAttachmentFailure() {
        let now = Date(timeIntervalSince1970: 10_000)
        let grantedSnapshot = PermissionSnapshot(
            accessibility: true,
            screenRecording: false,
            inputMonitoring: true
        )
        let missingPermissionSnapshot = PermissionSnapshot(
            accessibility: true,
            screenRecording: false,
            inputMonitoring: false
        )

        XCTAssertTrue(PermissionMonitorRecoveryPolicy.shouldRelaunch(
            isDockClickEnabled: true,
            snapshot: grantedSnapshot,
            isMonitoringActive: false,
            lastRelaunchAttemptAt: nil,
            now: now
        ))
        XCTAssertFalse(PermissionMonitorRecoveryPolicy.shouldRelaunch(
            isDockClickEnabled: false,
            snapshot: grantedSnapshot,
            isMonitoringActive: false,
            lastRelaunchAttemptAt: nil,
            now: now
        ))
        XCTAssertFalse(PermissionMonitorRecoveryPolicy.shouldRelaunch(
            isDockClickEnabled: true,
            snapshot: missingPermissionSnapshot,
            isMonitoringActive: false,
            lastRelaunchAttemptAt: nil,
            now: now
        ))
        XCTAssertFalse(PermissionMonitorRecoveryPolicy.shouldRelaunch(
            isDockClickEnabled: true,
            snapshot: grantedSnapshot,
            isMonitoringActive: true,
            lastRelaunchAttemptAt: nil,
            now: now
        ))
        XCTAssertFalse(PermissionMonitorRecoveryPolicy.shouldRelaunch(
            isDockClickEnabled: true,
            snapshot: grantedSnapshot,
            isMonitoringActive: false,
            isMonitoringSuspended: true,
            lastRelaunchAttemptAt: nil,
            now: now
        ))
    }

    func testPermissionMonitorRecoveryCooldownPreventsRelaunchLoop() {
        let now = Date(timeIntervalSince1970: 10_000)
        let snapshot = PermissionSnapshot(
            accessibility: true,
            screenRecording: false,
            inputMonitoring: true
        )

        XCTAssertFalse(PermissionMonitorRecoveryPolicy.shouldRelaunch(
            isDockClickEnabled: true,
            snapshot: snapshot,
            isMonitoringActive: false,
            lastRelaunchAttemptAt: now.addingTimeInterval(-60),
            now: now
        ))
        XCTAssertTrue(PermissionMonitorRecoveryPolicy.shouldRelaunch(
            isDockClickEnabled: true,
            snapshot: snapshot,
            isMonitoringActive: false,
            lastRelaunchAttemptAt: now.addingTimeInterval(-PermissionMonitorRecoveryPolicy.relaunchCooldown),
            now: now
        ))
    }

    func testReviewOnboardingDoesNotEnableDefaultsOrRecordSkippedState() {
        XCTAssertTrue(PermissionOnboardingMode.initialSetup.enablesFeatureDefaultsOnCompletion)
        XCTAssertTrue(PermissionOnboardingMode.initialSetup.recordsSkippedState)
        XCTAssertFalse(PermissionOnboardingMode.review.enablesFeatureDefaultsOnCompletion)
        XCTAssertFalse(PermissionOnboardingMode.review.recordsSkippedState)
    }

    func testApplicationTerminationDoesNotMarkOnboardingAsSkipped() {
        XCTAssertFalse(PermissionOnboardingClosePolicy.shouldRecordSkipped(
            isProgrammaticClose: false,
            didComplete: false,
            recordsSkippedState: true,
            isApplicationTerminating: true
        ))
        XCTAssertTrue(PermissionOnboardingClosePolicy.shouldRecordSkipped(
            isProgrammaticClose: false,
            didComplete: false,
            recordsSkippedState: true,
            isApplicationTerminating: false
        ))
    }

    private func isolatedDefaults() -> UserDefaults {
        let name = "OmniDockPermissionGateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }
}
