import Carbon.HIToolbox
import XCTest
@testable import OmniDockCore

@MainActor
final class WindowCycleTests: XCTestCase {
    func testTitleChangeWithUnnumberedAXWindowPreservesSelectedWindowForConfirmation() async {
        _ = NSApplication.shared
        let pid = pid_t.max
        let original = window(id: 1, processIdentifier: pid)
        var current = [original]
        var surfaces = [original]
        let inventory = WindowInventoryService(
            accessibilityWindowsProvider: { processIdentifier, _ in processIdentifier == pid ? current : nil },
            windowServerWindowsProvider: { [pid: surfaces] }
        )
        let registry = TestHotkeyRegistry()
        let input = TestWindowCycleInputMonitor()
        var focused: (pid_t, String?, CGWindowID?)?
        let panel = PreviewPanelController(
            requestWindowFocus: { window, completion in
                focused = (window.processIdentifier, window.title, window.windowID)
                completion(.focused)
            },
            requestWindowClose: { _, _, _, _ in }
        )
        let service = makeService(
            settings: configuredSettings(), registry: registry, panel: panel, inventory: inventory,
            inputMonitor: input,
            permissions: { PermissionSnapshot(accessibility: true, screenRecording: false, inputMonitoring: true) }
        )
        service.start()
        defer { service.stop(); inventory.stop(); panel.hide() }
        await drainMainQueue()
        seedWindows([original], in: inventory)
        let initialLoad = expectation(description: "Initial delayed reconciliation completed")
        let initialObserver = inventory.observeChanges { event in
            if case let .seed(processIdentifier, _, _) = event, processIdentifier == pid { initialLoad.fulfill() }
        }
        registry.onTrigger?(.forward)
        XCTAssertEqual(panel.displayedWindowCount, 1)
        await fulfillment(of: [initialLoad], timeout: 1)
        inventory.removeChangeObserver(initialObserver)
        await drainMainQueue()
        func renamed(number: CGWindowID?) -> PreviewWindowInfo {
            PreviewWindowInfo(id: "renamed", windowID: number, processIdentifier: pid,
                              appName: original.appName, title: "Renamed document", frame: original.frame, isMinimized: false)
        }
        current = [renamed(number: nil)]
        surfaces = [renamed(number: 1)]
        let refreshed = expectation(description: "Renamed selection reconciled")
        inventory.observeChanges { event in
            if case let .seed(processIdentifier, _, records) = event, processIdentifier == pid,
               records.contains(where: { $0.makePreviewWindowInfo().title == "Renamed document" }) {
                refreshed.fulfill()
            }
        }
        inventory.invalidate(processIdentifier: pid, reason: .titleChanged)
        await fulfillment(of: [refreshed], timeout: 1)
        await drainMainQueue()
        XCTAssertEqual(panel.displayedWindowCount, 1)
        input.onEvent?(.confirm)
        XCTAssertEqual(focused?.0, original.processIdentifier)
        XCTAssertEqual(focused?.1, "Renamed document")
        XCTAssertEqual(focused?.2, original.windowID)
    }

    func testNewlyLaunchedApplicationJoinsAnOpenSwitcher() async {
        _ = NSApplication.shared
        let application = NSRunningApplication.current
        let center = NotificationCenter()
        let original = window(id: 1, processIdentifier: pid_t.max)
        let launchedWindow = window(id: 2, processIdentifier: application.processIdentifier)
        var launchedWindows: [PreviewWindowInfo] = []
        let inventory = WindowInventoryService(
            workspaceNotificationCenter: center,
            accessibilityWindowsProvider: { pid, _ in
                pid == application.processIdentifier ? launchedWindows : nil
            }, windowServerWindowsProvider: { [:] }
        )
        inventory.start()
        let registry = TestHotkeyRegistry()
        let monitor = TestWindowCycleInputMonitor()
        let panel = PreviewPanelController(requestWindowFocus: { _, _ in }, requestWindowClose: { _, _, _, _ in })
        let service = makeService(
            settings: configuredSettings(), registry: registry, panel: panel, inventory: inventory,
            inputMonitor: monitor,
            permissions: { PermissionSnapshot(accessibility: true, screenRecording: false, inputMonitoring: true) }
        )
        service.start()
        defer { service.stop(); inventory.stop(); panel.hide() }
        await drainMainQueue()
        seedWindows([original], in: inventory)
        registry.onTrigger?(.forward)
        XCTAssertEqual(panel.displayedWindowCount, 1)
        launchedWindows = [launchedWindow]
        center.post(name: NSWorkspace.didLaunchApplicationNotification, object: nil,
                    userInfo: [NSWorkspace.applicationUserInfoKey: application])
        await drainMainQueue()
        await drainMainQueue()
        XCTAssertTrue(service.isSessionActive)
        XCTAssertEqual(panel.displayedWindowCount, 2)

        launchedWindows = []
        center.post(name: NSWorkspace.didTerminateApplicationNotification, object: nil,
                    userInfo: [NSWorkspace.applicationUserInfoKey: application])
        await drainMainQueue()
        XCTAssertTrue(service.isSessionActive)
        XCTAssertEqual(panel.displayedWindowCount, 1)
    }

    func testCreatedAndDestroyedWindowsRefreshOnlyTheirApplicationAndPreserveSelection() async {
        _ = NSApplication.shared
        let processIdentifier = pid_t.max
        let first = window(id: 1, processIdentifier: processIdentifier)
        let selected = window(id: 2, processIdentifier: processIdentifier)
        let newWindow = window(id: 3, processIdentifier: processIdentifier, originX: 40)
        let other = window(id: 4, processIdentifier: processIdentifier - 1)
        var currentWindows = [first, selected]
        var reads: [pid_t] = []
        let inventory = WindowInventoryService(
            accessibilityWindowsProvider: { pid, _ in
                reads.append(pid)
                return pid == processIdentifier ? currentWindows : nil
            }, windowServerWindowsProvider: { [:] }
        )
        let registry = TestHotkeyRegistry()
        let monitor = TestWindowCycleInputMonitor()
        var focusedIDs: [CGWindowID] = []
        let panel = PreviewPanelController(
            requestWindowFocus: { window, completion in
                if let windowID = window.windowID { focusedIDs.append(windowID) }
                completion(.focused)
            }, requestWindowClose: { _, _, _, _ in }
        )
        let service = makeService(
            settings: configuredSettings(), registry: registry, panel: panel, inventory: inventory,
            inputMonitor: monitor,
            permissions: { PermissionSnapshot(accessibility: true, screenRecording: false, inputMonitoring: true) }
        )
        service.start()
        defer { service.stop(); inventory.stop(); panel.hide() }
        await drainMainQueue()
        seedWindows([first, selected, other], in: inventory)
        registry.onTrigger?(.backward)
        XCTAssertEqual(panel.displayedWindowCount, 3)
        reads.removeAll()
        currentWindows = [selected, newWindow]
        inventory.invalidate(processIdentifier: processIdentifier, reason: .created)
        inventory.invalidate(processIdentifier: processIdentifier, reason: .destroyed)
        await drainMainQueue()

        XCTAssertEqual(reads, [processIdentifier], "A notification burst should read only one application's AX windows")
        XCTAssertEqual(panel.displayedWindowCount, 3)
        XCTAssertEqual(inventory.windows(for: processIdentifier).compactMap(\.identity.windowID), [2, 3])
        monitor.onEvent?(.confirm)
        XCTAssertEqual(focusedIDs, [2], "An unaffected selected window must remain selected")
    }

    func testConfirmedLastWindowCloseEndsSwitcherButFailedReadKeepsItOpen() async {
        _ = NSApplication.shared
        let processIdentifier = pid_t.max
        let original = window(id: 1, processIdentifier: processIdentifier)
        var currentWindows: [PreviewWindowInfo]? = [original]
        var reads = 0
        let inventory = WindowInventoryService(
            accessibilityWindowsProvider: { pid, _ in
                guard pid == processIdentifier else { return nil }
                reads += 1
                return currentWindows
            }, windowServerWindowsProvider: { [:] }
        )
        let registry = TestHotkeyRegistry()
        let monitor = TestWindowCycleInputMonitor()
        let panel = PreviewPanelController(
            requestWindowFocus: { _, _ in XCTFail("Window removal must not confirm a selection") },
            requestWindowClose: { _, _, _, _ in }
        )
        let service = makeService(
            settings: configuredSettings(), registry: registry, panel: panel, inventory: inventory,
            inputMonitor: monitor,
            permissions: { PermissionSnapshot(accessibility: true, screenRecording: false, inputMonitoring: true) }
        )
        service.start()
        defer { service.stop(); inventory.stop(); panel.hide() }
        await drainMainQueue()
        seedWindows([original], in: inventory)
        registry.onTrigger?(.forward)
        reads = 0
        currentWindows = nil
        inventory.invalidate(processIdentifier: processIdentifier, reason: .destroyed)
        await drainMainQueue()
        XCTAssertEqual(reads, 1)
        XCTAssertTrue(service.isSessionActive)
        XCTAssertEqual(panel.displayedWindowCount, 1)

        currentWindows = []
        inventory.invalidate(processIdentifier: processIdentifier, reason: .destroyed)
        await drainMainQueue()
        XCTAssertFalse(service.isSessionActive)
        XCTAssertFalse(service.isInputMonitoring)
        XCTAssertNil(panel.frame)
        XCTAssertTrue(service.isHotkeyRegistered)
    }

    func testCancelledSessionDoesNotProcessQueuedWindowCreation() async {
        _ = NSApplication.shared
        let processIdentifier = pid_t.max
        var currentWindows = [window(id: 1, processIdentifier: processIdentifier)]
        var reads = 0
        let inventory = WindowInventoryService(
            accessibilityWindowsProvider: { pid, _ in
                guard pid == processIdentifier else { return nil }
                reads += 1
                return currentWindows
            }, windowServerWindowsProvider: { [:] }
        )
        let settings = configuredSettings()
        let registry = TestHotkeyRegistry()
        let monitor = TestWindowCycleInputMonitor()
        let panel = PreviewPanelController(
            requestWindowFocus: { _, _ in XCTFail("Cancelled refresh must not focus a window") },
            requestWindowClose: { _, _, _, _ in }
        )
        let service = makeService(
            settings: settings, registry: registry, panel: panel, inventory: inventory, inputMonitor: monitor,
            permissions: { PermissionSnapshot(accessibility: true, screenRecording: false, inputMonitoring: true) }
        )
        service.start()
        defer { service.stop(); inventory.stop(); panel.hide() }
        await drainMainQueue()
        seedWindows(currentWindows, in: inventory)
        registry.onTrigger?(.forward)
        reads = 0
        currentWindows.append(window(id: 2, processIdentifier: processIdentifier))
        inventory.invalidate(processIdentifier: processIdentifier, reason: .created)
        settings.windowCycleEnabled = false
        await drainMainQueue()
        XCTAssertEqual(reads, 0)
        XCTAssertFalse(service.isSessionActive)
        XCTAssertFalse(service.isInputMonitoring)
        XCTAssertNil(panel.frame)
    }

    func testDisplayChangeCancelsSelectionWithoutUnregisteringOrFocusing() {
        let applicationCenter = NotificationCenter()
        let settings = configuredSettings()
        let registry = TestHotkeyRegistry()
        let monitor = TestWindowCycleInputMonitor()
        let inventory = WindowInventoryService()
        let panel = PreviewPanelController(
            requestWindowFocus: { _, _ in XCTFail("Display changes must not confirm a selection") },
            requestWindowClose: { _, _, _, _ in }
        )
        let service = makeService(
            settings: settings, registry: registry, panel: panel, inventory: inventory,
            inputMonitor: monitor, applicationNotificationCenter: applicationCenter,
            permissions: { PermissionSnapshot(accessibility: true, screenRecording: false, inputMonitoring: true) }
        )
        service.start()
        defer { service.stop(); panel.hide() }
        seedKeyboardWindows(in: inventory)
        registry.onTrigger?(.forward)
        XCTAssertTrue(service.isSessionActive)

        applicationCenter.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)

        XCTAssertFalse(service.isSessionActive)
        XCTAssertFalse(service.isInputMonitoring)
        XCTAssertNil(panel.frame)
        XCTAssertTrue(service.isHotkeyRegistered)
        XCTAssertTrue(settings.windowCycleEnabled)
        monitor.onEvent?(.confirm)
        seedKeyboardWindows(in: inventory)
        registry.onTrigger?(.forward)
        XCTAssertTrue(service.isSessionActive)
    }

    func testDisplayChangeWhileAwaitingInventoryRejectsDelayedPresentation() async {
        let applicationCenter = NotificationCenter()
        let registry = TestHotkeyRegistry()
        let monitor = TestWindowCycleInputMonitor()
        let inventory = WindowInventoryService()
        let panel = PreviewPanelController(
            requestWindowFocus: { _, _ in XCTFail("Stale inventory must not focus a window") },
            requestWindowClose: { _, _, _, _ in }
        )
        let service = makeService(
            settings: configuredSettings(), registry: registry, panel: panel, inventory: inventory,
            inputMonitor: monitor, applicationNotificationCenter: applicationCenter,
            permissions: { PermissionSnapshot(accessibility: true, screenRecording: false, inputMonitoring: true) }
        )
        service.start()
        defer { service.stop(); panel.hide() }
        registry.onTrigger?(.forward)
        XCTAssertTrue(service.isInputMonitoring)
        applicationCenter.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        seedKeyboardWindows(in: inventory)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(service.isInputMonitoring)
        XCTAssertFalse(service.isSessionActive)
        XCTAssertNil(panel.frame)
    }

    func testWorkspaceResumeRespectsDisabledSettingsAndRevokedPermissions() {
        for disableSetting in [true, false] {
            let settings = configuredSettings()
            let registry = TestHotkeyRegistry()
            let center = NotificationCenter()
            let applicationCenter = NotificationCenter()
            var permissions = PermissionSnapshot(accessibility: true, screenRecording: false, inputMonitoring: true)
            let service = makeService(settings: settings, registry: registry,
                                      workspaceNotificationCenter: center, applicationNotificationCenter: applicationCenter,
                                      permissions: { permissions })
            service.start()
            defer { service.stop() }
            center.post(name: NSWorkspace.willSleepNotification, object: nil)
            center.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
            if disableSetting {
                settings.windowCycleEnabled = false
            } else {
                permissions = PermissionSnapshot(accessibility: true, screenRecording: false, inputMonitoring: false)
                NotificationCenter.default.post(name: PermissionService.changedNotification, object: nil)
            }
            center.post(name: NSWorkspace.didWakeNotification, object: nil)
            applicationCenter.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
            XCTAssertFalse(service.isHotkeyRegistered)
            center.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
            applicationCenter.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
            XCTAssertFalse(service.isHotkeyRegistered)
            XCTAssertEqual(settings.windowCycleEnabled, !disableSetting)
            registry.onTrigger?(.forward)
            XCTAssertFalse(service.isSessionActive)
            XCTAssertFalse(service.isInputMonitoring)
            service.stop()
            let registrations = registry.registerCallCount
            center.post(name: NSWorkspace.willSleepNotification, object: nil)
            center.post(name: NSWorkspace.didWakeNotification, object: nil)
            XCTAssertEqual(registry.registerCallCount, registrations)
        }
    }

    func testSleepWhileAwaitingInventoryPreventsDelayedPresentation() async {
        let settings = configuredSettings()
        let registry = TestHotkeyRegistry()
        let monitor = TestWindowCycleInputMonitor()
        let center = NotificationCenter()
        let inventory = WindowInventoryService()
        let panel = PreviewPanelController(
            requestWindowFocus: { _, _ in XCTFail("Cancelled inventory must not focus a window") },
            requestWindowClose: { _, _, _, _ in }
        )
        let service = makeService(
            settings: settings, registry: registry, panel: panel, inventory: inventory,
            inputMonitor: monitor, workspaceNotificationCenter: center,
            permissions: { PermissionSnapshot(accessibility: true, screenRecording: false, inputMonitoring: true) }
        )
        service.start()
        defer { service.stop(); panel.hide() }
        registry.onTrigger?(.forward)
        XCTAssertTrue(service.isInputMonitoring)
        XCTAssertFalse(service.isSessionActive)
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        seedKeyboardWindows(in: inventory)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(service.isInputMonitoring)
        XCTAssertFalse(service.isSessionActive)
        XCTAssertEqual(panel.displayedWindowCount, 0)
    }

    func testWorkspaceSleepCancelsAndWakeDoesNotRestoreSelection() {
        let settings = configuredSettings()
        let registry = TestHotkeyRegistry()
        let monitor = TestWindowCycleInputMonitor()
        let center = NotificationCenter()
        let inventory = WindowInventoryService()
        let panel = PreviewPanelController(
            requestWindowFocus: { _, _ in XCTFail("Sleep must cancel, not confirm the selection") },
            requestWindowClose: { _, _, _, _ in }
        )
        let service = makeService(
            settings: settings, registry: registry, panel: panel, inventory: inventory,
            inputMonitor: monitor, workspaceNotificationCenter: center,
            permissions: { PermissionSnapshot(accessibility: true, screenRecording: false, inputMonitoring: true) }
        )
        defer { service.stop(); panel.hide() }
        service.start()
        seedKeyboardWindows(in: inventory)
        registry.onTrigger?(.forward)
        XCTAssertTrue(service.isSessionActive)

        center.post(name: NSWorkspace.willSleepNotification, object: nil)

        XCTAssertFalse(service.isSessionActive)
        XCTAssertFalse(service.isInputMonitoring)
        XCTAssertFalse(service.isHotkeyRegistered)
        XCTAssertEqual(panel.displayedWindowCount, 0)
        XCTAssertTrue(settings.windowCycleEnabled)
        service.refreshRegistration()
        registry.onTrigger?(.forward)
        monitor.onEvent?(.confirm)
        XCTAssertFalse(service.isHotkeyRegistered)
        XCTAssertFalse(service.isSessionActive)

        center.post(name: NSWorkspace.didWakeNotification, object: nil)

        XCTAssertTrue(service.isHotkeyRegistered)
        XCTAssertFalse(service.isSessionActive)
        XCTAssertFalse(service.isInputMonitoring)
        XCTAssertEqual(panel.displayedWindowCount, 0)
        seedKeyboardWindows(in: inventory)
        registry.onTrigger?(.forward)
        XCTAssertTrue(service.isSessionActive)
    }

    func testCancellationDisablingAndPermissionLossNeverFocusAWindow() {
        for exit in 0..<3 {
            let settings = configuredSettings()
            let registry = TestHotkeyRegistry()
            let monitor = TestWindowCycleInputMonitor()
            let inventory = WindowInventoryService()
            var permissions = PermissionSnapshot(accessibility: true, screenRecording: false, inputMonitoring: true)
            let panel = PreviewPanelController(
                requestWindowFocus: { _, _ in XCTFail("Cancelling must not focus a window") },
                requestWindowClose: { _, _, _, _ in }
            )
            let service = makeService(
                settings: settings, registry: registry, panel: panel, inventory: inventory, inputMonitor: monitor,
                permissions: { permissions }
            )
            defer { service.stop(); panel.hide() }
            service.start()
            seedKeyboardWindows(in: inventory)
            registry.onTrigger?(.forward)
            XCTAssertTrue(service.isSessionActive)
            monitor.onEvent?(.move(.down))
            switch exit {
            case 0: monitor.onEvent?(.cancel)
            case 1: settings.windowCycleEnabled = false
            default:
                permissions = PermissionSnapshot(accessibility: true, screenRecording: false, inputMonitoring: false)
                NotificationCenter.default.post(name: PermissionService.changedNotification, object: nil)
            }
            XCTAssertFalse(service.isSessionActive)
            XCTAssertFalse(service.isInputMonitoring)
            XCTAssertEqual(panel.displayedWindowCount, 0)
            monitor.onEvent?(.confirm)
        }
    }

    func testArrowNavigationStaysValidForEmptyShortAndSingleColumnGrids() {
        for count in 0...20 {
            let windows = (0..<count).map { window(id: CGWindowID($0 + 1), processIdentifier: 101) }
            for columns in 1...7 {
                var session = WindowCycleSession(windows: windows, frontmostProcessIdentifier: nil, initialDirection: .forward)
                for direction in [WindowCycleNavigation.down, .right, .up, .left] {
                    for _ in 0...count {
                        session.move(direction, columnCount: columns)
                        if windows.isEmpty {
                            XCTAssertNil(session.selectedWindow)
                        } else {
                            XCTAssertTrue(windows.indices.contains(session.selectedIndex))
                        }
                    }
                }
            }
        }
    }

    func testKeyboardNavigationConfirmsTheSelectedWindowAndTearsDownTheSession() {
        let settings = configuredSettings()
        let registry = TestHotkeyRegistry()
        let monitor = TestWindowCycleInputMonitor()
        let inventory = WindowInventoryService()
        var focusedIDs: [CGWindowID] = []
        let panel = PreviewPanelController(
            requestWindowFocus: { window, completion in
                if let windowID = window.windowID { focusedIDs.append(windowID) }
                completion(.focused)
            }, requestWindowClose: { _, _, _, _ in }
        )
        let service = makeService(
            settings: settings, registry: registry, panel: panel, inventory: inventory, inputMonitor: monitor,
            permissions: { PermissionSnapshot(accessibility: true, screenRecording: false, inputMonitoring: true) }
        )
        defer { service.stop(); panel.hide() }
        service.start()
        seedKeyboardWindows(in: inventory)
        registry.onTrigger?(.forward)
        XCTAssertTrue(service.isSessionActive)
        XCTAssertTrue(service.isInputMonitoring)
        let columns = panel.windowCycleColumnCount
        XCTAssertGreaterThan(columns, 1)

        monitor.onEvent?(.move(.down))
        monitor.onEvent?(.move(.right))
        monitor.onEvent?(.confirm)

        XCTAssertEqual(focusedIDs, [CGWindowID(columns + 2)])
        XCTAssertFalse(service.isSessionActive)
        XCTAssertFalse(service.isInputMonitoring)
        XCTAssertEqual(panel.displayedWindowCount, 0)
        monitor.onEvent?(.confirm)
        XCTAssertEqual(focusedIDs.count, 1)
    }

    func testArrowNavigationUsesGridRowsAndStopsAtEdges() {
        var session = WindowCycleSession(
            windows: (1...8).map { window(id: CGWindowID($0), processIdentifier: 101) },
            frontmostProcessIdentifier: nil, initialDirection: .forward
        )
        session.move(.right, columnCount: 3)
        XCTAssertEqual(session.selectedIndex, 1)
        session.move(.down, columnCount: 3)
        XCTAssertEqual(session.selectedIndex, 4)
        session.move(.right, columnCount: 3)
        XCTAssertEqual(session.selectedIndex, 5)
        session.move(.right, columnCount: 3)
        XCTAssertEqual(session.selectedIndex, 5)
        session.move(.down, columnCount: 3)
        XCTAssertEqual(session.selectedIndex, 7)
        session.move(.down, columnCount: 3)
        XCTAssertEqual(session.selectedIndex, 7)
        session.move(.up, columnCount: 3)
        XCTAssertEqual(session.selectedIndex, 4)
        session.move(.left, columnCount: 3)
        session.move(.left, columnCount: 3)
        XCTAssertEqual(session.selectedIndex, 3)
        session.move(.up, columnCount: 3)
        session.move(.up, columnCount: 3)
        XCTAssertEqual(session.selectedIndex, 0)
        session.advance(.backward)
        XCTAssertEqual(session.selectedIndex, 7, "Tab continues to wrap even though arrows stop at edges")
    }

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
            [.accessibility, .inputMonitoring]
        )
        XCTAssertTrue(WindowCycleRegistrationPolicy.shouldRegister(
            isStarted: true, isEnabled: true, arePreviewsEnabled: true,
            permissions: PermissionSnapshot(accessibility: true, screenRecording: false, inputMonitoring: true)
        ))
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

    func testRegistrationFailurePreservesSwitchAndReportsWarning() throws {
        let settings = configuredSettings()
        let registry = TestHotkeyRegistry(registerStatus: OSStatus(eventHotKeyExistsErr))
        let status = WindowCycleRegistrationStatusStore()
        let service = makeService(settings: settings, registry: registry, status: status)

        service.start()

        XCTAssertTrue(settings.windowCycleEnabled)
        XCTAssertFalse(service.isHotkeyRegistered)
        XCTAssertFalse(service.isInputMonitoring)
        XCTAssertNotNil(status.warning)
        XCTAssertGreaterThanOrEqual(registry.unregisterCallCount, 1)
        service.stop()
    }

    func testPermissionNotificationsSuspendAndResumeRegistrationWithoutChangingPreference() {
        let settings = configuredSettings()
        let registry = TestHotkeyRegistry()
        var permissions = PermissionSnapshot(accessibility: true, screenRecording: false, inputMonitoring: true)
        let service = makeService(settings: settings, registry: registry, permissions: { permissions })
        service.start()
        XCTAssertTrue(service.isHotkeyRegistered)

        permissions = PermissionSnapshot(accessibility: true, screenRecording: false, inputMonitoring: false)
        NotificationCenter.default.post(name: PermissionService.changedNotification, object: nil)
        XCTAssertFalse(service.isHotkeyRegistered)
        XCTAssertFalse(service.isSessionActive)
        XCTAssertFalse(service.isInputMonitoring)
        XCTAssertTrue(settings.windowCycleEnabled)

        permissions = PermissionSnapshot(accessibility: true, screenRecording: false, inputMonitoring: true)
        NotificationCenter.default.post(name: PermissionService.changedNotification, object: nil)
        XCTAssertTrue(service.isHotkeyRegistered)
        XCTAssertTrue(settings.windowCycleEnabled)

        permissions = PermissionSnapshot(accessibility: false, screenRecording: false, inputMonitoring: true)
        NotificationCenter.default.post(name: PermissionService.changedNotification, object: nil)
        settings.windowCycleEnabled = false
        permissions = PermissionSnapshot(accessibility: true, screenRecording: true, inputMonitoring: true)
        NotificationCenter.default.post(name: PermissionService.changedNotification, object: nil)
        XCTAssertFalse(service.isHotkeyRegistered)
        XCTAssertFalse(settings.windowCycleEnabled)
        service.stop()
    }

    func testInactiveSwitcherPermissionRefreshDoesNotDismissAnotherPreview() {
        let settings = configuredSettings()
        settings.windowCycleEnabled = false
        let panel = PreviewPanelController(
            requestWindowFocus: { _, _ in }, requestWindowClose: { _, _, _, _ in }
        )
        let service = makeService(settings: settings, registry: TestHotkeyRegistry(), panel: panel)
        service.start()
        defer { service.stop(); panel.hide() }
        let target = DockAppTarget(
            processIdentifier: 101, bundleIdentifier: "com.example.App", localizedName: "Example",
            dockElementTitle: "Example", hitPoint: .zero, previewAnchorKind: .commandTab
        )
        panel.show(target: target, windows: [window(id: 1, processIdentifier: 101)], message: nil)

        NotificationCenter.default.post(name: PermissionService.changedNotification, object: nil)

        XCTAssertEqual(panel.displayedWindowCount, 1)
        XCTAssertTrue(panel.hasInstalledContentView)
    }

    func testPreviewTabAndAltTabSettingAreLocalized() {
        XCTAssertEqual(
            LocalizedResourceCatalog.text(.tabPreview, language: .en),
            "Window Preview"
        )
        XCTAssertEqual(
            LocalizedResourceCatalog.text(.tabPreview, language: .zhHans),
            "窗口预览"
        )
        XCTAssertEqual(LocalizedResourceCatalog.text(.settingsWindowCycleTitle, language: .en), "Alt-Tab Preview")
        XCTAssertEqual(LocalizedResourceCatalog.text(.settingsWindowCycleTitle, language: .zhHans), "Alt Tab 预览")
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

    private func drainMainQueue() async {
        let drained = expectation(description: "Queued window lifecycle updates delivered")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 1)
    }

    private func seedWindows(_ windows: [PreviewWindowInfo], in inventory: WindowInventoryService) {
        for (processIdentifier, windows) in Dictionary(grouping: windows, by: \.processIdentifier) {
            let target = DockAppTarget(processIdentifier: processIdentifier, bundleIdentifier: nil,
                                       localizedName: "Example", dockElementTitle: "Example", hitPoint: .zero)
            inventory.seed(PreviewWindowSnapshot(windows: windows, captureWindows: [:]), for: target)
        }
    }

    private func makeService(
        settings: SettingsStore,
        registry: TestHotkeyRegistry,
        status: WindowCycleRegistrationStatusStore? = nil,
        panel: PreviewPanelController? = nil,
        inventory: WindowInventoryService? = nil,
        inputMonitor: WindowCycleInputMonitoring? = nil,
        workspaceNotificationCenter: NotificationCenter = NotificationCenter(),
        applicationNotificationCenter: NotificationCenter = NotificationCenter(),
        permissions: @escaping () -> PermissionSnapshot = {
            PermissionSnapshot(accessibility: true, screenRecording: true, inputMonitoring: true)
        }
    ) -> WindowCycleService {
        let windowInventory = inventory ?? WindowInventoryService()
        let previewService = ScreenCapturePreviewService(windowInventory: windowInventory)
        let windowControlService = WindowControlService()
        return WindowCycleService(
            settings: settings,
            permissionService: PermissionService(),
            windowInventory: windowInventory,
            previewService: previewService,
            previewPanelController: panel ?? PreviewPanelController(windowControlService: windowControlService),
            registrationStatus: status ?? WindowCycleRegistrationStatusStore(),
            hotkeyRegistry: registry,
            inputMonitor: inputMonitor,
            workspaceNotificationCenter: workspaceNotificationCenter,
            applicationNotificationCenter: applicationNotificationCenter,
            permissionSnapshotProvider: permissions
        )
    }

    private func seedKeyboardWindows(in inventory: WindowInventoryService) {
        let processIdentifier = pid_t.max
        let target = DockAppTarget(processIdentifier: processIdentifier, bundleIdentifier: "com.example.Editor",
                                   localizedName: "Editor", dockElementTitle: "Editor", hitPoint: .zero)
        let windows = (1...30).map { window(id: CGWindowID($0), processIdentifier: processIdentifier) }
        inventory.seed(PreviewWindowSnapshot(windows: windows, captureWindows: [:]), for: target)
    }

    private func window(id: CGWindowID, processIdentifier: pid_t, originX: CGFloat = 0) -> PreviewWindowInfo {
        PreviewWindowInfo(
            id: "window-\(id)",
            windowID: id,
            processIdentifier: processIdentifier,
            appName: "Example",
            title: "Window \(id)",
            frame: CGRect(x: originX, y: 0, width: 800, height: 500),
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

private final class TestWindowCycleInputMonitor: WindowCycleInputMonitoring {
    var onEvent: ((WindowCycleInputAction) -> Void)?
    private(set) var isMonitoring = false
    func start() -> Bool {
        isMonitoring = true
        return true
    }
    func stop() { isMonitoring = false }
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
