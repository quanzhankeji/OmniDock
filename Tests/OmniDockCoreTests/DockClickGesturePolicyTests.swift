import CoreGraphics
import XCTest
@testable import OmniDockCore

final class DockClickGesturePolicyTests: XCTestCase {
    func testShortClickIsNotLongPress() {
        XCTAssertFalse(DockClickGesturePolicy.isLongPress(
            elapsed: DockClickGesturePolicy.longPressDuration - 0.01
        ))
    }

    func testDeliberateClickIsNotLongPress() {
        XCTAssertFalse(DockClickGesturePolicy.isLongPress(elapsed: 0.5))
    }

    func testElapsedThresholdCountsAsLongPress() {
        XCTAssertTrue(DockClickGesturePolicy.isLongPress(
            elapsed: DockClickGesturePolicy.longPressDuration
        ))
    }

    func testSmallMovementIsNotDrag() {
        XCTAssertFalse(DockClickGesturePolicy.isDrag(
            from: CGPoint(x: 10, y: 10),
            to: CGPoint(x: 13, y: 13)
        ))
    }

    func testMovementAtThresholdCountsAsDrag() {
        XCTAssertTrue(DockClickGesturePolicy.isDrag(
            from: CGPoint(x: 10, y: 10),
            to: CGPoint(x: 15, y: 10)
        ))
    }

    func testUnmodifiedMouseClickCanBeHandled() {
        XCTAssertTrue(DockClickGesturePolicy.isPlainPrimaryClick(flags: []))
    }

    func testModifiedMouseClicksPassThroughToDock() {
        XCTAssertFalse(DockClickGesturePolicy.isPlainPrimaryClick(flags: [.maskControl]))
        XCTAssertFalse(DockClickGesturePolicy.isPlainPrimaryClick(flags: [.maskCommand]))
        XCTAssertFalse(DockClickGesturePolicy.isPlainPrimaryClick(flags: [.maskAlternate]))
        XCTAssertFalse(DockClickGesturePolicy.isPlainPrimaryClick(flags: [.maskShift]))
    }

    func testStaleRunCannotClearNewerEventTapRun() {
        var runState = DockEventTapRunState()
        let firstRun = runState.beginRun()
        let secondRun = runState.beginRun()

        XCTAssertFalse(runState.finishRun(firstRun))
        XCTAssertEqual(runState.activeRunIdentifier, secondRun)
        XCTAssertTrue(runState.finishRun(secondRun))
        XCTAssertNil(runState.activeRunIdentifier)
    }

    func testEventTapRunIdentifiersRemainMonotonicUnderStress() {
        var runState = DockEventTapRunState()
        var previousRun: UInt64 = 0

        for _ in 0..<1_200 {
            let run = runState.beginRun()
            XCTAssertGreaterThan(run, previousRun)
            if previousRun > 0 {
                XCTAssertFalse(runState.finishRun(previousRun))
                XCTAssertEqual(runState.activeRunIdentifier, run)
            }
            XCTAssertTrue(runState.finishRun(run))
            previousRun = run
        }
    }

    func testShortClickExecutesResolvedAction() {
        var stateMachine = DockClickGestureStateMachine()
        let target = gestureTarget(processIdentifier: 101, tile: "primary")

        let down = stateMachine.mouseDown(
            target: target,
            point: CGPoint(x: 20, y: 20),
            timestamp: 1
        )
        let up = stateMachine.mouseUp(target: target, timestamp: 1.2)

        XCTAssertEqual(down.disposition, .swallow)
        XCTAssertNotNil(down.scheduleLongPressSequence)
        XCTAssertEqual(up.disposition, .swallow)
        XCTAssertEqual(up.actionTarget, target.target)
        XCTAssertNil(up.replayMouseDownSequence)
        XCTAssertFalse(stateMachine.hasPendingGesture)
    }

    func testMissingReleaseSnapshotFailsOpen() {
        var stateMachine = DockClickGestureStateMachine()
        let down = stateMachine.mouseDown(
            target: gestureTarget(processIdentifier: 101, tile: "primary"),
            point: CGPoint(x: 20, y: 20),
            timestamp: 1
        )

        let up = stateMachine.mouseUp(target: nil, timestamp: 1.2)

        XCTAssertEqual(up.disposition, .passThrough)
        XCTAssertEqual(up.replayMouseDownSequence, down.scheduleLongPressSequence)
        XCTAssertNil(up.actionTarget)
    }

    func testDifferentReleaseTargetFailsOpen() {
        var stateMachine = DockClickGestureStateMachine()
        let down = stateMachine.mouseDown(
            target: gestureTarget(processIdentifier: 101, tile: "primary"),
            point: CGPoint(x: 20, y: 20),
            timestamp: 1
        )

        let up = stateMachine.mouseUp(
            target: gestureTarget(processIdentifier: 102, tile: "secondary"),
            timestamp: 1.2
        )

        XCTAssertEqual(up.disposition, .passThrough)
        XCTAssertEqual(up.replayMouseDownSequence, down.scheduleLongPressSequence)
        XCTAssertNil(up.actionTarget)
    }

    func testLongPressReplaysMouseDownOnce() throws {
        var stateMachine = DockClickGestureStateMachine()
        let target = gestureTarget(processIdentifier: 101, tile: "primary")
        let down = stateMachine.mouseDown(
            target: target,
            point: CGPoint(x: 20, y: 20),
            timestamp: 1
        )
        let sequence = try XCTUnwrap(down.scheduleLongPressSequence)

        let elapsed = stateMachine.longPressElapsed(sequence: sequence)
        let duplicateTimer = stateMachine.longPressElapsed(sequence: sequence)
        let up = stateMachine.mouseUp(target: target, timestamp: 2)

        XCTAssertEqual(elapsed.replayMouseDownSequence, sequence)
        XCTAssertNil(duplicateTimer.replayMouseDownSequence)
        XCTAssertEqual(up.disposition, .passThrough)
        XCTAssertNil(up.replayMouseDownSequence)
        XCTAssertNil(up.actionTarget)
    }

    func testDragReplaysMouseDownBeforePassingDrag() {
        var stateMachine = DockClickGestureStateMachine()
        let target = gestureTarget(processIdentifier: 101, tile: "primary")
        let down = stateMachine.mouseDown(
            target: target,
            point: CGPoint(x: 20, y: 20),
            timestamp: 1
        )

        let drag = stateMachine.mouseDragged(to: CGPoint(x: 26, y: 20))
        let up = stateMachine.mouseUp(target: target, timestamp: 1.3)

        XCTAssertEqual(drag.disposition, .passThrough)
        XCTAssertEqual(drag.replayMouseDownSequence, down.scheduleLongPressSequence)
        XCTAssertEqual(up.disposition, .passThrough)
        XCTAssertNil(up.replayMouseDownSequence)
        XCTAssertNil(up.actionTarget)
    }

    func testCancellationReplaysPendingMouseDown() {
        var stateMachine = DockClickGestureStateMachine()
        let down = stateMachine.mouseDown(
            target: gestureTarget(processIdentifier: 101, tile: "primary"),
            point: CGPoint(x: 20, y: 20),
            timestamp: 1
        )

        let cancellation = stateMachine.cancelPendingGesture()

        XCTAssertEqual(cancellation.replayMouseDownSequence, down.scheduleLongPressSequence)
        XCTAssertFalse(stateMachine.hasPendingGesture)
    }

    func testCancellationAfterLongPressDoesNotReplayMouseDownTwice() throws {
        var stateMachine = DockClickGestureStateMachine()
        let down = stateMachine.mouseDown(
            target: gestureTarget(processIdentifier: 101, tile: "primary"),
            point: CGPoint(x: 20, y: 20),
            timestamp: 1
        )
        let sequence = try XCTUnwrap(down.scheduleLongPressSequence)

        XCTAssertEqual(
            stateMachine.longPressElapsed(sequence: sequence).replayMouseDownSequence,
            sequence
        )
        let cancellation = stateMachine.cancelPendingGesture()

        XCTAssertNil(cancellation.replayMouseDownSequence)
        XCTAssertEqual(cancellation.discardMouseDownSequence, sequence)
        XCTAssertFalse(stateMachine.hasPendingGesture)
    }

    func testStaleLongPressCallbackCannotAffectNextGesture() throws {
        var stateMachine = DockClickGestureStateMachine()
        let target = gestureTarget(processIdentifier: 101, tile: "primary")
        let firstDown = stateMachine.mouseDown(
            target: target,
            point: CGPoint(x: 20, y: 20),
            timestamp: 1
        )
        let firstSequence = try XCTUnwrap(firstDown.scheduleLongPressSequence)
        _ = stateMachine.mouseUp(target: target, timestamp: 1.1)

        let secondDown = stateMachine.mouseDown(
            target: target,
            point: CGPoint(x: 20, y: 20),
            timestamp: 2
        )
        let secondSequence = try XCTUnwrap(secondDown.scheduleLongPressSequence)
        let staleTimer = stateMachine.longPressElapsed(sequence: firstSequence)

        XCTAssertNil(staleTimer.replayMouseDownSequence)
        XCTAssertTrue(stateMachine.hasPendingGesture)
        XCTAssertEqual(
            stateMachine.cancelPendingGesture().replayMouseDownSequence,
            secondSequence
        )
    }

    func testTapDisabledReplaysPendingMouseDownExactlyOnce() throws {
        let recorder = DockEventReplayRecorder()
        let store = DockInteractionSnapshotStore()
        let target = gestureTarget(processIdentifier: 101, tile: "primary").target
        let now = DockInteractionClock.now()
        store.publish(DockInteractionSnapshotPublication(
            generation: 1,
            hotTarget: DockInteractionHotTargetSnapshot(
                target: target,
                eventTapFrame: CGRect(x: 0, y: 0, width: 40, height: 40),
                shouldHandle: true,
                refreshedAt: now,
                inventoryRefreshedAt: now
            )
        ))
        let snapshotService = DockInteractionSnapshotService(
            snapshotStore: store,
            inventoryProvider: { [] },
            targetEvaluator: { target in
                DockInteractionEvaluatedTarget(target: target, shouldHandle: true)
            },
            pointerLocationProvider: { nil }
        )
        let settings = makeSettings()
        let eventTap = DockClickEventTap(
            settings: settings,
            snapshotService: snapshotService,
            eventPoster: { recorder.record($0) },
            actionHandler: { _ in }
        )
        let mouseDown = try XCTUnwrap(CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDown,
            mouseCursorPosition: CGPoint(x: 20, y: 20),
            mouseButton: .left
        ))

        XCTAssertNil(eventTap.handle(type: .leftMouseDown, event: mouseDown))
        XCTAssertEqual(recorder.count, 0)

        _ = eventTap.handle(type: .tapDisabledByTimeout, event: mouseDown)
        _ = eventTap.handle(type: .tapDisabledByTimeout, event: mouseDown)

        XCTAssertEqual(recorder.count, 1)
    }

    func testDeterministicGestureStressSequences() throws {
        var stateMachine = DockClickGestureStateMachine()
        let target = gestureTarget(processIdentifier: 101, tile: "primary")
        let otherTarget = gestureTarget(processIdentifier: 102, tile: "secondary")

        for index in 0..<1_200 {
            let baseTime = TimeInterval(index)
            let down = stateMachine.mouseDown(
                target: target,
                point: CGPoint(x: 20, y: 20),
                timestamp: baseTime
            )
            let sequence = try XCTUnwrap(down.scheduleLongPressSequence)

            switch index % 6 {
            case 0:
                let up = stateMachine.mouseUp(target: target, timestamp: baseTime + 0.1)
                XCTAssertEqual(up.disposition, .swallow)
                XCTAssertEqual(up.actionTarget, target.target)
                XCTAssertNil(up.replayMouseDownSequence)
            case 1:
                let timer = stateMachine.longPressElapsed(sequence: sequence)
                let up = stateMachine.mouseUp(target: target, timestamp: baseTime + 0.8)
                XCTAssertEqual(timer.replayMouseDownSequence, sequence)
                XCTAssertEqual(up.disposition, .passThrough)
                XCTAssertNil(up.actionTarget)
            case 2:
                let drag = stateMachine.mouseDragged(to: CGPoint(x: 26, y: 20))
                let up = stateMachine.mouseUp(target: target, timestamp: baseTime + 0.2)
                XCTAssertEqual(drag.replayMouseDownSequence, sequence)
                XCTAssertEqual(up.disposition, .passThrough)
            case 3:
                let up = stateMachine.mouseUp(target: nil, timestamp: baseTime + 0.1)
                XCTAssertEqual(up.replayMouseDownSequence, sequence)
                XCTAssertEqual(up.disposition, .passThrough)
            case 4:
                let up = stateMachine.mouseUp(target: otherTarget, timestamp: baseTime + 0.1)
                XCTAssertEqual(up.replayMouseDownSequence, sequence)
                XCTAssertEqual(up.disposition, .passThrough)
            default:
                let repeatedDown = stateMachine.mouseDown(
                    target: target,
                    point: CGPoint(x: 20, y: 20),
                    timestamp: baseTime + 0.05
                )
                XCTAssertEqual(repeatedDown.replayMouseDownSequence, sequence)
                XCTAssertEqual(repeatedDown.disposition, .passThrough)
            }

            XCTAssertFalse(stateMachine.hasPendingGesture)
        }
    }

    private func gestureTarget(processIdentifier: pid_t, tile: String) -> DockClickGestureTarget {
        DockClickGestureTarget(target: DockAppTarget(
            processIdentifier: processIdentifier,
            bundleIdentifier: "com.example.\(tile)",
            localizedName: tile,
            dockElementTitle: tile,
            hitPoint: CGPoint(x: 20, y: 20),
            dockItemFrame: CGRect(x: 0, y: 0, width: 40, height: 40),
            dockTileIdentifierOverride: "dock-item:\(tile)"
        ))
    }

    private func makeSettings() -> SettingsStore {
        let suiteName = "DockClickGesturePolicyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = SettingsStore(defaults: defaults, livePreviewLimitProvider: { 6 })
        settings.toggleAppVisibilityOnDockClick = true
        return settings
    }
}

private final class DockEventReplayRecorder {
    private let lock = NSLock()
    private var events: [CGEvent] = []

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return events.count
    }

    func record(_ event: CGEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }
}
