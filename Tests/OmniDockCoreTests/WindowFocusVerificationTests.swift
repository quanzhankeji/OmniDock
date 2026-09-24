import XCTest
@testable import OmniDockCore

final class WindowFocusVerificationTests: XCTestCase {
    func testAcceptedRaiseIsNotConfirmedFocusAndRetriesAreBounded() {
        let driver = FocusDriver()
        driver.start()
        XCTAssertEqual(driver.raiseCount, 1)
        XCTAssertTrue(driver.results.isEmpty)

        driver.drain()

        XCTAssertEqual(driver.raiseCount, 3)
        XCTAssertEqual(driver.results, [.unconfirmed])
        XCTAssertEqual(driver.delays, [0.08, 0.08, 0.08])
    }

    func testDelayedWindowConfirmationFinishesWithoutAnotherRaise() {
        let driver = FocusDriver()
        driver.start()
        driver.state = .focused
        driver.drain()

        XCTAssertEqual(driver.results, [.focused])
        XCTAssertEqual(driver.raiseCount, 1)
    }

    func testAlreadyFocusedWindowNeedsNoRaise() {
        let driver = FocusDriver()
        driver.state = .focused
        driver.start()

        XCTAssertEqual(driver.results, [.focused])
        XCTAssertEqual(driver.raiseCount, 0)
        XCTAssertTrue(driver.scheduled.isEmpty)
    }

    func testRemovedWindowOrRestartedApplicationStopsRetrying() {
        let driver = FocusDriver()
        driver.start()
        driver.state = .unavailable
        driver.drain()

        XCTAssertEqual(driver.results, [.unavailable])
        XCTAssertEqual(driver.raiseCount, 1)
    }

    func testUnreadableAccessibilityStateNeverRaisesOrReportsSuccess() {
        let driver = FocusDriver()
        driver.state = .unreadable
        driver.start()
        driver.drain()

        XCTAssertEqual(driver.results, [.unconfirmed])
        XCTAssertEqual(driver.raiseCount, 0)
    }

    func testLaterRequestForSameOrDifferentApplicationSupersedesPendingFocus() {
        for nextPID: pid_t in [100, 200] {
            let driver = FocusDriver()
            driver.start()
            _ = driver.tracker.begin(.focus, for: nextPID)
            driver.drain()

            XCTAssertEqual(driver.results, [.superseded])
            XCTAssertEqual(driver.raiseCount, 1)
        }
    }

    func testOpeningNextSwitcherCancelsFocusBeforeNextSelectionIsCommitted() {
        let driver = FocusDriver()
        driver.start()
        _ = driver.tracker.reserveForegroundOperation(frontmostProcessIdentifier: 100)
        driver.drain()

        XCTAssertEqual(driver.results, [.superseded])
        XCTAssertEqual(driver.raiseCount, 1)
    }

    func testCancellationDuringObservationPreventsAnotherRaise() {
        let driver = FocusDriver()
        driver.onObserve = {
            _ = driver.tracker.begin(.hide, for: 100)
        }
        driver.start()

        XCTAssertEqual(driver.results, [.superseded])
        XCTAssertEqual(driver.raiseCount, 0)
    }

    func testDesktopRevealDelayDoesNotOutliveNewUserIntent() {
        let driver = FocusDriver()
        driver.start(after: 0.08)
        XCTAssertEqual(driver.raiseCount, 0)
        _ = driver.tracker.begin(.bring, for: 200)
        driver.drain()

        XCTAssertEqual(driver.results, [.superseded])
        XCTAssertEqual(driver.raiseCount, 0)
    }

    func testFocusConfirmationRequiresExactWindowNotJustFrontmostApplication() {
        XCTAssertEqual(observation(focusedWindowMatches: false).state, .unfocused)
        XCTAssertEqual(observation(isFrontmost: false).state, .unfocused)
        XCTAssertEqual(observation(targetIsMinimized: true).state, .unfocused)
        XCTAssertEqual(observation(targetIsMinimized: nil).state, .unfocused)
        XCTAssertEqual(observation().state, .focused)
    }

    func testFailedQueriesClosedWindowsAndRelaunchesCannotConfirmFocus() {
        XCTAssertEqual(observation(applicationIsCurrent: false).state, .unavailable)
        XCTAssertEqual(observation(querySucceeded: false).state, .unreadable)
        XCTAssertEqual(observation(targetIsPresent: false).state, .unavailable)
    }

    private func observation(
        applicationIsCurrent: Bool = true,
        querySucceeded: Bool = true,
        targetIsPresent: Bool = true,
        targetIsMinimized: Bool? = false,
        isFrontmost: Bool = true,
        focusedWindowMatches: Bool = true
    ) -> WindowFocusObservation {
        WindowFocusObservation(
            applicationIsCurrent: applicationIsCurrent,
            querySucceeded: querySucceeded,
            targetIsPresent: targetIsPresent,
            targetIsMinimized: targetIsMinimized,
            isFrontmost: isFrontmost,
            focusedWindowMatches: focusedWindowMatches
        )
    }
}

private final class FocusDriver {
    let tracker = WindowOperationGenerationTracker()
    var state = WindowFocusState.unfocused
    var onObserve: (() -> Void)?
    var scheduled: [() -> Void] = []
    var delays: [TimeInterval] = []
    var results: [WindowFocusResult] = []
    var raiseCount = 0

    func start(after delay: TimeInterval = 0) {
        let token = tracker.begin(.focus, for: 100)
        let attempt = WindowFocusAttempt(
            isCurrent: { self.tracker.isForegroundCurrent(token) },
            observe: {
                self.onObserve?()
                return self.state
            },
            raise: { self.raiseCount += 1 },
            schedule: { delay, work in
                self.delays.append(delay)
                self.scheduled.append(work)
            },
            completion: { self.results.append($0) }
        )
        attempt.start(after: delay)
    }

    func drain() {
        var count = 0
        while !scheduled.isEmpty && count < 10 {
            count += 1
            scheduled.removeFirst()()
        }
        XCTAssertTrue(scheduled.isEmpty, "Focus verification must be bounded")
    }
}
