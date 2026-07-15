import XCTest
@testable import OmniDockCore

final class DockGeometryTests: XCTestCase {
    func testLikelyDockAreaCoversAllThreeEdgesAtTheSameTime() {
        let dockGeometry = DockGeometry()
        let screenFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let visibleFrame = CGRect(x: 0, y: 0, width: 1440, height: 877)

        XCTAssertTrue(dockGeometry.isPointInLikelyDockArea(
            CGPoint(x: 720, y: 40),
            screenFrame: screenFrame,
            visibleFrame: visibleFrame
        ))
        XCTAssertTrue(dockGeometry.isPointInLikelyDockArea(
            CGPoint(x: 40, y: 450),
            screenFrame: screenFrame,
            visibleFrame: visibleFrame
        ))
        XCTAssertTrue(dockGeometry.isPointInLikelyDockArea(
            CGPoint(x: 1400, y: 450),
            screenFrame: screenFrame,
            visibleFrame: visibleFrame
        ))
        XCTAssertFalse(dockGeometry.isPointInLikelyDockArea(
            CGPoint(x: 720, y: 450),
            screenFrame: screenFrame,
            visibleFrame: visibleFrame
        ))
    }

    func testLikelyDockAreaUsesVisibleDockGapsAndRejectsMenuBarCorners() {
        let dockGeometry = DockGeometry()
        let screenFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let visibleFrame = CGRect(x: 72, y: 72, width: 1296, height: 805)

        XCTAssertTrue(dockGeometry.isPointInLikelyDockArea(
            CGPoint(x: 180, y: 450),
            screenFrame: screenFrame,
            visibleFrame: visibleFrame
        ))
        XCTAssertTrue(dockGeometry.isPointInLikelyDockArea(
            CGPoint(x: 1260, y: 450),
            screenFrame: screenFrame,
            visibleFrame: visibleFrame
        ))
        XCTAssertTrue(dockGeometry.isPointInLikelyDockArea(
            CGPoint(x: 720, y: 180),
            screenFrame: screenFrame,
            visibleFrame: visibleFrame
        ))
        XCTAssertFalse(dockGeometry.isPointInLikelyDockArea(
            CGPoint(x: 40, y: 890),
            screenFrame: screenFrame,
            visibleFrame: visibleFrame
        ))
        XCTAssertFalse(dockGeometry.isPointInLikelyDockArea(
            CGPoint(x: 1400, y: 890),
            screenFrame: screenFrame,
            visibleFrame: visibleFrame
        ))
    }

    func testEventTapPointsConvertBeforeThreeEdgeDockAreaDetection() {
        let dockGeometry = DockGeometry()
        let screenFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let visibleFrame = CGRect(x: 0, y: 0, width: 1440, height: 877)
        let topPoint = DisplayCoordinateConverter.appKitPoint(
            fromQuartzPoint: CGPoint(x: 720, y: 50),
            quartzDisplayBounds: screenFrame,
            appKitScreenFrame: screenFrame
        )
        let bottomPoint = DisplayCoordinateConverter.appKitPoint(
            fromQuartzPoint: CGPoint(x: 720, y: 850),
            quartzDisplayBounds: screenFrame,
            appKitScreenFrame: screenFrame
        )

        XCTAssertEqual(topPoint, CGPoint(x: 720, y: 850))
        XCTAssertEqual(bottomPoint, CGPoint(x: 720, y: 50))
        XCTAssertFalse(dockGeometry.isPointInLikelyDockArea(
            topPoint,
            screenFrame: screenFrame,
            visibleFrame: visibleFrame
        ))
        XCTAssertTrue(dockGeometry.isPointInLikelyDockArea(
            bottomPoint,
            screenFrame: screenFrame,
            visibleFrame: visibleFrame
        ))
    }

    func testInfersOrientationFromDockItemFrameOnOffsetScreens() {
        let dockGeometry = DockGeometry()
        let leftScreen = CGRect(x: -1728, y: 200, width: 1728, height: 1117)
        let rightScreen = CGRect(x: 1512, y: -240, width: 1920, height: 1080)

        XCTAssertEqual(dockGeometry.inferredOrientation(
            dockItemFrame: CGRect(x: -1000, y: 204, width: 64, height: 64),
            anchor: CGPoint(x: -968, y: 236),
            screenFrame: leftScreen
        ), .bottom)
        XCTAssertEqual(dockGeometry.inferredOrientation(
            dockItemFrame: CGRect(x: 1516, y: 160, width: 64, height: 64),
            anchor: CGPoint(x: 1548, y: 192),
            screenFrame: rightScreen
        ), .left)
        XCTAssertEqual(dockGeometry.inferredOrientation(
            dockItemFrame: CGRect(x: 3364, y: 160, width: 64, height: 64),
            anchor: CGPoint(x: 3396, y: 192),
            screenFrame: rightScreen
        ), .right)
    }

    func testInfersAutoHiddenDockOrientationFromAnchorWhenItemFrameIsUnavailable() {
        let dockGeometry = DockGeometry()
        let screenFrame = CGRect(x: 1440, y: -300, width: 1920, height: 1080)

        XCTAssertEqual(dockGeometry.inferredOrientation(
            dockItemFrame: nil,
            anchor: CGPoint(x: 3352, y: 240),
            screenFrame: screenFrame
        ), .right)
    }

    func testDockClickMonitoringPolicyRequiresEnabledPermissionedUnsuspendedState() {
        XCTAssertFalse(DockClickMonitoringPolicy.shouldInstall(
            isEnabled: false,
            hasRequiredPermissions: true,
            isSuspended: false
        ))
        XCTAssertFalse(DockClickMonitoringPolicy.shouldInstall(
            isEnabled: true,
            hasRequiredPermissions: false,
            isSuspended: false
        ))
        XCTAssertFalse(DockClickMonitoringPolicy.shouldInstall(
            isEnabled: true,
            hasRequiredPermissions: true,
            isSuspended: true
        ))
        XCTAssertTrue(DockClickMonitoringPolicy.shouldInstall(
            isEnabled: true,
            hasRequiredPermissions: true,
            isSuspended: false
        ))
    }
}
