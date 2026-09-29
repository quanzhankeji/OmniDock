import AppKit
import ApplicationServices
import XCTest
@testable import OmniDockCore

final class WindowInventoryStateTests: XCTestCase {
    func testEmptyApplicationRemainsTrackedUntilTermination() {
        var state = WindowInventoryState()
        _ = state.apply(.seed(processIdentifier: 101, revision: 1, records: []))
        XCTAssertEqual(state.processIdentifiers, [101])
        _ = state.apply(.processTerminated(processIdentifier: 101))
        XCTAssertTrue(state.processIdentifiers.isEmpty)
    }

    func testSwitcherSnapshotIncludesNewAccessibilityWindowBeforeItsSurfaceAppears() {
        let visible = record(windowID: 10, title: "Visible").makePreviewWindowInfo()
        let newlyCreated = PreviewWindowInfo(
            id: "new-window", windowID: 20, processIdentifier: 101, appName: "Example", title: "New document",
            frame: CGRect(x: 40, y: 40, width: 800, height: 600), isMinimized: false
        )
        let windows = WindowInventorySwitcherSnapshotPolicy.merge(
            accessibilityWindows: [visible, newlyCreated], windowServerWindows: [visible]
        )
        XCTAssertEqual(windows.compactMap(\.windowID), [10, 20])
    }

    func testSwitcherSnapshotDoesNotDuplicateAnUnmatchedTabOnAnExistingSurface() {
        let visible = record(windowID: 10, title: "Visible").makePreviewWindowInfo()
        let tab = record(windowID: 20, title: "Background tab").makePreviewWindowInfo()
        let windows = WindowInventorySwitcherSnapshotPolicy.merge(
            accessibilityWindows: [visible, tab], windowServerWindows: [visible]
        )
        XCTAssertEqual(windows.compactMap(\.windowID), [10])
    }

    func testBothAccessibilityCreationNotificationsInvalidateWindowStructure() {
        XCTAssertEqual(WindowInventoryInvalidation(accessibilityNotification: kAXWindowCreatedNotification), .created)
        XCTAssertEqual(WindowInventoryInvalidation(accessibilityNotification: kAXCreatedNotification), .created)
        XCTAssertEqual(WindowInventoryInvalidation(accessibilityNotification: kAXUIElementDestroyedNotification), .destroyed)
        XCTAssertNil(WindowInventoryInvalidation(accessibilityNotification: "AXUnrelatedNotification"))
    }

    func testWindowStateSurvivesCaptureMergeAndInventoryRoundTrip() throws {
        let ax = PreviewWindowInfo(
            id: "ax-10", windowID: 10, processIdentifier: 101, appName: "Editor",
            title: "Document", frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            isMinimized: false, isApplicationHidden: true, isFullScreen: true
        )
        let surface = PreviewWindowInfo(
            id: "sc-10", windowID: 10, processIdentifier: 101, appName: "Editor",
            title: "Document", frame: ax.frame, isMinimized: false
        )
        for merged in [
            PreviewWindowCatalog.mergeForDisplay(axWindows: [ax], shareableWindows: [surface]),
            WindowInventorySwitcherSnapshotPolicy.merge(accessibilityWindows: [ax], windowServerWindows: [surface])
        ] {
            let info = try XCTUnwrap(merged.first)
            XCTAssertEqual(info.isApplicationHidden, true)
            XCTAssertEqual(info.isFullScreen, true)
            let restored = WindowInventoryRecord(info, displayOrder: 0).makePreviewWindowInfo()
            XCTAssertEqual(restored.isApplicationHidden, true)
            XCTAssertEqual(restored.isFullScreen, true)
        }
    }

    func testSwitcherSnapshotRequiresAccessibilitySupportForWindowServerSurfaces() {
        let windowServerWindow = record(windowID: 10, title: "Residual Surface").makePreviewWindowInfo()

        let windows = WindowInventorySwitcherSnapshotPolicy.merge(
            accessibilityWindows: [],
            windowServerWindows: [windowServerWindow]
        )

        XCTAssertTrue(windows.isEmpty)
    }

    func testSwitcherSnapshotKeepsValidatedWindowServerWindowsAndMinimizedAccessibilityWindows() {
        let visible = record(windowID: 10, title: "Visible").makePreviewWindowInfo()
        let minimized = WindowInventoryRecord(
            identity: .window(processIdentifier: 101, windowID: 20),
            id: "window-20",
            processIdentifier: 101,
            appName: "Example",
            title: "Minimized",
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            isMinimized: true
        ).makePreviewWindowInfo()

        let windows = WindowInventorySwitcherSnapshotPolicy.merge(
            accessibilityWindows: [visible, minimized],
            windowServerWindows: [visible]
        )

        XCTAssertEqual(windows.map(\.windowID), [10, 20])
        XCTAssertEqual(windows.map(\.isMinimized), [false, true])
    }

    func testSwitcherSnapshotDoesNotLetOneAccessibilityWindowAuthorizeDuplicateSurfaces() {
        let accessibilityWindow = record(windowID: 10, title: "Window").makePreviewWindowInfo()
        let duplicateSurface = WindowInventoryRecord(
            identity: .window(processIdentifier: 101, windowID: 20),
            id: "window-20",
            processIdentifier: 101,
            appName: "Example",
            title: "Window",
            frame: accessibilityWindow.frame,
            isMinimized: false
        ).makePreviewWindowInfo()

        let windows = WindowInventorySwitcherSnapshotPolicy.merge(
            accessibilityWindows: [accessibilityWindow],
            windowServerWindows: [accessibilityWindow, duplicateSurface]
        )

        XCTAssertEqual(windows.map(\.windowID), [10])
    }

    func testMinimizedWindowWithoutAXNumberKeepsItsKnownIdentity() {
        let previous = record(windowID: 10, title: "Document").makePreviewWindowInfo()
        let minimized = PreviewWindowInfo(
            id: "ax-minimized", windowID: nil, processIdentifier: 101, appName: "Example",
            title: previous.title, frame: previous.frame, isMinimized: true
        )
        let windows = WindowInventorySwitcherSnapshotPolicy.merge(
            accessibilityWindows: [minimized], windowServerWindows: [], previousWindows: [previous]
        )
        XCTAssertEqual(windows.map(\.windowID), [10])
        XCTAssertEqual(windows.map(\.isMinimized), [true])
    }

    func testMinimizedIdentityFallbackRejectsAmbiguityOtherProcessesAndNewNormalWindows() {
        let previous = record(windowID: 10, title: "Document").makePreviewWindowInfo()
        let duplicate = record(windowID: 20, title: "Document").makePreviewWindowInfo()
        func ax(_ id: String, pid: pid_t = 101, minimized: Bool = true) -> PreviewWindowInfo {
            PreviewWindowInfo(id: id, windowID: nil, processIdentifier: pid, appName: "Example",
                              title: previous.title, frame: previous.frame, isMinimized: minimized)
        }
        for (current, known) in [
            ([ax("one")], [previous, duplicate]),
            ([ax("one"), ax("two")], [previous]),
            ([ax("other", pid: 202)], [previous]),
            ([ax("new", minimized: false)], [previous])
        ] {
            let windows = WindowInventorySwitcherSnapshotPolicy.merge(
                accessibilityWindows: current, windowServerWindows: [], previousWindows: known
            )
            XCTAssertTrue(windows.allSatisfy { $0.windowID == nil })
        }
    }

    func testSeedRejectsOutOfOrderResultsForTheSameProcess() {
        var state = WindowInventoryState()
        let original = record(windowID: 10, title: "Original")
        let stale = record(windowID: 20, title: "Stale")

        XCTAssertTrue(state.apply(.seed(processIdentifier: 101, revision: 2, records: [original])))
        XCTAssertFalse(state.apply(.seed(processIdentifier: 101, revision: 1, records: [stale])))
        XCTAssertEqual(state.records(for: 101).map(\.title), ["Original"])
        XCTAssertEqual(state.recordsByWindowID[10]?.title, "Original")
    }

    func testDuplicateInvalidationDoesNotCreateRepeatedStateChanges() {
        var state = WindowInventoryState()
        XCTAssertTrue(state.apply(.seed(processIdentifier: 101, revision: 1, records: [record(windowID: 10)])))

        XCTAssertTrue(state.apply(.processInvalidated(processIdentifier: 101, reason: .resized)))
        XCTAssertFalse(state.apply(.processInvalidated(processIdentifier: 101, reason: .titleChanged)))
        XCTAssertTrue(state.isStale(processIdentifier: 101))
    }

    func testProcessTerminationCleansWindowIndexesAndFocusHistory() {
        var state = WindowInventoryState()
        let first = record(windowID: 10)
        let second = record(windowID: 20)
        XCTAssertTrue(state.apply(.seed(processIdentifier: 101, revision: 1, records: [first, second])))
        XCTAssertTrue(state.apply(.windowFocused(second.identity)))

        XCTAssertTrue(state.apply(.processTerminated(processIdentifier: 101)))
        XCTAssertTrue(state.records(for: 101).isEmpty)
        XCTAssertTrue(state.windowIDsByProcessID[101]?.isEmpty ?? true)
        XCTAssertTrue(state.focusHistory.isEmpty)
        XCTAssertNil(state.recordsByWindowID[10])
        XCTAssertNil(state.recordsByWindowID[20])
    }

    func testApplicationLaunchClearsFactsForAReusedProcessIdentifier() {
        var state = WindowInventoryState()
        XCTAssertTrue(state.apply(.seed(processIdentifier: 101, revision: 4, records: [record(windowID: 10)])))
        XCTAssertTrue(state.apply(.windowFocused(record(windowID: 10).identity)))

        XCTAssertTrue(state.apply(.processLaunched(processIdentifier: 101)))
        XCTAssertTrue(state.records(for: 101).isEmpty)
        XCTAssertTrue(state.focusHistory.isEmpty)
        XCTAssertNil(state.recordsByWindowID[10])

        XCTAssertTrue(state.apply(.seed(processIdentifier: 101, revision: 1, records: [record(windowID: 20)])))
        XCTAssertEqual(state.records(for: 101).map(\.identity.windowID), [20])
    }

    func testFocusHistoryProvidesMruOrderWithoutChangingDisplayOrder() {
        var state = WindowInventoryState()
        let first = record(windowID: 10, title: "First", displayOrder: 0)
        let second = record(windowID: 20, title: "Second", displayOrder: 1)
        XCTAssertTrue(state.apply(.seed(processIdentifier: 101, revision: 1, records: [first, second])))

        XCTAssertTrue(state.apply(.windowFocused(second.identity)))
        XCTAssertEqual(state.records(for: 101).map(\.title), ["First", "Second"])
        XCTAssertEqual(state.allRecordsByMostRecentFocus().map(\.title), ["Second", "First"])
    }

    func testSpaceChangeMarksTrackedProcessesStaleWithoutDiscardingFacts() {
        var state = WindowInventoryState()
        XCTAssertTrue(state.apply(.seed(processIdentifier: 101, revision: 1, records: [record(windowID: 10)])))
        XCTAssertTrue(state.apply(.seed(processIdentifier: 202, revision: 1, records: [record(windowID: 20, processIdentifier: 202)])))

        XCTAssertTrue(state.apply(.activeSpaceChanged))
        XCTAssertTrue(state.isStale(processIdentifier: 101))
        XCTAssertTrue(state.isStale(processIdentifier: 202))
        XCTAssertEqual(state.allRecordsByMostRecentFocus().count, 2)
    }

    func testDisplayChangePreservesFocusOrderWhenFreshGeometryArrives() {
        var state = WindowInventoryState()
        let first = record(windowID: 10)
        let second = record(windowID: 20)
        _ = state.apply(.seed(processIdentifier: 101, revision: 1, records: [first, second]))
        _ = state.apply(.windowFocused(second.identity))

        XCTAssertTrue(state.apply(.displayConfigurationChanged))
        XCTAssertTrue(state.isStale(processIdentifier: 101))
        _ = state.apply(.seed(processIdentifier: 101, revision: 2, records: [first, second]))
        XCTAssertFalse(state.isStale(processIdentifier: 101))
        XCTAssertEqual(state.allRecordsByMostRecentFocus().map(\.identity), [second.identity, first.identity])
    }

    func testOnlyMetadataEventsAreDebounced() {
        XCTAssertEqual(WindowInventoryEventCoalescingPolicy.delay(for: .moved), 0.1)
        XCTAssertEqual(WindowInventoryEventCoalescingPolicy.delay(for: .resized), 0.1)
        XCTAssertEqual(WindowInventoryEventCoalescingPolicy.delay(for: .titleChanged), 0.1)
        XCTAssertEqual(WindowInventoryEventCoalescingPolicy.delay(for: .created), 0)
        XCTAssertEqual(WindowInventoryEventCoalescingPolicy.delay(for: .destroyed), 0)
        XCTAssertEqual(WindowInventoryEventCoalescingPolicy.delay(for: .minimized), 0)
    }

    func testSnapshotReuseRefusesStaleOrExpiredRecords() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(WindowInventorySnapshotReusePolicy.shouldReuse(
            seededAt: now.addingTimeInterval(-0.5),
            isStale: false,
            now: now
        ))
        XCTAssertFalse(WindowInventorySnapshotReusePolicy.shouldReuse(
            seededAt: now.addingTimeInterval(-0.7),
            isStale: false,
            now: now
        ))
        XCTAssertFalse(WindowInventorySnapshotReusePolicy.shouldReuse(
            seededAt: now,
            isStale: true,
            now: now
        ))
    }

    private func record(
        windowID: CGWindowID,
        title: String = "Window",
        processIdentifier: pid_t = 101,
        displayOrder: Int = 0
    ) -> WindowInventoryRecord {
        WindowInventoryRecord(
            identity: .window(processIdentifier: processIdentifier, windowID: windowID),
            id: "window-\(windowID)",
            processIdentifier: processIdentifier,
            appName: "Example",
            title: title,
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            isMinimized: false,
            displayOrder: displayOrder
        )
    }
}

@MainActor
final class WindowInventoryServiceTests: XCTestCase {
    func testApplicationLaunchIsPublishedBeforeItsFirstWindowIsKnown() async {
        let application = NSRunningApplication.current
        let center = NotificationCenter()
        let service = WindowInventoryService(workspaceNotificationCenter: center)
        service.start()
        defer { service.stop() }
        let launched = expectation(description: "An unindexed application launch is published")
        service.observeChanges { event in
            if case let .processLaunched(processIdentifier) = event,
               processIdentifier == application.processIdentifier {
                launched.fulfill()
            }
        }

        center.post(name: NSWorkspace.didLaunchApplicationNotification, object: nil,
                    userInfo: [NSWorkspace.applicationUserInfoKey: application])

        await fulfillment(of: [launched], timeout: 1)
    }

    func testTargetedReconciliationReadsOnlyTheAffectedApplicationAndRejectsOldSnapshots() {
        let target = target()
        let updated = window(title: "Updated")
        var reads: [pid_t] = []
        let service = WindowInventoryService(
            accessibilityWindowsProvider: { processIdentifier, _ in
                reads.append(processIdentifier)
                return [updated]
            },
            windowServerWindowsProvider: { [:] }
        )
        defer { service.stop() }
        let oldSnapshot = PreviewWindowSnapshot(windows: [window(title: "Old")], captureWindows: [:])
        service.seed(oldSnapshot, for: target)
        let oldRevision = service.beginSnapshotRequest(for: target)

        let records = service.reconcileWindows(for: target.processIdentifier)
        service.seed(oldSnapshot, for: target, requestRevision: oldRevision)

        XCTAssertEqual(reads, [target.processIdentifier])
        XCTAssertEqual(records?.map(\.title), ["Updated"])
        XCTAssertEqual(service.windows(for: target.processIdentifier).map(\.title), ["Updated"])
        XCTAssertNil(service.previewSnapshot(for: target), "Structural refresh must discard cached closed surfaces")
    }

    func testTargetedReconciliationDistinguishesReadFailureFromAnEmptyWindowList() {
        let target = target()
        var accessibilityWindows: [PreviewWindowInfo]?
        let service = WindowInventoryService(
            accessibilityWindowsProvider: { _, _ in accessibilityWindows },
            windowServerWindowsProvider: { [:] }
        )
        defer { service.stop() }
        service.seed(PreviewWindowSnapshot(windows: [window(title: "Document")], captureWindows: [:]), for: target)

        XCTAssertNil(service.reconcileWindows(for: target.processIdentifier))
        XCTAssertEqual(service.windows(for: target.processIdentifier).count, 1)
        accessibilityWindows = []
        XCTAssertEqual(service.reconcileWindows(for: target.processIdentifier)?.count, 0)
        XCTAssertTrue(service.windows(for: target.processIdentifier).isEmpty)
    }

    func testTargetedEmptyResultDoesNotRemoveAnotherApplicationsWindows() {
        let target = target()
        let otherTarget = DockAppTarget(processIdentifier: 202, bundleIdentifier: nil, localizedName: "Other",
                                        dockElementTitle: "Other", hitPoint: .zero)
        let otherWindow = PreviewWindowInfo(
            id: "other", windowID: 20, processIdentifier: otherTarget.processIdentifier, appName: "Other",
            title: "Other document", frame: CGRect(x: 0, y: 0, width: 800, height: 600), isMinimized: false
        )
        let service = WindowInventoryService(
            accessibilityWindowsProvider: { _, _ in [] }, windowServerWindowsProvider: { [:] }
        )
        defer { service.stop() }
        service.seed(PreviewWindowSnapshot(windows: [window(title: "Document")], captureWindows: [:]), for: target)
        service.seed(PreviewWindowSnapshot(windows: [otherWindow], captureWindows: [:]), for: otherTarget)

        _ = service.reconcileWindows(for: target.processIdentifier)

        XCTAssertEqual(service.allWindows().map(\.identity), [PreviewWindowIdentity(otherWindow)])
    }

    func testRepeatedVisibilityChangesArePublishedUntilTheNextSnapshot() async {
        let application = NSRunningApplication.current
        let center = NotificationCenter()
        let service = WindowInventoryService(workspaceNotificationCenter: center)
        service.start()
        defer { service.stop() }
        var invalidations = 0
        service.observeChanges { event in
            if case let .processInvalidated(pid, .visibilityChanged) = event,
               pid == application.processIdentifier {
                invalidations += 1
            }
        }
        for notification in [NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification] {
            center.post(
                name: notification, object: nil, userInfo: [NSWorkspace.applicationUserInfoKey: application]
            )
            let drained = expectation(description: "Visibility notification delivered")
            DispatchQueue.main.async { drained.fulfill() }
            await fulfillment(of: [drained], timeout: 1)
        }
        XCTAssertEqual(invalidations, 2)
    }

    func testDisplayObserverDoesNotDuplicateOrOutliveInventoryService() {
        let applicationCenter = NotificationCenter()
        let service = WindowInventoryService(applicationNotificationCenter: applicationCenter)
        let target = target()
        let snapshot = PreviewWindowSnapshot(windows: [window(title: "Document")], captureWindows: [:])
        var invalidations = 0
        service.start()
        service.start()
        service.observeChanges { event in
            if case .displayConfigurationChanged = event { invalidations += 1 }
        }
        service.seed(snapshot, for: target)
        applicationCenter.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        XCTAssertEqual(invalidations, 1)
        service.stop()
        service.seed(snapshot, for: target)
        applicationCenter.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        XCTAssertNotNil(service.previewSnapshot(for: target))
        service.start()
        defer { service.stop() }
        applicationCenter.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        XCTAssertNil(service.previewSnapshot(for: target))
    }

    func testDisplayChangeInvalidatesSnapshotsAndRejectsEarlierRequests() {
        let applicationCenter = NotificationCenter()
        let service = WindowInventoryService(applicationNotificationCenter: applicationCenter)
        service.start()
        defer { service.stop() }
        let target = target()
        let unseenTarget = DockAppTarget(processIdentifier: 202, bundleIdentifier: nil, localizedName: "Other",
                                        dockElementTitle: "Other", hitPoint: .zero)
        let snapshot = PreviewWindowSnapshot(windows: [window(title: "Old frame")], captureWindows: [:])
        service.seed(snapshot, for: target)
        let earlierRevision = service.beginSnapshotRequest(for: target)
        let unseenRevision = service.beginSnapshotRequest(for: unseenTarget)
        XCTAssertNotNil(service.previewSnapshot(for: target))

        applicationCenter.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)

        XCTAssertNil(service.previewSnapshot(for: target))
        XCTAssertTrue(service.allWindows().isEmpty)
        service.seed(snapshot, for: target, requestRevision: earlierRevision)
        service.seed(PreviewWindowSnapshot(windows: [], captureWindows: [:]),
                     for: unseenTarget, requestRevision: unseenRevision)
        XCTAssertNil(service.previewSnapshot(for: target))
        XCTAssertNil(service.previewSnapshot(for: unseenTarget))
        XCTAssertTrue(service.allWindows().isEmpty)

        service.seed(PreviewWindowSnapshot(windows: [window(title: "Fresh frame")], captureWindows: [:]), for: target)
        XCTAssertEqual(service.allWindows().map(\.title), ["Fresh frame"])
    }

    func testApplicationVisibilityNotificationsInvalidateWindowMetadata() async {
        let application = NSRunningApplication.current
        let target = DockAppTarget(
            processIdentifier: application.processIdentifier, bundleIdentifier: "com.example.Editor",
            localizedName: "Editor", dockElementTitle: "Editor", hitPoint: .zero
        )
        for notification in [NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification] {
            let service = WindowInventoryService()
            service.start()
            defer { service.stop() }
            service.seed(PreviewWindowSnapshot(windows: [PreviewWindowInfo(
                id: "document", windowID: 10, processIdentifier: target.processIdentifier,
                appName: "Editor", title: "Document", frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                isMinimized: false
            )], captureWindows: [:]), for: target)
            let invalidated = expectation(description: "Visibility invalidates metadata")
            service.observeChanges { event in
                if case let .processInvalidated(pid, reason) = event,
                   pid == target.processIdentifier, reason == .visibilityChanged {
                    invalidated.fulfill()
                }
            }

            NSWorkspace.shared.notificationCenter.post(
                name: notification, object: nil, userInfo: [NSWorkspace.applicationUserInfoKey: application]
            )
            await fulfillment(of: [invalidated], timeout: 1)
            XCTAssertNil(service.previewSnapshot(for: target))
            XCTAssertTrue(service.windows(for: target.processIdentifier).isEmpty)
        }
    }

    func testOlderSnapshotCompletionCannotReplaceNewerRequest() {
        let service = WindowInventoryService()
        let target = target()
        let earlierRevision = service.beginSnapshotRequest(for: target)
        let laterRevision = service.beginSnapshotRequest(for: target)

        service.seed(
            PreviewWindowSnapshot(windows: [window(title: "New")], captureWindows: [:]),
            for: target,
            requestRevision: laterRevision
        )
        service.seed(
            PreviewWindowSnapshot(windows: [window(title: "Old")], captureWindows: [:]),
            for: target,
            requestRevision: earlierRevision
        )

        XCTAssertEqual(service.previewSnapshot(for: target)?.windows.map(\.title), ["New"])
    }

    func testCachedSnapshotFillsFromSeedAndFallsBackAfterAWindowCloses() {
        let service = WindowInventoryService()
        let target = target()
        let window = window(title: "Window")
        let snapshot = PreviewWindowSnapshot(windows: [window], captureWindows: [:])

        service.seed(snapshot, for: target)
        XCTAssertEqual(service.previewSnapshot(for: target)?.windows.map(\.title), ["Window"])

        service.remove(window)
        XCTAssertNil(service.previewSnapshot(for: target))
        XCTAssertTrue(service.windows(for: 101).isEmpty)
    }

    func testApplicationExitClearsCachedSnapshotAndFutureWindowIndex() {
        let service = WindowInventoryService()
        let target = target()
        service.seed(
            PreviewWindowSnapshot(windows: [window(title: "Window")], captureWindows: [:]),
            for: target
        )

        service.remove(processIdentifier: target.processIdentifier)

        XCTAssertNil(service.previewSnapshot(for: target))
        XCTAssertTrue(service.windows(for: target.processIdentifier).isEmpty)
        XCTAssertTrue(service.allWindows().isEmpty)
    }

    func testWindowRemovalPublishesAfterTheInventoryDropsTheRecord() {
        let service = WindowInventoryService()
        let target = target()
        let previewWindow = window(title: "Window")
        var observedIdentity: PreviewWindowIdentity?

        let observer = service.observeChanges { event in
            if case let .windowRemoved(identity) = event {
                observedIdentity = identity
            }
        }
        defer {
            service.removeChangeObserver(observer)
        }

        service.seed(
            PreviewWindowSnapshot(windows: [previewWindow], captureWindows: [:]),
            for: target
        )
        service.remove(previewWindow)

        XCTAssertEqual(observedIdentity, PreviewWindowIdentity(previewWindow))
        XCTAssertTrue(service.windows(for: target.processIdentifier).isEmpty)
    }

    func testChangeObserverCanUnsubscribeDuringDelivery() {
        let service = WindowInventoryService()
        let target = target()
        var callbackCount = 0
        var observer: UUID?
        observer = service.observeChanges { _ in
            callbackCount += 1
            if let observer {
                service.removeChangeObserver(observer)
            }
        }

        service.seed(
            PreviewWindowSnapshot(windows: [window(title: "Window")], captureWindows: [:]),
            for: target
        )
        service.remove(window(title: "Window"))

        XCTAssertEqual(callbackCount, 1)
    }

    private func target() -> DockAppTarget {
        DockAppTarget(
            processIdentifier: 101,
            bundleIdentifier: "com.example.windowed",
            localizedName: "Example",
            dockElementTitle: "Example",
            hitPoint: .zero
        )
    }

    private func window(title: String) -> PreviewWindowInfo {
        PreviewWindowInfo(
            id: "window-10",
            windowID: 10,
            processIdentifier: 101,
            appName: "Example",
            title: title,
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            isMinimized: false
        )
    }
}
