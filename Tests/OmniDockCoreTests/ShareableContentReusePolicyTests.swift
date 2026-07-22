import XCTest
@testable import OmniDockCore

final class ShareableContentReusePolicyTests: XCTestCase {
    func testCacheIsReusableOnlyInsideItsFreshnessWindow() {
        let capturedAt = Date(timeIntervalSince1970: 100)

        XCTAssertTrue(ShareableContentReusePolicy.canReuse(
            capturedAt: capturedAt,
            now: Date(timeIntervalSince1970: 100.75),
            maximumAge: 0.75
        ))
        XCTAssertFalse(ShareableContentReusePolicy.canReuse(
            capturedAt: capturedAt,
            now: Date(timeIntervalSince1970: 100.751),
            maximumAge: 0.75
        ))
        XCTAssertFalse(ShareableContentReusePolicy.canReuse(
            capturedAt: capturedAt,
            now: Date(timeIntervalSince1970: 99.9),
            maximumAge: 0.75
        ))
    }
}
