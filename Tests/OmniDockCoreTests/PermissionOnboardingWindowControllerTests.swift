import AppKit
import XCTest
@testable import OmniDockCore

@MainActor
final class PermissionOnboardingWindowControllerTests: XCTestCase {
    func testQueuedRefreshIsRejectedAfterWindowCloses() throws {
        let harness = PermissionOnboardingHarness()
        defer { harness.shutDown() }

        let staleRefresh = try harness.queuePermissionRefresh()
        harness.permissionService.currentSnapshot = .allOnboardingPermissionsGranted

        harness.controller.close()

        XCTAssertTrue(harness.settings.permissionOnboardingSkipped)
        XCTAssertFalse(harness.settings.permissionOnboardingCompleted)
        XCTAssertEqual(harness.callbacks.skippedCount, 1)

        let snapshotCountAfterClose = harness.permissionService.snapshotCount
        staleRefresh()

        XCTAssertEqual(harness.permissionService.snapshotCount, snapshotCountAfterClose)
        XCTAssertEqual(harness.callbacks.completedCount, 0)
        XCTAssertTrue(harness.settings.permissionOnboardingSkipped)
        XCTAssertFalse(harness.settings.permissionOnboardingCompleted)
        XCTAssertFalse(harness.settings.toggleAppVisibilityOnDockClick)
    }

    func testQueuedRefreshIsRejectedAfterChoosingLater() throws {
        let harness = PermissionOnboardingHarness()
        defer { harness.shutDown() }

        let staleRefresh = try harness.queuePermissionRefresh()
        harness.permissionService.currentSnapshot = .allOnboardingPermissionsGranted

        try harness.chooseLater()

        XCTAssertTrue(harness.settings.permissionOnboardingSkipped)
        XCTAssertFalse(harness.settings.permissionOnboardingCompleted)
        XCTAssertEqual(harness.callbacks.skippedCount, 1)

        let snapshotCountAfterSkip = harness.permissionService.snapshotCount
        staleRefresh()

        XCTAssertEqual(harness.permissionService.snapshotCount, snapshotCountAfterSkip)
        XCTAssertEqual(harness.callbacks.completedCount, 0)
        XCTAssertTrue(harness.settings.permissionOnboardingSkipped)
        XCTAssertFalse(harness.settings.permissionOnboardingCompleted)
        XCTAssertFalse(harness.settings.toggleAppVisibilityOnDockClick)
    }

    func testReplacementSessionRejectsOldRefreshAndAcceptsCurrentRefresh() throws {
        let harness = PermissionOnboardingHarness()
        defer { harness.shutDown() }

        let staleRefresh = try harness.queuePermissionRefresh()

        harness.controller.show(
            focus: .accessibility,
            automaticallyOpenSettings: true,
            mode: .initialSetup
        )
        let openSettings = try XCTUnwrap(harness.scheduler.popAction(after: 0.25))
        openSettings()
        let currentRefresh = try XCTUnwrap(harness.scheduler.popAction(after: 0.5))
        harness.permissionService.currentSnapshot = .allOnboardingPermissionsGranted

        let snapshotCountBeforeRefreshes = harness.permissionService.snapshotCount
        staleRefresh()

        XCTAssertEqual(harness.permissionService.snapshotCount, snapshotCountBeforeRefreshes)
        XCTAssertEqual(harness.callbacks.completedCount, 0)

        currentRefresh()

        XCTAssertEqual(harness.permissionService.snapshotCount, snapshotCountBeforeRefreshes + 1)
        XCTAssertEqual(harness.callbacks.completedCount, 1)
        XCTAssertTrue(harness.settings.permissionOnboardingCompleted)
        XCTAssertFalse(harness.settings.permissionOnboardingSkipped)
        XCTAssertTrue(harness.settings.toggleAppVisibilityOnDockClick)
    }

    func testVisibleOnboardingRefreshesLocalizedCopyWhenLanguageChanges() throws {
        let harness = PermissionOnboardingHarness()
        defer {
            harness.settings.appLanguage = .system
            harness.shutDown()
        }

        harness.settings.appLanguage = .en
        harness.controller.show(mode: .review)
        let contentView = try XCTUnwrap(harness.controller.window?.contentView)
        XCTAssertTrue(textValues(in: contentView).contains(
            AppLocalization.text(.onboardingTitle, language: .en)
        ))

        harness.settings.appLanguage = .zhHans
        let updatedValues = textValues(in: contentView)
        XCTAssertTrue(updatedValues.contains(
            AppLocalization.text(.onboardingTitle, language: .zhHans)
        ))
        XCTAssertTrue(updatedValues.contains(
            AppLocalization.text(.onboardingSubtitle, language: .zhHans)
        ))
        XCTAssertTrue(updatedValues.contains(
            AppLocalization.text(.onboardingPrivacyNote, language: .zhHans)
        ))
    }

    private func textValues(in view: NSView) -> [String] {
        var values = (view as? NSTextField).map { [$0.stringValue] } ?? []
        for subview in view.subviews {
            values.append(contentsOf: textValues(in: subview))
        }
        return values
    }
}

@MainActor
private final class PermissionOnboardingHarness {
    let permissionService = PermissionOnboardingPermissionServiceStub()
    let scheduler = PermissionOnboardingDeferredScheduler()
    let callbacks = PermissionOnboardingCallbackRecorder()
    let settings: SettingsStore
    let presentationCoordinator: ApplicationPresentationCoordinator

    lazy var controller = PermissionOnboardingWindowController(
        settings: settings,
        permissionService: permissionService,
        presentationCoordinator: presentationCoordinator,
        onCompleted: { [callbacks] in
            callbacks.completedCount += 1
        },
        onSkipped: { [callbacks] in
            callbacks.skippedCount += 1
        },
        onPermissionStatusChanged: { [callbacks] in
            callbacks.statusChangedCount += 1
        },
        scheduleDeferredAction: { [scheduler] delay, action in
            scheduler.schedule(after: delay, action: action)
        }
    )

    init() {
        _ = NSApplication.shared

        let defaultsName = "OmniDockPermissionOnboardingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defaults.removePersistentDomain(forName: defaultsName)
        settings = SettingsStore(defaults: defaults, livePreviewLimitProvider: { 8 })
        settings.showDockPreviews = false
        settings.liveDockPreviewsEnabled = false
        settings.toggleAppVisibilityOnDockClick = false
        settings.hotkeysEnabled = false

        presentationCoordinator = ApplicationPresentationCoordinator(
            setActivationPolicy: { _ in true },
            activateApplication: {},
            scheduleDeferred: { action in action() }
        )
    }

    func queuePermissionRefresh() throws -> PermissionOnboardingDeferredScheduler.Action {
        controller.show(
            focus: .accessibility,
            automaticallyOpenSettings: true,
            mode: .initialSetup
        )
        let openSettings = try XCTUnwrap(scheduler.popAction(after: 0.25))
        openSettings()
        return try XCTUnwrap(scheduler.popAction(after: 0.5))
    }

    func chooseLater() throws {
        let contentView = try XCTUnwrap(controller.window?.contentView)
        let laterButton = try XCTUnwrap(button(withAction: "skip:", in: contentView))
        laterButton.performClick(nil)
    }

    func shutDown() {
        controller.prepareForApplicationTermination()
        controller.close()
    }

    private func button(withAction actionName: String, in view: NSView) -> NSButton? {
        if let button = view as? NSButton,
           let action = button.action,
           NSStringFromSelector(action) == actionName {
            return button
        }

        for subview in view.subviews {
            if let button = button(withAction: actionName, in: subview) {
                return button
            }
        }
        return nil
    }
}

private final class PermissionOnboardingPermissionServiceStub: PermissionOnboardingPermissionProviding {
    var currentSnapshot: PermissionSnapshot = .missingOnboardingPermissions
    private(set) var snapshotCount = 0
    private(set) var openedPermissions: [PermissionKind] = []

    func snapshot() -> PermissionSnapshot {
        snapshotCount += 1
        return currentSnapshot
    }

    func openPrivacySettings(for kind: PermissionKind) {
        openedPermissions.append(kind)
    }

    func isGranted(_ kind: PermissionKind, in snapshot: PermissionSnapshot) -> Bool {
        switch kind {
        case .accessibility:
            return snapshot.accessibility
        case .screenRecording:
            return snapshot.screenRecording
        case .inputMonitoring:
            return snapshot.inputMonitoring
        }
    }
}

@MainActor
private final class PermissionOnboardingDeferredScheduler {
    typealias Action = @MainActor () -> Void

    private var actions: [(delay: TimeInterval, action: Action)] = []

    func schedule(after delay: TimeInterval, action: @escaping Action) {
        actions.append((delay, action))
    }

    func popAction(after delay: TimeInterval) -> Action? {
        guard let index = actions.firstIndex(where: { $0.delay == delay }) else {
            return nil
        }
        return actions.remove(at: index).action
    }
}

@MainActor
private final class PermissionOnboardingCallbackRecorder {
    var completedCount = 0
    var skippedCount = 0
    var statusChangedCount = 0
}

private extension PermissionSnapshot {
    static let missingOnboardingPermissions = PermissionSnapshot(
        accessibility: false,
        screenRecording: false,
        inputMonitoring: false
    )

    static let allOnboardingPermissionsGranted = PermissionSnapshot(
        accessibility: true,
        screenRecording: true,
        inputMonitoring: true
    )
}
