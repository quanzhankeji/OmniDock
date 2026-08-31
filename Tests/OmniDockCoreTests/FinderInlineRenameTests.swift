import XCTest
@testable import OmniDockCore

final class FinderInlineRenameTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)

    func testRenamesOnceFinderOwnsFocus() {
        XCTAssertEqual(
            FinderInlineRenamePolicy.step(
                frontmostBundleIdentifier: "com.apple.finder",
                isSecureInputEnabled: false,
                now: now,
                deadline: now.addingTimeInterval(1)
            ),
            .rename
        )
    }

    func testWaitsWhileAnotherApplicationStillHasFocus() {
        // Revealing a file activates Finder asynchronously, so the first look
        // usually still finds the application the user came from.
        XCTAssertEqual(
            FinderInlineRenamePolicy.step(
                frontmostBundleIdentifier: "com.apple.Safari",
                isSecureInputEnabled: false,
                now: now,
                deadline: now.addingTimeInterval(1)
            ),
            .wait
        )
    }

    func testGivesUpRatherThanTypingIntoAnotherApplication() {
        XCTAssertEqual(
            FinderInlineRenamePolicy.step(
                frontmostBundleIdentifier: "com.apple.Safari",
                isSecureInputEnabled: false,
                now: now.addingTimeInterval(2),
                deadline: now.addingTimeInterval(1)
            ),
            .cancel
        )
    }

    func testGivesUpWhenNothingIsFrontmost() {
        XCTAssertEqual(
            FinderInlineRenamePolicy.step(
                frontmostBundleIdentifier: nil,
                isSecureInputEnabled: false,
                now: now.addingTimeInterval(2),
                deadline: now.addingTimeInterval(1)
            ),
            .cancel
        )
    }

    func testSecureInputStopsTheAttemptEvenWithFinderFrontmost() {
        XCTAssertEqual(
            FinderInlineRenamePolicy.step(
                frontmostBundleIdentifier: "com.apple.finder",
                isSecureInputEnabled: true,
                now: now,
                deadline: now.addingTimeInterval(1)
            ),
            .cancel
        )
    }

    func testActivatorPollsUntilFinderComesForwardThenSendsReturn() {
        var frontmost = "com.apple.Safari"
        var pending: [() -> Void] = []
        var currentTime = now
        var returnCount = 0

        var activator = FinderInlineRenameActivator()
        activator.frontmostBundleIdentifier = { frontmost }
        activator.isSecureInputEnabled = { false }
        activator.hasAccessibilityAccess = { true }
        activator.bringFinderForward = {}
        activator.postReturnKey = { returnCount += 1 }
        activator.now = { currentTime }
        activator.schedule = { delay, work in
            currentTime = currentTime.addingTimeInterval(delay)
            pending.append(work)
        }

        activator.begin()
        XCTAssertEqual(returnCount, 0)

        pending.removeFirst()()
        XCTAssertEqual(returnCount, 0)

        frontmost = "com.apple.finder"
        pending.removeFirst()()
        XCTAssertEqual(returnCount, 1)
        XCTAssertTrue(pending.isEmpty)
    }

    func testActivatorStopsAtTheDeadlineWithoutSendingReturn() {
        var pending: [() -> Void] = []
        var currentTime = now
        var returnCount = 0

        var activator = FinderInlineRenameActivator()
        activator.frontmostBundleIdentifier = { "com.apple.Safari" }
        activator.isSecureInputEnabled = { false }
        activator.hasAccessibilityAccess = { true }
        activator.bringFinderForward = {}
        activator.postReturnKey = { returnCount += 1 }
        activator.now = { currentTime }
        activator.schedule = { delay, work in
            currentTime = currentTime.addingTimeInterval(delay)
            pending.append(work)
        }

        activator.begin()
        var iterations = 0
        while let next = pending.first {
            pending.removeFirst()
            next()
            iterations += 1
            XCTAssertLessThan(iterations, 500, "polling never stopped")
        }

        XCTAssertEqual(returnCount, 0)
    }

    func testNothingIsPostedWithoutAccessibilityAccess() {
        // The system drops synthetic keys from an untrusted app, so there is
        // nothing to wait for: stop instead of polling to the deadline.
        var scheduled = 0
        var returnCount = 0
        var didActivateFinder = false

        var activator = FinderInlineRenameActivator()
        activator.frontmostBundleIdentifier = { "com.apple.finder" }
        activator.isSecureInputEnabled = { false }
        activator.hasAccessibilityAccess = { false }
        activator.bringFinderForward = { didActivateFinder = true }
        activator.postReturnKey = { returnCount += 1 }
        activator.now = { self.now }
        activator.schedule = { _, _ in scheduled += 1 }

        activator.begin()

        XCTAssertEqual(returnCount, 0)
        XCTAssertEqual(scheduled, 0)
        XCTAssertFalse(didActivateFinder)
    }

    func testSecureInputStopsBeforeAskingForAccessibility() {
        // Asking would put a permission prompt on screen for a keystroke that
        // could not be delivered anyway.
        var didCheckAccess = false
        var returnCount = 0

        var activator = FinderInlineRenameActivator()
        activator.frontmostBundleIdentifier = { "com.apple.finder" }
        activator.isSecureInputEnabled = { true }
        activator.hasAccessibilityAccess = {
            didCheckAccess = true
            return true
        }
        activator.bringFinderForward = {}
        activator.postReturnKey = { returnCount += 1 }
        activator.now = { self.now }
        activator.schedule = { _, _ in }

        activator.begin()

        XCTAssertFalse(didCheckAccess)
        XCTAssertEqual(returnCount, 0)
    }

    func testFinderIsAskedForwardBeforeTheWaitBegins() {
        var order: [String] = []

        var activator = FinderInlineRenameActivator()
        activator.frontmostBundleIdentifier = {
            order.append("checked")
            return "com.apple.finder"
        }
        activator.isSecureInputEnabled = { false }
        activator.hasAccessibilityAccess = { true }
        activator.bringFinderForward = { order.append("activated") }
        activator.postReturnKey = { order.append("return") }
        activator.now = { self.now }
        activator.schedule = { _, _ in }

        activator.begin()

        XCTAssertEqual(order, ["activated", "checked", "return"])
    }
}
