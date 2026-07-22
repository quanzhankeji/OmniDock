import XCTest
@testable import OmniDockCore

final class WindowInventoryStateTests: XCTestCase {
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
