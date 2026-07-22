import Carbon.HIToolbox
import XCTest
@testable import OmniDockCore

@MainActor
final class WindowCycleTests: XCTestCase {
    func testSettingsDefaultAndPersistenceKeepWindowCycleDisabled() {
        let defaults = isolatedDefaults()
        let store = SettingsStore(defaults: defaults, livePreviewLimitProvider: { 8 })

        XCTAssertFalse(store.windowCycleEnabled)

        store.windowCycleEnabled = true

        let reloaded = SettingsStore(defaults: defaults, livePreviewLimitProvider: { 8 })
        XCTAssertTrue(reloaded.windowCycleEnabled)
    }

    func testWindowCycleReadsExistingStoredPreference() {
        let defaults = isolatedDefaults()
        defaults.set(true, forKey: "independentWindowSwitcherEnabled")

        let store = SettingsStore(defaults: defaults, livePreviewLimitProvider: { 8 })

        XCTAssertTrue(store.windowCycleEnabled)
    }

    func testForwardSessionStartsWithPreviousApplicationWindow() throws {
        let session = WindowCycleSession(
            windows: [window(id: 1, processIdentifier: 101), window(id: 2, processIdentifier: 202)],
            frontmostProcessIdentifier: 101,
            initialDirection: .forward
        )

        XCTAssertEqual(try XCTUnwrap(session.selectedWindow).windowID, 2)
    }

    func testForwardSessionOnlySkipsTheCurrentWindowNotEveryWindowFromItsApplication() throws {
        let currentWindow = window(id: 1, processIdentifier: 101)
        let session = WindowCycleSession(
            windows: [
                currentWindow,
                window(id: 2, processIdentifier: 101),
                window(id: 3, processIdentifier: 202)
            ],
            frontmostProcessIdentifier: 101,
            frontmostWindowIdentity: PreviewWindowIdentity(currentWindow),
            initialDirection: .forward
        )

        XCTAssertEqual(try XCTUnwrap(session.selectedWindow).windowID, 2)
    }

    func testForwardBackwardAndWrapMaintainWindowLevelSelection() throws {
        var session = WindowCycleSession(
            windows: [window(id: 1, processIdentifier: 101), window(id: 2, processIdentifier: 202), window(id: 3, processIdentifier: 202)],
            frontmostProcessIdentifier: 101,
            initialDirection: .forward
        )

        XCTAssertEqual(try XCTUnwrap(session.selectedWindow).windowID, 2)
        session.advance(.forward)
        XCTAssertEqual(try XCTUnwrap(session.selectedWindow).windowID, 3)
        session.advance(.forward)
        XCTAssertEqual(try XCTUnwrap(session.selectedWindow).windowID, 1)
        session.advance(.backward)
        XCTAssertEqual(try XCTUnwrap(session.selectedWindow).windowID, 3)
    }

    func testCapturePriorityIsLimitedToTheSelectedWindowAndItsNeighbors() {
        let session = WindowCycleSession(
            windows: [
                window(id: 1, processIdentifier: 101),
                window(id: 2, processIdentifier: 202),
                window(id: 3, processIdentifier: 303),
                window(id: 4, processIdentifier: 404),
                window(id: 5, processIdentifier: 505)
            ],
            frontmostProcessIdentifier: 101,
            initialDirection: .forward
        )

        XCTAssertEqual(session.capturePriorityWindows.compactMap(\.windowID), [2, 3, 1])
    }

    func testStaticCaptureQueuePrioritizesSelectionThenIncludesEveryWindow() {
        let session = WindowCycleSession(
            windows: [
                window(id: 1, processIdentifier: 101),
                window(id: 2, processIdentifier: 202),
                window(id: 3, processIdentifier: 303),
                window(id: 4, processIdentifier: 404),
                window(id: 5, processIdentifier: 505)
            ],
            frontmostProcessIdentifier: 101,
            initialDirection: .forward
        )

        XCTAssertEqual(session.staticCaptureWindows.compactMap(\.windowID), [2, 3, 1, 4, 5])
    }

    func testUnavailableStaticCaptureDoesNotBlockTheRemainingQueue() {
        let requested: Set<PreviewWindowIdentity> = [
            .window(processIdentifier: 101, windowID: 1),
            .window(processIdentifier: 202, windowID: 2),
            .window(processIdentifier: 303, windowID: 3)
        ]
        let available: Set<PreviewWindowIdentity> = [
            .window(processIdentifier: 101, windowID: 1)
        ]

        XCTAssertEqual(
            StaticPreviewCaptureAvailabilityPolicy.unavailableIdentities(
                requested: requested,
                available: available
            ),
            [
                .window(processIdentifier: 202, windowID: 2),
                .window(processIdentifier: 303, windowID: 3)
            ]
        )
    }

    func testRemovingWindowKeepsSelectionAtAStableValidIndex() throws {
        var session = WindowCycleSession(
            windows: [window(id: 1, processIdentifier: 101), window(id: 2, processIdentifier: 202), window(id: 3, processIdentifier: 303)],
            frontmostProcessIdentifier: 101,
            initialDirection: .forward
        )

        XCTAssertTrue(session.remove(.window(processIdentifier: 202, windowID: 2)))
        XCTAssertEqual(try XCTUnwrap(session.selectedWindow).windowID, 3)
        XCTAssertTrue(session.remove(processIdentifier: 303))
        XCTAssertEqual(try XCTUnwrap(session.selectedWindow).windowID, 1)
        XCTAssertTrue(session.remove(processIdentifier: 101))
        XCTAssertNil(session.selectedWindow)
    }

    func testReconcilingInventoryKeepsTheSelectedWindowWhenItStillExists() throws {
        var session = WindowCycleSession(
            windows: [
                window(id: 1, processIdentifier: 101),
                window(id: 2, processIdentifier: 202),
                window(id: 3, processIdentifier: 303)
            ],
            frontmostProcessIdentifier: 101,
            initialDirection: .forward
        )

        XCTAssertEqual(try XCTUnwrap(session.selectedWindow).windowID, 2)
        session.replaceWindows([
            window(id: 3, processIdentifier: 303),
            window(id: 2, processIdentifier: 202),
            window(id: 4, processIdentifier: 404)
        ])

        XCTAssertEqual(try XCTUnwrap(session.selectedWindow).windowID, 2)
    }

    func testReconcilingInventoryKeepsAValidSelectionWhenTheSelectedWindowClosed() throws {
        var session = WindowCycleSession(
            windows: [
                window(id: 1, processIdentifier: 101),
                window(id: 2, processIdentifier: 202),
                window(id: 3, processIdentifier: 303)
            ],
            frontmostProcessIdentifier: 101,
            initialDirection: .forward
        )

        session.replaceWindows([
            window(id: 1, processIdentifier: 101),
            window(id: 3, processIdentifier: 303)
        ])

        XCTAssertEqual(try XCTUnwrap(session.selectedWindow).windowID, 3)
    }

    func testRegistrationPolicyRequiresSwitchPreviewsAndEveryRequiredPermission() {
        let granted = PermissionSnapshot(accessibility: true, screenRecording: true, inputMonitoring: true)
        let missingInputMonitoring = PermissionSnapshot(accessibility: true, screenRecording: true, inputMonitoring: false)

        XCTAssertTrue(WindowCycleRegistrationPolicy.shouldRegister(
            isStarted: true,
            isEnabled: true,
            arePreviewsEnabled: true,
            permissions: granted
        ))
        XCTAssertFalse(WindowCycleRegistrationPolicy.shouldRegister(
            isStarted: true,
            isEnabled: false,
            arePreviewsEnabled: true,
            permissions: granted
        ))
        XCTAssertFalse(WindowCycleRegistrationPolicy.shouldRegister(
            isStarted: true,
            isEnabled: true,
            arePreviewsEnabled: false,
            permissions: granted
        ))
        XCTAssertFalse(WindowCycleRegistrationPolicy.shouldRegister(
            isStarted: true,
            isEnabled: true,
            arePreviewsEnabled: true,
            permissions: missingInputMonitoring
        ))
        XCTAssertEqual(
            PermissionFeature.windowCycle.requiredPermissions,
            [.accessibility, .screenRecording, .inputMonitoring]
        )
    }

    func testDisablingSwitcherUnregistersAndLeavesNoActiveSessionOrMonitor() {
        let settings = configuredSettings()
        let registry = TestHotkeyRegistry()
        let service = makeService(settings: settings, registry: registry)

        service.start()
        XCTAssertTrue(service.isHotkeyRegistered)
        XCTAssertEqual(registry.registerCallCount, 1)

        settings.windowCycleEnabled = false

        XCTAssertFalse(service.isHotkeyRegistered)
        XCTAssertFalse(service.isSessionActive)
        XCTAssertFalse(service.isInputMonitoring)
        XCTAssertEqual(registry.unregisterCallCount, 1)
        service.stop()
    }

    func testRegistrationFailureRollsBackSwitchAndReportsWarning() throws {
        let settings = configuredSettings()
        let registry = TestHotkeyRegistry(registerStatus: OSStatus(eventHotKeyExistsErr))
        let status = WindowCycleRegistrationStatusStore()
        let service = makeService(settings: settings, registry: registry, status: status)

        service.start()

        XCTAssertFalse(settings.windowCycleEnabled)
        XCTAssertFalse(service.isHotkeyRegistered)
        XCTAssertFalse(service.isInputMonitoring)
        XCTAssertNotNil(status.warning)
        XCTAssertGreaterThanOrEqual(registry.unregisterCallCount, 1)
        service.stop()
    }

    func testPreviewTabAndAltTabSettingAreLocalized() {
        XCTAssertEqual(AppLocalization.text(.tabPreview, language: .en), "Preview")
        XCTAssertEqual(AppLocalization.text(.tabPreview, language: .zhHans), "预览")
        XCTAssertEqual(AppLocalization.text(.settingsWindowCycleTitle, language: .en), "Alt-Tab Preview")
        XCTAssertEqual(AppLocalization.text(.settingsWindowCycleTitle, language: .zhHans), "Alt Tab 预览")
    }

    func testWindowCycleSuppressesDockHoverWhileItsSharedPanelIsActive() {
        XCTAssertTrue(DockPreviewHoverSuppressionPolicy.shouldSuspend(
            commandTabPreviewIsActive: false,
            windowCycleIsActive: true
        ))
        XCTAssertTrue(DockPreviewHoverSuppressionPolicy.shouldSuspend(
            commandTabPreviewIsActive: true,
            windowCycleIsActive: false
        ))
        XCTAssertFalse(DockPreviewHoverSuppressionPolicy.shouldSuspend(
            commandTabPreviewIsActive: false,
            windowCycleIsActive: false
        ))
    }

    private func configuredSettings() -> SettingsStore {
        let store = SettingsStore(defaults: isolatedDefaults(), livePreviewLimitProvider: { 8 })
        store.showDockPreviews = true
        store.windowCycleEnabled = true
        return store
    }

    private func makeService(
        settings: SettingsStore,
        registry: TestHotkeyRegistry,
        status: WindowCycleRegistrationStatusStore? = nil
    ) -> WindowCycleService {
        let windowInventory = WindowInventoryService()
        let previewService = ScreenCapturePreviewService(windowInventory: windowInventory)
        let windowControlService = WindowControlService()
        return WindowCycleService(
            settings: settings,
            permissionService: PermissionService(),
            windowInventory: windowInventory,
            windowControlService: windowControlService,
            previewService: previewService,
            previewPanelController: PreviewPanelController(windowControlService: windowControlService),
            registrationStatus: status ?? WindowCycleRegistrationStatusStore(),
            hotkeyRegistry: registry,
            permissionSnapshotProvider: {
                PermissionSnapshot(accessibility: true, screenRecording: true, inputMonitoring: true)
            }
        )
    }

    private func window(id: CGWindowID, processIdentifier: pid_t) -> PreviewWindowInfo {
        PreviewWindowInfo(
            id: "window-\(id)",
            windowID: id,
            processIdentifier: processIdentifier,
            appName: "Example",
            title: "Window \(id)",
            frame: CGRect(x: 0, y: 0, width: 800, height: 500),
            isMinimized: false
        )
    }

    private func isolatedDefaults() -> UserDefaults {
        let name = "OmniDockWindowCycleTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }
}

@MainActor
private final class TestHotkeyRegistry: WindowCycleHotkeyRegistering {
    var onTrigger: ((WindowCycleDirection) -> Void)?
    private(set) var isRegistered = false
    private(set) var registerCallCount = 0
    private(set) var unregisterCallCount = 0
    private let registerStatus: OSStatus?

    init(registerStatus: OSStatus? = nil) {
        self.registerStatus = registerStatus
    }

    func register() -> OSStatus? {
        registerCallCount += 1
        if let registerStatus {
            return registerStatus
        }
        isRegistered = true
        return nil
    }

    func unregister() {
        unregisterCallCount += 1
        isRegistered = false
    }
}
