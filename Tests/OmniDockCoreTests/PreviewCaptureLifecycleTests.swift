import ScreenCaptureKit
import XCTest
@testable import OmniDockCore

final class PreviewCaptureLifecycleTests: XCTestCase {
    func testCaptureCandidatePolicyLimitsHiddenSnapshotSessions() {
        let windows = (1...24).map { index in
            PreviewWindowInfo(
                id: "window-\(index)",
                windowID: CGWindowID(index),
                processIdentifier: 100,
                appName: "Test",
                title: "Window \(index)",
                frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                isMinimized: false
            )
        }
        let availableIdentities = Set(windows.map(PreviewWindowIdentity.init))

        XCTAssertEqual(
            PreviewCaptureCandidatePolicy.identities(
                for: windows,
                availableIdentities: availableIdentities,
                maximumCount: 6
            ).count,
            6
        )
        XCTAssertEqual(
            PreviewCaptureCandidatePolicy.identities(
                for: windows,
                availableIdentities: availableIdentities,
                maximumCount: 3
            ).count,
            3
        )
    }

    func testRestartRejectsCallbacksFromStaleGenerationEvenWhenStreamIdentifierIsReused() {
        var lifecycle = PreviewCaptureStreamLifecycle<Int>()
        let staleGeneration = lifecycle.begin(streamIdentifier: 7)
        XCTAssertTrue(lifecycle.markRunning(generation: staleGeneration, streamIdentifier: 7))

        let currentGeneration = lifecycle.begin(streamIdentifier: 7)
        XCTAssertTrue(lifecycle.markRunning(generation: currentGeneration, streamIdentifier: 7))

        XCTAssertFalse(lifecycle.acceptFrame(
            generation: staleGeneration,
            streamIdentifier: 7,
            continuesAfterFirstFrame: true
        ))
        XCTAssertFalse(lifecycle.acceptError(
            generation: staleGeneration,
            streamIdentifier: 7
        ))
        XCTAssertTrue(lifecycle.acceptFrame(
            generation: currentGeneration,
            streamIdentifier: 7,
            continuesAfterFirstFrame: true
        ))
    }

    func testStopRejectsFrameThatWasAlreadyAuthorizedForProcessing() {
        var lifecycle = PreviewCaptureStreamLifecycle<String>()
        let generation = lifecycle.begin(streamIdentifier: "stream")
        XCTAssertTrue(lifecycle.markRunning(
            generation: generation,
            streamIdentifier: "stream"
        ))
        XCTAssertEqual(lifecycle.frameGeneration(for: "stream"), generation)

        lifecycle.invalidate()

        XCTAssertNil(lifecycle.frameGeneration(for: "stream"))
        XCTAssertFalse(lifecycle.acceptFrame(
            generation: generation,
            streamIdentifier: "stream",
            continuesAfterFirstFrame: true
        ))
        XCTAssertFalse(lifecycle.acceptError(
            generation: generation,
            streamIdentifier: "stream"
        ))
    }

    func testTerminalStreamRejectsSubsequentFramesAndErrors() {
        var lifecycle = PreviewCaptureStreamLifecycle<String>()
        let generation = lifecycle.begin(streamIdentifier: "stream")
        XCTAssertTrue(lifecycle.markRunning(
            generation: generation,
            streamIdentifier: "stream"
        ))

        XCTAssertTrue(lifecycle.acceptError(
            generation: generation,
            streamIdentifier: "stream"
        ))

        XCTAssertTrue(lifecycle.isTerminal)
        XCTAssertNil(lifecycle.frameGeneration(for: "stream"))
        XCTAssertFalse(lifecycle.acceptFrame(
            generation: generation,
            streamIdentifier: "stream",
            continuesAfterFirstFrame: true
        ))
        XCTAssertFalse(lifecycle.acceptError(
            generation: generation,
            streamIdentifier: "stream"
        ))

        lifecycle.invalidate()
        XCTAssertFalse(lifecycle.isTerminal)
    }

    func testStaticCaptureStartLimiterCapsStartsAndPromotesInOrder() {
        let limiter = PreviewCaptureStartLimiter(maximumConcurrentStarts: 3)
        var started: [Int] = []
        let first = limiter.enqueue { _ in started.append(1) }
        let second = limiter.enqueue { _ in started.append(2) }
        let third = limiter.enqueue { _ in started.append(3) }
        let fourth = limiter.enqueue { _ in started.append(4) }
        let fifth = limiter.enqueue { _ in started.append(5) }

        XCTAssertEqual(started, [1, 2, 3])

        limiter.finish(second)
        XCTAssertEqual(started, [1, 2, 3, 4])

        limiter.finish(first)
        XCTAssertEqual(started, [1, 2, 3, 4, 5])

        [third, fourth, fifth].forEach(limiter.finish)
    }

    func testStaticCaptureStartLimiterCancelsQueuedWork() {
        let limiter = PreviewCaptureStartLimiter(maximumConcurrentStarts: 3)
        var started: [Int] = []
        let first = limiter.enqueue { _ in started.append(1) }
        let second = limiter.enqueue { _ in started.append(2) }
        let third = limiter.enqueue { _ in started.append(3) }
        let cancelled = limiter.enqueue { _ in started.append(4) }

        limiter.cancel(cancelled)
        limiter.finish(first)
        let replacement = limiter.enqueue { _ in started.append(5) }

        XCTAssertEqual(started, [1, 2, 3, 5])

        [second, third, replacement].forEach(limiter.finish)
    }

    func testStaticCaptureStartLimiterCanCancelOnlyQueuedWork() {
        let limiter = PreviewCaptureStartLimiter(maximumConcurrentStarts: 1)
        var started: [Int] = []
        let active = limiter.enqueue { _ in started.append(1) }
        let queued = limiter.enqueue { _ in started.append(2) }

        XCTAssertFalse(limiter.cancelQueued(active))
        XCTAssertTrue(limiter.cancelQueued(queued))
        limiter.finish(active)

        XCTAssertEqual(started, [1])
    }

    func testStaticCaptureStartLimiterCancellationReleasesActiveSlot() {
        let limiter = PreviewCaptureStartLimiter(maximumConcurrentStarts: 1)
        var started: [Int] = []
        let active = limiter.enqueue { _ in started.append(1) }
        let queued = limiter.enqueue { _ in started.append(2) }

        limiter.cancel(active)

        XCTAssertEqual(started, [1, 2])
        limiter.finish(queued)
    }

    func testStaticCaptureStartLimiterWaitsForAsynchronousStopBeforePromoting() {
        let limiter = PreviewCaptureStartLimiter(maximumConcurrentStarts: 1)
        var started: [Int] = []
        var stopCompletion: (() -> Void)?
        let active = limiter.enqueue { _ in started.append(1) }
        let queued = limiter.enqueue { _ in started.append(2) }

        limiter.finish(active) { completion in
            stopCompletion = completion
        }

        XCTAssertEqual(started, [1])
        stopCompletion?()
        XCTAssertEqual(started, [1, 2])
        limiter.finish(queued)
    }

    func testFallbackFailureDoesNotTerminateStreamAfterLiveFrameArrives() {
        var lifecycle = PreviewCaptureStreamLifecycle<String>()
        let generation = lifecycle.begin(streamIdentifier: "stream")
        XCTAssertTrue(lifecycle.markRunning(
            generation: generation,
            streamIdentifier: "stream"
        ))
        XCTAssertTrue(lifecycle.canStartFallback(
            generation: generation,
            streamIdentifier: "stream"
        ))
        XCTAssertTrue(lifecycle.beginFallback(
            generation: generation,
            streamIdentifier: "stream"
        ))

        XCTAssertTrue(lifecycle.acceptFrame(
            generation: generation,
            streamIdentifier: "stream",
            continuesAfterFirstFrame: true
        ))

        XCTAssertFalse(lifecycle.acceptFallbackError(
            generation: generation,
            streamIdentifier: "stream",
            continuesAfterFirstFrame: true
        ))
        XCTAssertTrue(lifecycle.isRunning)
        XCTAssertEqual(lifecycle.frameGeneration(for: "stream"), generation)
    }

    func testLateFallbackCannotReplaceAcceptedLiveFrame() {
        var lifecycle = PreviewCaptureStreamLifecycle<String>()
        let generation = lifecycle.begin(streamIdentifier: "stream")
        XCTAssertTrue(lifecycle.markRunning(
            generation: generation,
            streamIdentifier: "stream"
        ))
        XCTAssertTrue(lifecycle.beginFallback(
            generation: generation,
            streamIdentifier: "stream"
        ))

        XCTAssertTrue(lifecycle.acceptFrame(
            generation: generation,
            streamIdentifier: "stream",
            continuesAfterFirstFrame: true
        ))
        XCTAssertFalse(lifecycle.acceptFallback(
            generation: generation,
            streamIdentifier: "stream",
            continuesAfterFirstFrame: true
        ))
        XCTAssertTrue(lifecycle.isRunning)
        XCTAssertEqual(lifecycle.frameGeneration(for: "stream"), generation)
    }

    func testProvisionalFallbackKeepsContinuousStreamAliveForLaterFrames() {
        var lifecycle = PreviewCaptureStreamLifecycle<String>()
        let generation = lifecycle.begin(streamIdentifier: "stream")
        XCTAssertTrue(lifecycle.markRunning(
            generation: generation,
            streamIdentifier: "stream"
        ))

        XCTAssertTrue(lifecycle.beginFallback(
            generation: generation,
            streamIdentifier: "stream"
        ))
        XCTAssertTrue(lifecycle.acceptFallback(
            generation: generation,
            streamIdentifier: "stream",
            continuesAfterFirstFrame: true
        ))
        XCTAssertFalse(lifecycle.canStartFallback(
            generation: generation,
            streamIdentifier: "stream"
        ))
        XCTAssertTrue(lifecycle.isRunning)
        XCTAssertEqual(lifecycle.frameGeneration(for: "stream"), generation)
        XCTAssertTrue(lifecycle.acceptFrame(
            generation: generation,
            streamIdentifier: "stream",
            continuesAfterFirstFrame: true
        ))
    }

    func testFallbackFailureKeepsContinuousStreamAliveBeforeFirstFrame() {
        var lifecycle = PreviewCaptureStreamLifecycle<String>()
        let generation = lifecycle.begin(streamIdentifier: "stream")
        XCTAssertTrue(lifecycle.markRunning(
            generation: generation,
            streamIdentifier: "stream"
        ))
        XCTAssertTrue(lifecycle.beginFallback(
            generation: generation,
            streamIdentifier: "stream"
        ))

        XCTAssertTrue(lifecycle.acceptFallbackError(
            generation: generation,
            streamIdentifier: "stream",
            continuesAfterFirstFrame: true
        ))
        XCTAssertTrue(lifecycle.isRunning)
        XCTAssertEqual(lifecycle.frameGeneration(for: "stream"), generation)
        XCTAssertTrue(lifecycle.acceptFrame(
            generation: generation,
            streamIdentifier: "stream",
            continuesAfterFirstFrame: true
        ))
    }

    func testFallbackRemainsTerminalForSingleFrameCapture() {
        var lifecycle = PreviewCaptureStreamLifecycle<String>()
        let generation = lifecycle.begin(streamIdentifier: "stream")
        XCTAssertTrue(lifecycle.markRunning(
            generation: generation,
            streamIdentifier: "stream"
        ))
        XCTAssertTrue(lifecycle.beginFallback(
            generation: generation,
            streamIdentifier: "stream"
        ))

        XCTAssertTrue(lifecycle.acceptFallback(
            generation: generation,
            streamIdentifier: "stream",
            continuesAfterFirstFrame: false
        ))
        XCTAssertNil(lifecycle.frameGeneration(for: "stream"))
        XCTAssertFalse(lifecycle.acceptFrame(
            generation: generation,
            streamIdentifier: "stream",
            continuesAfterFirstFrame: false
        ))
    }

    func testStreamFrameStatusOnlyAcceptsCompleteOrUnavailableMetadata() {
        XCTAssertTrue(PreviewStreamFrameStatusPolicy.shouldProcess(.unavailable))
        XCTAssertTrue(PreviewStreamFrameStatusPolicy.shouldProcess(.status(SCFrameStatus.complete.rawValue)))
        XCTAssertFalse(PreviewStreamFrameStatusPolicy.shouldProcess(.invalid))
        XCTAssertFalse(PreviewStreamFrameStatusPolicy.shouldProcess(.status(SCFrameStatus.started.rawValue)))
        XCTAssertFalse(PreviewStreamFrameStatusPolicy.shouldProcess(.status(SCFrameStatus.idle.rawValue)))
        XCTAssertFalse(PreviewStreamFrameStatusPolicy.shouldProcess(.status(SCFrameStatus.blank.rawValue)))
    }

    func testContinuousCaptureUsesOpaqueOutputWhileSingleFrameCaptureDoesNot() {
        XCTAssertTrue(PreviewCapturePurpose.continuousLive.usesOpaqueOutput)
        XCTAssertFalse(PreviewCapturePurpose.singleFrame.usesOpaqueOutput)
    }

    func testReplacingRequestStopsOnlySupersededSessionsAndCompletesEachRequestOnce() {
        let registry = makeRegistry()
        let firstSession = FakeSession()
        let secondSession = FakeSession()
        var firstCompletionCount = 0
        var secondCompletionCount = 0

        let firstRequest = registry.begin(processIdentifier: 42) {
            firstCompletionCount += 1
        }
        XCTAssertTrue(registry.install([firstSession], for: firstRequest))

        let secondRequest = registry.begin(processIdentifier: 42) {
            secondCompletionCount += 1
        }

        XCTAssertNotEqual(firstRequest.token, secondRequest.token)
        XCTAssertFalse(registry.isCurrent(firstRequest))
        XCTAssertTrue(registry.isCurrent(secondRequest))
        XCTAssertEqual(firstSession.stopCount, 1)
        XCTAssertEqual(firstCompletionCount, 1)

        XCTAssertTrue(registry.install([secondSession], for: secondRequest))
        XCTAssertFalse(registry.finish(firstRequest))
        XCTAssertEqual(secondSession.stopCount, 0)
        XCTAssertEqual(firstCompletionCount, 1)

        XCTAssertTrue(registry.finish(secondRequest))
        XCTAssertFalse(registry.finish(secondRequest))
        XCTAssertEqual(secondSession.stopCount, 1)
        XCTAssertEqual(secondCompletionCount, 1)
    }

    func testClearInvalidatesRequestAndStopsSessionsFromLateInstall() {
        let registry = makeRegistry()
        let ownedSession = FakeSession()
        let lateSession = FakeSession()
        var completionCount = 0

        let request = registry.begin(processIdentifier: 73) {
            completionCount += 1
        }
        XCTAssertTrue(registry.install([ownedSession], for: request))

        registry.clear(processIdentifier: 73)

        XCTAssertFalse(registry.isCurrent(request))
        XCTAssertEqual(ownedSession.stopCount, 1)
        XCTAssertEqual(completionCount, 1)
        XCTAssertFalse(registry.install([lateSession], for: request))
        XCTAssertEqual(lateSession.stopCount, 1)

        registry.clear(processIdentifier: 73)
        XCTAssertFalse(registry.finish(request))
        XCTAssertEqual(ownedSession.stopCount, 1)
        XCTAssertEqual(completionCount, 1)
    }

    private func makeRegistry() -> PreviewCaptureRequestRegistry<FakeSession> {
        PreviewCaptureRequestRegistry { session in
            session.stop()
        }
    }

    private final class FakeSession {
        private(set) var stopCount = 0

        func stop() {
            stopCount += 1
        }
    }
}
