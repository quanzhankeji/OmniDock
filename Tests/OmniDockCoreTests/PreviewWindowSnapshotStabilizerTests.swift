import XCTest
@testable import OmniDockCore

final class PreviewWindowSnapshotStabilizerTests: XCTestCase {
    func testSameCountWithDifferentWindowIdentityRequiresConfirmation() {
        var stabilizer = PreviewWindowSnapshotStabilizer()
        stabilizer.reset(acceptedIdentities: [identity(1)])

        XCTAssertEqual(stabilizer.evaluate([identity(2)]), .pending)
        XCTAssertEqual(stabilizer.evaluate([identity(2)]), .apply)
        XCTAssertEqual(stabilizer.acceptedIdentities, [identity(2)])
    }

    func testTransientIdentityExpansionDoesNotChangeAcceptedSnapshot() {
        var stabilizer = PreviewWindowSnapshotStabilizer()
        let accepted: Set<PreviewWindowIdentity> = [identity(1)]
        stabilizer.reset(acceptedIdentities: accepted)

        XCTAssertEqual(stabilizer.evaluate([identity(1), identity(2), identity(3), identity(4)]), .pending)
        XCTAssertEqual(stabilizer.evaluate(accepted), .unchanged)
        XCTAssertEqual(stabilizer.acceptedIdentities, accepted)
    }

    func testEmptySnapshotMustBeObservedTwice() {
        var stabilizer = PreviewWindowSnapshotStabilizer()
        stabilizer.reset(acceptedIdentities: [identity(1)])

        XCTAssertEqual(stabilizer.evaluate([]), .pending)
        XCTAssertEqual(stabilizer.evaluate([]), .apply)
        XCTAssertEqual(stabilizer.acceptedIdentities, [])
    }

    func testTitleFrameAndOrderChangesDoNotChangeStrongIdentitySet() {
        let first = PreviewWindowSnapshot(
            windows: [window(1, title: "First"), window(2, title: "Second")],
            captureWindows: [:]
        )
        let reordered = PreviewWindowSnapshot(
            windows: [
                window(2, title: "Renamed", frame: CGRect(x: 20, y: 30, width: 900, height: 700)),
                window(1, title: "First", frame: CGRect(x: 5, y: 10, width: 700, height: 500))
            ],
            captureWindows: [:]
        )
        var stabilizer = PreviewWindowSnapshotStabilizer()
        stabilizer.reset(acceptedIdentities: first.identities)

        XCTAssertEqual(first.identities, reordered.identities)
        XCTAssertNotEqual(first.presentations, reordered.presentations)
        XCTAssertEqual(stabilizer.evaluate(reordered.identities), .unchanged)
    }

    func testPreviewRequestRejectsStaleGenerationOrChangedDockTile() {
        XCTAssertFalse(PreviewRequestValidationPolicy.accepts(
            responseGeneration: 4,
            currentGeneration: 5,
            isSameDockTile: true
        ))
        XCTAssertFalse(PreviewRequestValidationPolicy.accepts(
            responseGeneration: 5,
            currentGeneration: 5,
            isSameDockTile: false
        ))
        XCTAssertTrue(PreviewRequestValidationPolicy.accepts(
            responseGeneration: 5,
            currentGeneration: 5,
            isSameDockTile: true
        ))
    }

    private func identity(_ windowID: CGWindowID) -> PreviewWindowIdentity {
        .window(processIdentifier: 42, windowID: windowID)
    }

    private func window(
        _ windowID: CGWindowID,
        title: String,
        frame: CGRect = CGRect(x: 0, y: 0, width: 800, height: 600)
    ) -> PreviewWindowInfo {
        PreviewWindowInfo(
            id: "window-\(windowID)",
            windowID: windowID,
            processIdentifier: 42,
            appName: "Test App",
            title: title,
            frame: frame,
            isMinimized: false
        )
    }
}
