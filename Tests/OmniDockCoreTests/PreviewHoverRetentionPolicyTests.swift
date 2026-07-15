import XCTest
@testable import OmniDockCore

final class PreviewHoverRetentionPolicyTests: XCTestCase {
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
