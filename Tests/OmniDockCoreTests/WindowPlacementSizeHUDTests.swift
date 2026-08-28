import XCTest
import AppKit
@testable import OmniDockCore

final class WindowPlacementSizeHUDTests: XCTestCase {
    private let visibleFrame = CGRect(x: 0, y: 0, width: 1_440, height: 850)
    private let contentSize = CGSize(width: 90, height: 26)

    func testOriginTrailsPointerByTheFixedOffset() {
        let origin = WindowPlacementSizeHUDLayout.origin(
            contentSize: contentSize,
            appKitPoint: CGPoint(x: 600, y: 500),
            visibleFrame: visibleFrame
        )
        XCTAssertEqual(
            origin,
            CGPoint(
                x: 600 + WindowPlacementSizeHUDLayout.pointerOffset,
                y: 500 - contentSize.height
                    - WindowPlacementSizeHUDLayout.pointerOffset
            )
        )
    }

    func testOriginStaysInsideTheVisibleFrame() {
        let bottomRight = WindowPlacementSizeHUDLayout.origin(
            contentSize: contentSize,
            appKitPoint: CGPoint(x: 1_439, y: 2),
            visibleFrame: visibleFrame
        )
        XCTAssertEqual(
            bottomRight.x,
            visibleFrame.maxX - contentSize.width
                - WindowPlacementSizeHUDLayout.screenInset
        )
        XCTAssertEqual(
            bottomRight.y,
            visibleFrame.minY + WindowPlacementSizeHUDLayout.screenInset
        )

        let topLeft = WindowPlacementSizeHUDLayout.origin(
            contentSize: contentSize,
            appKitPoint: CGPoint(x: -400, y: 4_000),
            visibleFrame: visibleFrame
        )
        XCTAssertEqual(
            topLeft.x,
            visibleFrame.minX + WindowPlacementSizeHUDLayout.screenInset
        )
        XCTAssertEqual(
            topLeft.y,
            visibleFrame.maxY - contentSize.height
                - WindowPlacementSizeHUDLayout.screenInset
        )
    }

    // Fractional origins let the window server resample the bubble between
    // pixels while it follows the pointer, which reads as shimmer.
    func testOriginSnapsToWholePoints() {
        let origin = WindowPlacementSizeHUDLayout.origin(
            contentSize: contentSize,
            appKitPoint: CGPoint(x: 600.42, y: 500.61),
            visibleFrame: visibleFrame
        )
        XCTAssertEqual(origin.x, origin.x.rounded())
        XCTAssertEqual(origin.y, origin.y.rounded())
    }

    // A Retina display can position a window on its own pixel grid. Snapping
    // to whole points there would advance the bubble two pixels at a time,
    // which is visible as stepping when the pointer moves slowly.
    func testOriginSnapsToTheBackingPixelGrid() {
        let origin = WindowPlacementSizeHUDLayout.origin(
            contentSize: contentSize,
            appKitPoint: CGPoint(x: 600.4, y: 500.1),
            visibleFrame: visibleFrame,
            backingScale: 2
        )
        XCTAssertEqual(origin.x, (origin.x * 2).rounded() / 2)
        XCTAssertEqual(origin.y, (origin.y * 2).rounded() / 2)
        XCTAssertEqual(origin.x, 616.5)
    }

    // The geometry cache is keyed on display bounds, so an entry without them
    // could never match a later pointer position. Storing one would make every
    // following move re-query the window server.
    func testOnlyDisplayBackedGeometryIsReusable() {
        XCTAssertTrue(
            WindowPlacementSizeHUDScreenGeometry(
                quartzBounds: CGRect(x: 0, y: 0, width: 1_440, height: 900),
                appKitFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
                visibleFrame: visibleFrame
            ).isReusable
        )
        XCTAssertFalse(
            WindowPlacementSizeHUDScreenGeometry(
                quartzBounds: .null,
                appKitFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
                visibleFrame: visibleFrame
            ).isReusable
        )
    }

    func testOriginFallsBackToTheRawPlacementWithoutAScreen() {
        let origin = WindowPlacementSizeHUDLayout.origin(
            contentSize: contentSize,
            appKitPoint: CGPoint(x: 120, y: 240),
            visibleFrame: .zero
        )
        XCTAssertEqual(
            origin,
            CGPoint(
                x: 120 + WindowPlacementSizeHUDLayout.pointerOffset,
                y: 240 - contentSize.height
                    - WindowPlacementSizeHUDLayout.pointerOffset
            )
        )
    }

    func testCachedScreenGeometryConvertsAndBoundsChecksPoints() {
        let geometry = WindowPlacementSizeHUDScreenGeometry(
            quartzBounds: CGRect(x: 0, y: 0, width: 1_440, height: 900),
            appKitFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
            visibleFrame: visibleFrame
        )
        XCTAssertTrue(geometry.contains(eventTapPoint: CGPoint(x: 10, y: 10)))
        XCTAssertFalse(
            geometry.contains(eventTapPoint: CGPoint(x: 1_500, y: 10))
        )
        XCTAssertEqual(
            geometry.appKitPoint(fromEventTapPoint: CGPoint(x: 10, y: 100)),
            CGPoint(x: 10, y: 800)
        )
    }

    func testFormatterRoundsToWholePoints() {
        XCTAssertEqual(
            WindowPlacementSizeFormatter.text(
                for: CGSize(width: 1_279.6, height: 719.4)
            ),
            "1280×719"
        )
    }

    // The rapid-motion rules that suppress the bubble must survive the change
    // to coalesced pointer delivery: they are speed based, so merging two
    // events into one sample must not change the verdict.
    func testMotionTrackerReachesTheSameVerdictFromCoalescedSamples() {
        func isRapidAfterSweep(step: CGFloat, samples: Int) -> Bool {
            var tracker = WindowPlacementSizeHUDPolicy.MotionTracker()
            var point = CGPoint(x: 0, y: 0)
            var timestamp: TimeInterval = 0
            let interval = TimeInterval(step) / 2_400
            var isRapid = false
            for _ in 0..<samples {
                let next = CGPoint(x: point.x + step, y: point.y)
                timestamp += interval
                isRapid = tracker.record(
                    from: point,
                    to: next,
                    elapsed: interval,
                    timestamp: timestamp
                )
                point = next
            }
            return isRapid
        }

        XCTAssertTrue(isRapidAfterSweep(step: 20, samples: 40))
        XCTAssertTrue(isRapidAfterSweep(step: 40, samples: 20))
    }
}
