import XCTest
@testable import OmniDockCore

final class PreviewContentReadinessTests: XCTestCase {
    func testCaptureWaitsForFirstFrameBeforeBecomingDisplayable() {
        let window = identity(1)
        let now = Date(timeIntervalSince1970: 100)
        var tracker = PreviewContentReadinessTracker()

        tracker.synchronize(
            sources: [window: .capture],
            now: now,
            timeout: 1
        )

        XCTAssertEqual(tracker.state(for: window), .waiting(deadline: now.addingTimeInterval(1)))
        XCTAssertTrue(tracker.displayableIdentities.isEmpty)
        XCTAssertEqual(tracker.acceptFrame(for: window), .becameReady)
        XCTAssertEqual(tracker.displayableIdentities, [window])
    }

    func testFailureRemovesOnlyWaitingWindowFromDisplayCandidates() {
        let successfulWindow = identity(1)
        let failedWindow = identity(2)
        var tracker = PreviewContentReadinessTracker()

        tracker.synchronize(
            sources: [successfulWindow: .capture, failedWindow: .capture],
            now: Date(timeIntervalSince1970: 100),
            timeout: 1
        )
        XCTAssertEqual(tracker.acceptFrame(for: successfulWindow), .becameReady)
        XCTAssertTrue(tracker.markUnavailable(failedWindow))

        XCTAssertEqual(tracker.displayableIdentities, [successfulWindow])
        XCTAssertEqual(tracker.state(for: failedWindow), .unavailable)
    }

    func testTimedOutIdentityDoesNotRestartDuringSameHoverCycle() {
        let window = identity(1)
        let now = Date(timeIntervalSince1970: 100)
        var tracker = PreviewContentReadinessTracker()

        tracker.synchronize(sources: [window: .capture], now: now, timeout: 1)
        XCTAssertEqual(
            tracker.expireWaiting(at: now.addingTimeInterval(1)),
            [window]
        )

        tracker.synchronize(
            sources: [window: .capture],
            now: now.addingTimeInterval(2),
            timeout: 1
        )

        XCTAssertEqual(tracker.state(for: window), .unavailable)
        XCTAssertTrue(tracker.captureEligibleIdentities.isEmpty)
        XCTAssertFalse(tracker.hasWaitingContent)
        XCTAssertEqual(tracker.acceptFrame(for: window), .rejected)
    }

    func testErrorAfterFirstFrameKeepsLastReadyState() {
        let window = identity(1)
        var tracker = PreviewContentReadinessTracker()

        tracker.synchronize(sources: [window: .capture], now: Date(), timeout: 1)
        XCTAssertEqual(tracker.acceptFrame(for: window), .becameReady)

        XCTAssertFalse(tracker.markUnavailable(window))
        XCTAssertEqual(tracker.state(for: window), .ready)
        XCTAssertEqual(tracker.acceptFrame(for: window), .updatedReady)
    }

    func testReadyImageSurvivesTemporaryLossOfCaptureMapping() {
        let window = identity(1)
        var tracker = PreviewContentReadinessTracker()

        tracker.synchronize(sources: [window: .capture], now: Date(), timeout: 1)
        XCTAssertEqual(tracker.acceptFrame(for: window), .becameReady)
        tracker.synchronize(sources: [window: .unavailable], now: Date(), timeout: 1)

        XCTAssertEqual(tracker.state(for: window), .ready)
        XCTAssertEqual(tracker.displayableIdentities, [window])
        XCTAssertEqual(tracker.captureEligibleIdentities, [window])
    }

    func testWaitingSessionSurvivesTemporaryLossOfCaptureMapping() {
        let window = identity(1)
        let now = Date(timeIntervalSince1970: 100)
        var tracker = PreviewContentReadinessTracker()

        tracker.synchronize(sources: [window: .capture], now: now, timeout: 1)
        tracker.synchronize(
            sources: [window: .unavailable],
            now: now.addingTimeInterval(0.25),
            timeout: 10
        )

        XCTAssertEqual(
            tracker.state(for: window),
            .waiting(deadline: now.addingTimeInterval(1))
        )
        XCTAssertEqual(tracker.captureEligibleIdentities, [window])
    }

    func testSnapshotRefreshPreservesOriginalWaitingDeadline() {
        let window = identity(1)
        let now = Date(timeIntervalSince1970: 100)
        var tracker = PreviewContentReadinessTracker()

        tracker.synchronize(sources: [window: .capture], now: now, timeout: 1)
        tracker.synchronize(
            sources: [window: .capture],
            now: now.addingTimeInterval(0.75),
            timeout: 10
        )

        XCTAssertEqual(tracker.nextWaitingDeadline, now.addingTimeInterval(1))
    }

    func testSameFrameWindowsRemainIndependentByStrongIdentity() {
        let first = identity(1)
        let second = identity(2)
        var tracker = PreviewContentReadinessTracker()

        tracker.synchronize(
            sources: [first: .capture, second: .capture],
            now: Date(),
            timeout: 1
        )
        XCTAssertEqual(tracker.acceptFrame(for: first), .becameReady)

        XCTAssertEqual(tracker.state(for: first), .ready)
        XCTAssertNotEqual(tracker.state(for: second), .ready)
        XCTAssertEqual(tracker.displayableIdentities, [first])
    }

    func testCachedImageAndTextOnlyEntriesAreImmediatelyDisplayable() {
        let cached = identity(1)
        let minimized = identity(2)
        let missing = identity(3)
        var tracker = PreviewContentReadinessTracker()

        tracker.synchronize(
            sources: [
                cached: .cachedImage,
                minimized: .textOnly,
                missing: .unavailable
            ],
            now: Date(),
            timeout: 1
        )

        XCTAssertEqual(tracker.displayableIdentities, [cached, minimized])
        XCTAssertEqual(tracker.state(for: cached), .ready)
        XCTAssertEqual(tracker.state(for: minimized), .textOnly)
        XCTAssertEqual(tracker.state(for: missing), .unavailable)
        XCTAssertTrue(tracker.captureEligibleIdentities.isEmpty)
    }

    func testContentSourceRequiresAnImageCaptureOrMinimizedRecoveryPath() {
        XCTAssertEqual(
            PreviewContentSourcePolicy.source(
                hasCachedImage: true,
                isMinimized: false,
                hasCaptureWindow: false
            ),
            .cachedImage
        )
        XCTAssertEqual(
            PreviewContentSourcePolicy.source(
                hasCachedImage: false,
                isMinimized: true,
                hasCaptureWindow: false
            ),
            .textOnly
        )
        XCTAssertEqual(
            PreviewContentSourcePolicy.source(
                hasCachedImage: false,
                isMinimized: false,
                hasCaptureWindow: true
            ),
            .capture
        )
        XCTAssertEqual(
            PreviewContentSourcePolicy.source(
                hasCachedImage: false,
                isMinimized: false,
                hasCaptureWindow: false
            ),
            .unavailable
        )
    }

    func testRemovingAndReaddingIdentityStartsANewWaitingCycle() {
        let window = identity(1)
        let now = Date(timeIntervalSince1970: 100)
        var tracker = PreviewContentReadinessTracker()

        tracker.synchronize(sources: [window: .capture], now: now, timeout: 1)
        tracker.synchronize(sources: [:], now: now, timeout: 1)
        tracker.synchronize(
            sources: [window: .capture],
            now: now.addingTimeInterval(2),
            timeout: 1
        )

        XCTAssertEqual(
            tracker.state(for: window),
            .waiting(deadline: now.addingTimeInterval(3))
        )
    }

    func testContentGenerationRejectsLateOrUntrackedFrames() {
        XCTAssertTrue(PreviewContentGenerationPolicy.accepts(
            responseGeneration: 4,
            currentGeneration: 4,
            isIdentityTracked: true
        ))
        XCTAssertFalse(PreviewContentGenerationPolicy.accepts(
            responseGeneration: 3,
            currentGeneration: 4,
            isIdentityTracked: true
        ))
        XCTAssertFalse(PreviewContentGenerationPolicy.accepts(
            responseGeneration: 4,
            currentGeneration: 4,
            isIdentityTracked: false
        ))
    }

    func testCaptureAvailabilityRetainsRegisteredSessionDuringTransientMappingLoss() {
        let retained = identity(1)
        let newlyAvailable = identity(2)
        let unavailable = identity(3)

        XCTAssertEqual(
            PreviewCaptureAvailabilityPolicy.identities(
                currentCaptureIdentities: [newlyAvailable],
                registeredIdentities: [retained],
                contentEligibleIdentities: [retained, newlyAvailable, unavailable]
            ),
            [retained, newlyAvailable]
        )
    }

    func testTimeoutPolicyUsesLongerDeadlineOnOlderOrReducedLoadSystems() {
        XCTAssertEqual(
            PreviewContentTimeoutPolicy.timeout(
                operatingSystemMajorVersion: 14,
                prefersReducedLoad: false
            ),
            1
        )
        XCTAssertEqual(
            PreviewContentTimeoutPolicy.timeout(
                operatingSystemMajorVersion: 13,
                prefersReducedLoad: false
            ),
            1.5
        )
        XCTAssertEqual(
            PreviewContentTimeoutPolicy.timeout(
                operatingSystemMajorVersion: 26,
                prefersReducedLoad: true
            ),
            1.5
        )
    }

    func testOneThousandStableRefreshesDoNotResetReadinessOrDeadline() {
        let readyWindow = identity(1)
        let waitingWindow = identity(2)
        let now = Date(timeIntervalSince1970: 100)
        let sources: [PreviewWindowIdentity: PreviewContentSource] = [
            readyWindow: .capture,
            waitingWindow: .capture
        ]
        var tracker = PreviewContentReadinessTracker()

        tracker.synchronize(sources: sources, now: now, timeout: 1)
        XCTAssertEqual(tracker.acceptFrame(for: readyWindow), .becameReady)
        for index in 0..<1_000 {
            tracker.synchronize(
                sources: sources,
                now: now.addingTimeInterval(Double(index) / 10_000),
                timeout: 10
            )
        }

        XCTAssertEqual(tracker.state(for: readyWindow), .ready)
        XCTAssertEqual(tracker.nextWaitingDeadline, now.addingTimeInterval(1))
    }

    private func identity(_ windowID: CGWindowID) -> PreviewWindowIdentity {
        .window(processIdentifier: 42, windowID: windowID)
    }
}
