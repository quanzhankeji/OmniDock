import XCTest
@testable import OmniDockCore

final class PermissionFeatureGateTests: XCTestCase {
    func testFeaturePermissionRequirements() {
        XCTAssertEqual(PermissionFeature.dockClick.requiredPermissions, [.accessibility, .inputMonitoring])
        XCTAssertEqual(PermissionFeature.dockPreview.requiredPermissions, [.accessibility, .screenRecording])
        XCTAssertEqual(PermissionFeature.hotkeys.requiredPermissions, [.accessibility])
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
        XCTAssertEqual(PermissionFeatureGate.missingPermissions(for: .dockPreview, in: snapshot), [.screenRecording])
        XCTAssertTrue(PermissionFeatureGate.missingPermissions(for: .hotkeys, in: snapshot).isEmpty)
    }

    func testDisableUnavailableFeaturesTurnsOffOnlyMissingPermissionFeatures() {
        let defaults = isolatedDefaults()
        let store = SettingsStore(defaults: defaults, livePreviewLimitProvider: { 8 })
        let snapshot = PermissionSnapshot(
            accessibility: true,
            screenRecording: false,
            inputMonitoring: true
        )

        let disabled = PermissionFeatureGate.disableUnavailableFeatures(in: store, snapshot: snapshot)

        XCTAssertEqual(disabled, [.dockPreview])
        XCTAssertTrue(store.toggleAppVisibilityOnDockClick)
        XCTAssertFalse(store.showDockPreviews)
        XCTAssertFalse(store.liveDockPreviewsEnabled)
        XCTAssertTrue(store.hotkeysEnabled)
    }

    func testAllOnboardingPermissionsGrantedRequiresEveryPermission() {
        XCTAssertTrue(PermissionFeatureGate.allOnboardingPermissionsGranted(in: PermissionSnapshot(
            accessibility: true,
            screenRecording: true,
            inputMonitoring: true,
            finderExtension: true,
            folderAccess: true
        )))

        XCTAssertFalse(PermissionFeatureGate.allOnboardingPermissionsGranted(in: PermissionSnapshot(
            accessibility: true,
            screenRecording: true,
            inputMonitoring: false,
            finderExtension: true,
            folderAccess: true
        )))
    }

    func testRequestedFeatureTurnsOnAfterItsPermissionsAreGranted() {
        let defaults = isolatedDefaults()
        let store = SettingsStore(defaults: defaults, livePreviewLimitProvider: { 8 })
        store.toggleAppVisibilityOnDockClick = false
        store.hotkeysEnabled = false

        var queue = PermissionFeatureActivationQueue()
        queue.request(.dockClick)
        queue.request(.hotkeys)

        let firstEnabled = queue.resolve(
            in: store,
            snapshot: PermissionSnapshot(
                accessibility: true,
                screenRecording: false,
                inputMonitoring: false
            )
        )

        XCTAssertEqual(firstEnabled, [.hotkeys])
        XCTAssertTrue(store.hotkeysEnabled)
        XCTAssertFalse(store.toggleAppVisibilityOnDockClick)
        XCTAssertEqual(queue.pendingFeatures, [.dockClick])

        let secondEnabled = queue.resolve(
            in: store,
            snapshot: PermissionSnapshot(
                accessibility: true,
                screenRecording: false,
                inputMonitoring: true
            )
        )

        XCTAssertEqual(secondEnabled, [.dockClick])
        XCTAssertTrue(store.toggleAppVisibilityOnDockClick)
        XCTAssertTrue(queue.pendingFeatures.isEmpty)
    }

    func testPermissionRefreshDoesNotEnableFeaturesWithoutExplicitRequests() {
        let defaults = isolatedDefaults()
        let store = SettingsStore(defaults: defaults, livePreviewLimitProvider: { 8 })
        store.showDockPreviews = false
        store.liveDockPreviewsEnabled = false
        store.toggleAppVisibilityOnDockClick = false
        store.hotkeysEnabled = false

        var queue = PermissionFeatureActivationQueue()
        let enabled = queue.resolve(
            in: store,
            snapshot: PermissionSnapshot(
                accessibility: true,
                screenRecording: true,
                inputMonitoring: true
            )
        )

        XCTAssertTrue(enabled.isEmpty)
        XCTAssertTrue(queue.pendingFeatures.isEmpty)
        XCTAssertFalse(store.showDockPreviews)
        XCTAssertFalse(store.liveDockPreviewsEnabled)
        XCTAssertFalse(store.toggleAppVisibilityOnDockClick)
        XCTAssertFalse(store.hotkeysEnabled)
    }

    func testRequestedPreviewRestoresParentAndLivePreviewSwitches() {
        let defaults = isolatedDefaults()
        let store = SettingsStore(defaults: defaults, livePreviewLimitProvider: { 8 })
        store.showDockPreviews = false
        store.liveDockPreviewsEnabled = false

        var queue = PermissionFeatureActivationQueue()
        queue.request(.dockPreview)

        let enabled = queue.resolve(
            in: store,
            snapshot: PermissionSnapshot(
                accessibility: true,
                screenRecording: true,
                inputMonitoring: false
            )
        )

        XCTAssertEqual(enabled, [.dockPreview])
        XCTAssertTrue(store.showDockPreviews)
        XCTAssertTrue(store.liveDockPreviewsEnabled)
    }

    func testFinderExtensionEnablesOnlyAfterEveryRequiredPermissionIsReady() {
        let defaults = isolatedDefaults()
        let store = SettingsStore(defaults: defaults, livePreviewLimitProvider: { 8 })
        var queue = PermissionFeatureActivationQueue()
        queue.request(.finderExtension)

        let pending = queue.resolve(
            in: store,
            snapshot: PermissionSnapshot(
                accessibility: true,
                screenRecording: true,
                inputMonitoring: true,
                finderExtension: true,
                folderAccess: false
            )
        )
        XCTAssertTrue(pending.isEmpty)
        XCTAssertFalse(store.finderExtensionEnabled)

        let enabled = queue.resolve(
            in: store,
            snapshot: PermissionSnapshot(
                accessibility: false,
                screenRecording: true,
                inputMonitoring: true,
                finderExtension: true,
                folderAccess: true
            )
        )
        XCTAssertEqual(enabled, [.finderExtension])
        XCTAssertTrue(store.finderExtensionEnabled)
    }

    func testActivationQueueRestoresPendingFeaturesAfterRelaunch() {
        let defaults = isolatedDefaults()
        let store = SettingsStore(defaults: defaults, livePreviewLimitProvider: { 8 })
        store.toggleAppVisibilityOnDockClick = false

        var queue = PermissionFeatureActivationQueue(pendingFeatures: [.dockClick])
        let enabled = queue.resolve(
            in: store,
            snapshot: PermissionSnapshot(
                accessibility: true,
                screenRecording: false,
                inputMonitoring: true
            )
        )

        XCTAssertEqual(enabled, [.dockClick])
        XCTAssertTrue(store.toggleAppVisibilityOnDockClick)
        XCTAssertTrue(queue.pendingFeatures.isEmpty)
    }

    func testActivationQueuePreservesTemporarilyUnavailableFeatureIntent() {
        let defaults = isolatedDefaults()
        let store = SettingsStore(defaults: defaults, livePreviewLimitProvider: { 8 })
        store.showDockPreviews = false
        store.liveDockPreviewsEnabled = false
        store.toggleAppVisibilityOnDockClick = false
        store.hotkeysEnabled = false
        store.finderExtensionEnabled = true

        let unavailableSnapshot = PermissionSnapshot(
            accessibility: false,
            screenRecording: false,
            inputMonitoring: true,
            finderExtension: false,
            folderAccess: true
        )
        let disabled = PermissionFeatureGate.disableUnavailableFeatures(
            in: store,
            snapshot: unavailableSnapshot
        )

        var queue = PermissionFeatureActivationQueue()
        queue.preserveIntent(for: disabled)

        XCTAssertFalse(store.finderExtensionEnabled)
        XCTAssertEqual(queue.pendingFeatures, [.finderExtension])

        let restored = queue.resolve(
            in: store,
            snapshot: PermissionSnapshot(
                accessibility: false,
                screenRecording: false,
                inputMonitoring: true,
                finderExtension: true,
                folderAccess: true
            )
        )

        XCTAssertEqual(restored, [.finderExtension])
        XCTAssertTrue(store.finderExtensionEnabled)
        XCTAssertTrue(queue.pendingFeatures.isEmpty)
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
