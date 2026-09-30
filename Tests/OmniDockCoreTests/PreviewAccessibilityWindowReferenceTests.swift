import ApplicationServices
import XCTest
@testable import OmniDockCore

final class PreviewAccessibilityWindowReferenceTests: XCTestCase {
    private let launchDate = Date(timeIntervalSince1970: 100)

    func testResolvesOnlyTheRetainedElementFromCurrentWindows() throws {
        // Application elements stand in for opaque AX identities; no live AX query is needed.
        let target = AXUIElementCreateApplication(101)
        let other = AXUIElementCreateApplication(102)
        let reference = PreviewAccessibilityWindowReference(
            element: target, processIdentifier: 101, applicationLaunchDate: launchDate
        )
        for windows in [[other, target], [target, other]] {
            let resolved = try XCTUnwrap(reference.resolve(
                in: windows, processIdentifier: 101, applicationLaunchDate: launchDate
            ))
            XCTAssertTrue(CFEqual(resolved, target))
        }
        XCTAssertNil(reference.resolve(
            in: [other], processIdentifier: 101, applicationLaunchDate: launchDate
        ))
    }

    func testRejectsRelaunchedProcessesAndUnknownLaunchDates() {
        let target = AXUIElementCreateApplication(101)
        let reference = PreviewAccessibilityWindowReference(
            element: target, processIdentifier: 101, applicationLaunchDate: launchDate
        )
        for currentLaunchDate in [nil, launchDate.addingTimeInterval(1)] {
            XCTAssertNil(reference.resolve(
                in: [target], processIdentifier: 101, applicationLaunchDate: currentLaunchDate
            ))
        }
        XCTAssertNil(reference.resolve(
            in: [target], processIdentifier: 102, applicationLaunchDate: launchDate
        ))
    }

    func testRejectsAnElementOwnedByAnotherProcess() {
        let target = AXUIElementCreateApplication(102)
        let reference = PreviewAccessibilityWindowReference(
            element: target, processIdentifier: 101, applicationLaunchDate: launchDate
        )
        XCTAssertNil(reference.resolve(
            in: [target], processIdentifier: 101, applicationLaunchDate: launchDate
        ))
    }

    func testUnnumberedIdentitySurvivesRenameAndListReordering() {
        let reference = PreviewAccessibilityWindowReference(
            element: AXUIElementCreateApplication(101), processIdentifier: 101, applicationLaunchDate: launchDate
        )
        func info(id: String, title: String, reference: PreviewAccessibilityWindowReference) -> PreviewWindowInfo {
            PreviewWindowInfo(
                id: id, windowID: nil, processIdentifier: 101, appName: "Editor", title: title,
                frame: .zero, isMinimized: true, accessibilityReference: reference
            )
        }
        let original = info(id: "ax-101-0-Same", title: "Same", reference: reference)
        let renamed = info(id: "ax-101-1-Renamed", title: "Renamed", reference: reference)
        XCTAssertEqual(PreviewWindowIdentity(original), PreviewWindowIdentity(renamed))
        let relaunched = info(id: original.id, title: original.title, reference: PreviewAccessibilityWindowReference(
            element: reference.element, processIdentifier: 101, applicationLaunchDate: launchDate.addingTimeInterval(1)
        ))
        XCTAssertNotEqual(PreviewWindowIdentity(original), PreviewWindowIdentity(relaunched))
    }

    func testEqualAXReferencesHaveEqualHashes() {
        let first = PreviewAccessibilityWindowReference(
            element: AXUIElementCreateApplication(101), processIdentifier: 101, applicationLaunchDate: launchDate
        )
        let second = PreviewAccessibilityWindowReference(
            element: AXUIElementCreateApplication(101), processIdentifier: 101, applicationLaunchDate: launchDate
        )
        XCTAssertEqual(first, second)
        XCTAssertEqual(Set([first, second]).count, 1)
    }
}
