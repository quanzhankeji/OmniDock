import CoreGraphics
import Foundation

struct DockClickGestureTarget: Equatable {
    let target: DockAppTarget

    func matches(_ other: DockClickGestureTarget) -> Bool {
        target.dockTileIdentifier == other.target.dockTileIdentifier
            && target.processIdentifier == other.target.processIdentifier
    }
}

enum DockClickCurrentEventDisposition: Equatable {
    case passThrough
    case swallow
}

struct DockClickGestureDecision: Equatable {
    let disposition: DockClickCurrentEventDisposition
    let replayMouseDownSequence: UInt64?
    let discardMouseDownSequence: UInt64?
    let actionTarget: DockAppTarget?
    let scheduleLongPressSequence: UInt64?

    static let passThrough = DockClickGestureDecision(
        disposition: .passThrough,
        replayMouseDownSequence: nil,
        discardMouseDownSequence: nil,
        actionTarget: nil,
        scheduleLongPressSequence: nil
    )

    static let swallow = DockClickGestureDecision(
        disposition: .swallow,
        replayMouseDownSequence: nil,
        discardMouseDownSequence: nil,
        actionTarget: nil,
        scheduleLongPressSequence: nil
    )
}

struct DockClickGestureStateMachine {
    private struct PendingGesture {
        let sequence: UInt64
        let target: DockClickGestureTarget
        let downPoint: CGPoint
        let beganAt: TimeInterval
        var hasReplayedMouseDown: Bool
    }

    private var nextSequence: UInt64 = 0
    private var pendingGesture: PendingGesture?

    var hasPendingGesture: Bool {
        pendingGesture != nil
    }

    mutating func mouseDown(
        target: DockClickGestureTarget?,
        point: CGPoint,
        timestamp: TimeInterval
    ) -> DockClickGestureDecision {
        if let pendingGesture {
            self.pendingGesture = nil
            return DockClickGestureDecision(
                disposition: .passThrough,
                replayMouseDownSequence: pendingGesture.hasReplayedMouseDown ? nil : pendingGesture.sequence,
                discardMouseDownSequence: pendingGesture.sequence,
                actionTarget: nil,
                scheduleLongPressSequence: nil
            )
        }

        guard let target else {
            return .passThrough
        }

        nextSequence &+= 1
        let sequence = nextSequence
        pendingGesture = PendingGesture(
            sequence: sequence,
            target: target,
            downPoint: point,
            beganAt: timestamp,
            hasReplayedMouseDown: false
        )
        return DockClickGestureDecision(
            disposition: .swallow,
            replayMouseDownSequence: nil,
            discardMouseDownSequence: nil,
            actionTarget: nil,
            scheduleLongPressSequence: sequence
        )
    }

    mutating func mouseDragged(to point: CGPoint) -> DockClickGestureDecision {
        guard var pendingGesture else {
            return .passThrough
        }
        guard !pendingGesture.hasReplayedMouseDown else {
            return .passThrough
        }
        guard DockClickGesturePolicy.isDrag(from: pendingGesture.downPoint, to: point) else {
            return .swallow
        }

        pendingGesture.hasReplayedMouseDown = true
        self.pendingGesture = pendingGesture
        return DockClickGestureDecision(
            disposition: .passThrough,
            replayMouseDownSequence: pendingGesture.sequence,
            discardMouseDownSequence: nil,
            actionTarget: nil,
            scheduleLongPressSequence: nil
        )
    }

    mutating func mouseUp(
        target: DockClickGestureTarget?,
        timestamp: TimeInterval
    ) -> DockClickGestureDecision {
        guard let pendingGesture else {
            return .passThrough
        }
        self.pendingGesture = nil

        if pendingGesture.hasReplayedMouseDown {
            return DockClickGestureDecision(
                disposition: .passThrough,
                replayMouseDownSequence: nil,
                discardMouseDownSequence: pendingGesture.sequence,
                actionTarget: nil,
                scheduleLongPressSequence: nil
            )
        }

        let elapsed = max(0, timestamp - pendingGesture.beganAt)
        guard !DockClickGesturePolicy.isLongPress(elapsed: elapsed),
              let target,
              pendingGesture.target.matches(target)
        else {
            return DockClickGestureDecision(
                disposition: .passThrough,
                replayMouseDownSequence: pendingGesture.sequence,
                discardMouseDownSequence: pendingGesture.sequence,
                actionTarget: nil,
                scheduleLongPressSequence: nil
            )
        }

        return DockClickGestureDecision(
            disposition: .swallow,
            replayMouseDownSequence: nil,
            discardMouseDownSequence: pendingGesture.sequence,
            actionTarget: target.target,
            scheduleLongPressSequence: nil
        )
    }

    mutating func longPressElapsed(sequence: UInt64) -> DockClickGestureDecision {
        guard var pendingGesture,
              pendingGesture.sequence == sequence,
              !pendingGesture.hasReplayedMouseDown
        else {
            return .swallow
        }

        pendingGesture.hasReplayedMouseDown = true
        self.pendingGesture = pendingGesture
        return DockClickGestureDecision(
            disposition: .swallow,
            replayMouseDownSequence: sequence,
            discardMouseDownSequence: nil,
            actionTarget: nil,
            scheduleLongPressSequence: nil
        )
    }

    mutating func cancelPendingGesture() -> DockClickGestureDecision {
        guard let pendingGesture else {
            return .passThrough
        }
        self.pendingGesture = nil
        return DockClickGestureDecision(
            disposition: .passThrough,
            replayMouseDownSequence: pendingGesture.hasReplayedMouseDown ? nil : pendingGesture.sequence,
            discardMouseDownSequence: pendingGesture.sequence,
            actionTarget: nil,
            scheduleLongPressSequence: nil
        )
    }
}
