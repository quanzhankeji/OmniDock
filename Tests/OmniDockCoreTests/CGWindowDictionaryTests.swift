import CoreGraphics
import XCTest
@testable import OmniDockCore

final class CGWindowDictionaryTests: XCTestCase {
    func testFrameReadsDictionaryBounds() {
        let window: [String: Any] = [
            kCGWindowBounds as String: [
                "X": 10,
                "Y": 20,
                "Width": 300,
                "Height": 200
            ]
        ]

        XCTAssertEqual(
            CGWindowDictionary.frame(from: window),
            CGRect(x: 10, y: 20, width: 300, height: 200)
        )
    }

    func testFrameReadsNSDictionaryBounds() {
        let window: [String: Any] = [
            kCGWindowBounds as String: [
                "X": 10,
                "Y": 20,
                "Width": 300,
                "Height": 200
            ] as NSDictionary
        ]

        XCTAssertEqual(
            CGWindowDictionary.frame(from: window),
            CGRect(x: 10, y: 20, width: 300, height: 200)
        )
    }
}
