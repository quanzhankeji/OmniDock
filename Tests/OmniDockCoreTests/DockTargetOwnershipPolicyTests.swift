import XCTest
@testable import OmniDockCore

final class DockTargetOwnershipPolicyTests: XCTestCase {
    func testCurrentProcessIsNeverHandled() {
        XCTAssertFalse(DockTargetOwnershipPolicy.shouldHandle(
            targetProcessIdentifier: 410,
            currentProcessIdentifier: 410
        ))
    }

    func testDifferentProcessCanBeHandled() {
        XCTAssertTrue(DockTargetOwnershipPolicy.shouldHandle(
            targetProcessIdentifier: 411,
            currentProcessIdentifier: 410
        ))
    }
}
