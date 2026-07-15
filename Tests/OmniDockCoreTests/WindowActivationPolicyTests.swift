import AppKit
import XCTest
@testable import OmniDockCore

final class WindowActivationPolicyTests: XCTestCase {
    func testSingleWindowActivationIgnoresOtherAppsWithoutActivatingAllWindows() {
        let options = WindowActivationPolicy.options(allWindows: false)

        XCTAssertFalse(options.contains(.activateAllWindows))
        if #unavailable(macOS 14.0) {
            XCTAssertTrue(options.contains(.activateIgnoringOtherApps))
        }
    }

    func testAllWindowActivationIncludesAllWindowsAndIgnoresOtherApps() {
        let options = WindowActivationPolicy.options(allWindows: true)

        XCTAssertTrue(options.contains(.activateAllWindows))
        if #unavailable(macOS 14.0) {
            XCTAssertTrue(options.contains(.activateIgnoringOtherApps))
        }
    }
}
