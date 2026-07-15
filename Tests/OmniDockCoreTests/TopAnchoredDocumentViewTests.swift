import XCTest
@testable import OmniDockCore

@MainActor
final class TopAnchoredDocumentViewTests: XCTestCase {
    func testDocumentViewUsesTopDownCoordinates() {
        XCTAssertTrue(TopAnchoredDocumentView().isFlipped)
    }
}
