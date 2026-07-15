import XCTest
@testable import OmniDockCore

@MainActor
final class PreviewPanelRootViewTests: XCTestCase {
    func testRootViewIsTransparentAndNonOpaque() {
        let view = PreviewPanelRootView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))

        XCTAssertFalse(view.isOpaque)
        XCTAssertTrue(view.wantsLayer)

        XCTAssertEqual(view.layer?.backgroundColor?.alpha, 0)
    }
}
