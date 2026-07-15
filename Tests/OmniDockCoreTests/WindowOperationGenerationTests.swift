import XCTest
@testable import OmniDockCore

final class WindowOperationGenerationTests: XCTestCase {
    func testSecondToggleCancelsPendingHideAndKeepsBringCurrent() {
        let tracker = WindowOperationGenerationTracker()
        let processIdentifier: pid_t = 101

        let pendingHide = tracker.beginPendingHide(for: processIdentifier)
        XCTAssertTrue(tracker.hasPendingHide(for: processIdentifier))

        let bring = tracker.begin(.bring, for: processIdentifier)

        XCTAssertFalse(tracker.hasPendingHide(for: processIdentifier))
        XCTAssertFalse(tracker.consumePendingHide(pendingHide))
        XCTAssertTrue(tracker.isCurrent(bring))
    }

    func testNewBringInvalidatesStaleHideCallback() {
        let tracker = WindowOperationGenerationTracker()
        let hide = tracker.begin(.hide, for: 301)

        _ = tracker.begin(.bring, for: 301)

        XCTAssertFalse(tracker.isCurrent(hide))
    }

    func testNewFocusInvalidatesStaleMinimizeCallback() {
        let tracker = WindowOperationGenerationTracker()
        let minimize = tracker.begin(.minimize, for: 302)

        _ = tracker.begin(.focus, for: 302)

        XCTAssertFalse(tracker.isCurrent(minimize))
    }

    func testNewHideInvalidatesStaleFocusCallback() {
        let tracker = WindowOperationGenerationTracker()
        let focus = tracker.begin(.focus, for: 303)

        _ = tracker.begin(.hide, for: 303)

        XCTAssertFalse(tracker.isCurrent(focus))
    }

    func testNewMinimizeInvalidatesStaleOpenCallback() {
        let tracker = WindowOperationGenerationTracker()
        let open = tracker.begin(.open, for: 304)

        _ = tracker.begin(.minimize, for: 304)

        XCTAssertFalse(tracker.isCurrent(open))
    }

    func testOperationsForDifferentProcessesRemainCurrent() {
        let tracker = WindowOperationGenerationTracker()
        let first = tracker.begin(.hide, for: 401)

        _ = tracker.begin(.open, for: 402)

        XCTAssertTrue(tracker.isCurrent(first))
        XCTAssertFalse(tracker.isForegroundCurrent(first))
    }

    func testLatestForegroundOperationRemainsCurrent() {
        let tracker = WindowOperationGenerationTracker()

        _ = tracker.begin(.focus, for: 401)
        let latest = tracker.begin(.bring, for: 402)

        XCTAssertTrue(tracker.isForegroundCurrent(latest))
    }

    func testDelayedForegroundWorkRequiresTargetToRemainFrontmost() {
        let tracker = WindowOperationGenerationTracker()
        let open = tracker.begin(.open, for: 402)

        XCTAssertTrue(tracker.isForegroundCurrent(
            open,
            currentFrontmostProcessIdentifier: 402
        ))
        XCTAssertFalse(tracker.isForegroundCurrent(
            open,
            currentFrontmostProcessIdentifier: 403
        ))
        XCTAssertFalse(tracker.isForegroundCurrent(
            open,
            currentFrontmostProcessIdentifier: nil
        ))
    }

    func testDifferentProcessOperationInvalidatesForegroundOpenCallback() {
        let tracker = WindowOperationGenerationTracker()
        let open = tracker.begin(.open, for: 501)

        _ = tracker.begin(.bring, for: 502)

        XCTAssertTrue(tracker.isCurrent(open))
        XCTAssertFalse(tracker.isForegroundCurrent(open))
    }

    func testDifferentProcessOperationCancelsPendingHideCompletion() {
        let tracker = WindowOperationGenerationTracker()
        let pendingHide = tracker.beginPendingHide(for: 601)

        _ = tracker.begin(.focus, for: 602)

        XCTAssertFalse(tracker.consumePendingHide(pendingHide))
        XCTAssertFalse(tracker.hasPendingHide(for: 601))
    }

    func testCloseInvalidatesOlderForegroundCallback() {
        let tracker = WindowOperationGenerationTracker()
        let open = tracker.begin(.open, for: 701)

        let close = tracker.begin(.close, for: 701)

        XCTAssertFalse(tracker.isCurrent(open))
        XCTAssertTrue(tracker.isForegroundCurrent(close))
    }

    func testForegroundReservationCanBecomeOpenOperationAfterProcessLaunches() {
        let tracker = WindowOperationGenerationTracker()
        let reservation = tracker.reserveForegroundOperation(frontmostProcessIdentifier: 700)

        let open = tracker.begin(
            .open,
            for: 801,
            reservation: reservation,
            currentFrontmostProcessIdentifier: 700
        )

        XCTAssertNotNil(open)
        XCTAssertTrue(open.map(tracker.isForegroundCurrent) ?? false)
    }

    func testNewerForegroundOperationRejectsDelayedLaunchReservation() {
        let tracker = WindowOperationGenerationTracker()
        let reservation = tracker.reserveForegroundOperation(frontmostProcessIdentifier: 700)

        _ = tracker.begin(.bring, for: 802)

        XCTAssertNil(tracker.begin(
            .open,
            for: 801,
            reservation: reservation,
            currentFrontmostProcessIdentifier: 700
        ))
    }

    func testChangedFrontmostApplicationRejectsDelayedLaunchReservation() {
        let tracker = WindowOperationGenerationTracker()
        let reservation = tracker.reserveForegroundOperation(frontmostProcessIdentifier: 700)

        XCTAssertNil(tracker.begin(
            .open,
            for: 801,
            reservation: reservation,
            currentFrontmostProcessIdentifier: 702
        ))
    }

    func testLaunchedApplicationMayCompleteItsOwnReservationWhenItBecameFrontmost() {
        let tracker = WindowOperationGenerationTracker()
        let reservation = tracker.reserveForegroundOperation(frontmostProcessIdentifier: 700)

        XCTAssertNotNil(tracker.begin(
            .open,
            for: 801,
            reservation: reservation,
            currentFrontmostProcessIdentifier: 801
        ))
    }
}
