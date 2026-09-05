import AppKit
import XCTest
@testable import OmniDockCore

final class DockTargetCandidatePolicyTests: XCTestCase {
    // This app switches to a regular presentation while its settings window is
    // open, and that is exactly when its tile should offer a preview.
    func testAnApplicationShowingATileCanBePreviewed() {
        XCTAssertTrue(
            DockTargetCandidatePolicy.isPreviewable(activationPolicy: .regular)
        )
    }

    func testApplicationsWithNoTileAreNotPreviewable() {
        for policy: NSApplication.ActivationPolicy in [.accessory, .prohibited] {
            XCTAssertFalse(
                DockTargetCandidatePolicy.isPreviewable(activationPolicy: policy),
                "\(policy.rawValue)"
            )
        }
    }
}

final class DockTargetOwnershipPolicyTests: XCTestCase {
    // Still true, but it now governs only whether to take over a click aimed
    // at this app - previews no longer ask.
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
