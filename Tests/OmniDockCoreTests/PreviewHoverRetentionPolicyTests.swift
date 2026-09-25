import CoreGraphics
import XCTest
@testable import OmniDockCore

final class PreviewHoverRetentionPolicyTests: XCTestCase {
    func testWidePreviewDoesNotRetainUnrelatedSpaceAlongDock() {
        XCTAssertFalse(PreviewHoverRetentionPolicy.isPointInInteractionRegion(
            CGPoint(x: 140, y: 70),
            dockItemFrame: CGRect(x: 420, y: 24, width: 64, height: 64),
            panelFrame: CGRect(x: 120, y: 160, width: 880, height: 174)
        ))
    }

    func testDiagonalPathFromIconToFarPreviewCardStaysInsideRegion() {
        let start = CGPoint(x: 450, y: 70)
        let end = CGPoint(x: 950, y: 180)
        for step in 0...10 {
            let progress = CGFloat(step) / 10
            let point = CGPoint(x: start.x + (end.x - start.x) * progress,
                                y: start.y + (end.y - start.y) * progress)
            XCTAssertTrue(PreviewHoverRetentionPolicy.isPointInInteractionRegion(
                point,
                dockItemFrame: CGRect(x: 420, y: 24, width: 64, height: 64),
                panelFrame: CGRect(x: 120, y: 160, width: 880, height: 174)
            ), "Diagonal path left the interaction region at \(point)")
        }
    }

    func testSideDocksAndNegativeScreenCoordinatesPreservePathsButRejectEmptyCorners() {
        let dock = CGRect(x: 420, y: 24, width: 64, height: 64)
        let panel = CGRect(x: 120, y: 160, width: 880, height: 174)
        for angle in [CGFloat.zero, .pi / 2, -.pi / 2] {
            let transform = CGAffineTransform(translationX: -1800, y: -900).rotated(by: angle)
            for step in 0...10 {
                let progress = CGFloat(step) / 10
                let point = CGPoint(x: 450 + 500 * progress, y: 70 + 110 * progress)
                XCTAssertTrue(PreviewHoverRetentionPolicy.isPointInInteractionRegion(
                    point.applying(transform),
                    dockItemFrame: dock.applying(transform),
                    panelFrame: panel.applying(transform)
                ))
            }
            XCTAssertFalse(PreviewHoverRetentionPolicy.isPointInInteractionRegion(
                CGPoint(x: 140, y: 70).applying(transform),
                dockItemFrame: dock.applying(transform),
                panelFrame: panel.applying(transform)
            ))
        }
    }

    func testOverlappingFramesAndPanelMarginsRemainUsable() {
        let dock = CGRect(x: 300, y: 24, width: 64, height: 64)
        let panel = CGRect(x: 220, y: 80, width: 280, height: 174)
        for point in [CGPoint(x: 330, y: 80), CGPoint(x: 205, y: 170), CGPoint(x: 330, y: 265)] {
            XCTAssertTrue(PreviewHoverRetentionPolicy.isPointInInteractionRegion(
                point, dockItemFrame: dock, panelFrame: panel
            ))
        }
        XCTAssertFalse(PreviewHoverRetentionPolicy.isPointInInteractionRegion(
            CGPoint(x: 180, y: 170), dockItemFrame: dock, panelFrame: panel
        ))
    }

    func testInteractionRegionIncludesPreviewPanel() {
        let panel = CGRect(x: 220, y: 160, width: 280, height: 174)
        let dockItem = CGRect(x: 300, y: 24, width: 64, height: 64)

        XCTAssertTrue(PreviewHoverRetentionPolicy.isPointInInteractionRegion(
            CGPoint(x: 340, y: 220),
            dockItemFrame: dockItem,
            panelFrame: panel
        ))
    }

    func testInteractionRegionIncludesPathBetweenDockIconAndPanel() {
        let panel = CGRect(x: 220, y: 160, width: 280, height: 174)
        let dockItem = CGRect(x: 300, y: 24, width: 64, height: 64)

        XCTAssertTrue(PreviewHoverRetentionPolicy.isPointInInteractionRegion(
            CGPoint(x: 340, y: 120),
            dockItemFrame: dockItem,
            panelFrame: panel
        ))
    }

    func testInteractionRegionRejectsUnrelatedDesktopPoints() {
        let panel = CGRect(x: 220, y: 160, width: 280, height: 174)
        let dockItem = CGRect(x: 300, y: 24, width: 64, height: 64)

        XCTAssertFalse(PreviewHoverRetentionPolicy.isPointInInteractionRegion(
            CGPoint(x: 820, y: 520),
            dockItemFrame: dockItem,
            panelFrame: panel
        ))
    }
}
