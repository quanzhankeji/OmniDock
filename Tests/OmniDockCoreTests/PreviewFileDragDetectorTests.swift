import AppKit
import XCTest
@testable import OmniDockCore

final class PreviewFileDragDetectorTests: XCTestCase {
    func testDetectsModernFileURLDrag() {
        XCTAssertTrue(PreviewFileDragDetector.containsFileDrag(types: [.fileURL]))
    }

    func testDetectsFinderFilenamesDrag() {
        XCTAssertTrue(PreviewFileDragDetector.containsFileDrag(types: [
            PreviewFileDragDetector.finderFilenamesType
        ]))
    }

    func testIgnoresNonFileDragTypes() {
        XCTAssertFalse(PreviewFileDragDetector.containsFileDrag(types: [.string]))
    }
}
