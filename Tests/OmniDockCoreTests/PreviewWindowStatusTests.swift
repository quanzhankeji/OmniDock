import AppKit
import XCTest
@testable import OmniDockCore

final class PreviewWindowStatusTests: XCTestCase {
    func testDisplayNameRequiresUnambiguousPositiveIntersection() {
        let displays = [
            PreviewDisplay(name: "Left", frame: CGRect(x: -1200, y: 0, width: 1200, height: 900)),
            PreviewDisplay(name: "Main", frame: CGRect(x: 0, y: 0, width: 1600, height: 1000))
        ]
        XCTAssertEqual(PreviewWindowStatus.displayName(
            for: CGRect(x: -400, y: 100, width: 600, height: 500), in: displays
        ), "Left")
        XCTAssertNil(PreviewWindowStatus.displayName(
            for: CGRect(x: -300, y: 100, width: 600, height: 500), in: displays
        ))
        XCTAssertNil(PreviewWindowStatus.displayName(
            for: CGRect(x: 2000, y: 100, width: 600, height: 500), in: displays
        ))
        XCTAssertNil(PreviewWindowStatus.displayName(for: .zero, in: displays))
    }

    func testQuartzCoordinatesCoverDisplaysAboveAndBelowThePrimaryScreen() {
        let displays = [
            PreviewDisplay(name: "Above", frame: CGRect(x: 0, y: -900, width: 1600, height: 900)),
            PreviewDisplay(name: "Main", frame: CGRect(x: 0, y: 0, width: 1600, height: 1000)),
            PreviewDisplay(name: "Below", frame: CGRect(x: 0, y: 1000, width: 1600, height: 900))
        ]
        for (y, name) in [(-500, "Above"), (100, "Main"), (1200, "Below")] {
            XCTAssertEqual(PreviewWindowStatus.displayName(
                for: CGRect(x: 100, y: y, width: 600, height: 300), in: displays
            ), name)
        }
    }

    func testMirroredOrInvalidGeometryDoesNotInventDisplayOwnership() {
        let frame = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        let displays = [PreviewDisplay(name: "Main", frame: frame), PreviewDisplay(name: "Mirror", frame: frame)]
        XCTAssertNil(PreviewWindowStatus.displayName(for: frame, in: displays))
        for invalid in [CGRect.null, .infinite, CGRect(x: 0, y: 0, width: -2, height: 20)] {
            XCTAssertNil(PreviewWindowStatus.displayName(for: invalid, in: [displays[0]]), "Invalid frame: \(invalid)")
            XCTAssertNil(PreviewWindowStatus.displayName(for: frame, in: [PreviewDisplay(name: "Invalid", frame: invalid)]))
        }
        XCTAssertNil(PreviewWindowStatus.displayName(for: frame, in: []))
    }

    func testScreenSizedWindowIsNotAssumedToBeFullScreen() {
        let frame = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        let info = PreviewWindowInfo(id: "window", windowID: 1, processIdentifier: 42,
                                     appName: "Editor", title: "Document", frame: frame, isMinimized: false)
        let text = PreviewWindowStatus.text(for: info, displays: [PreviewDisplay(name: "Main", frame: frame)])
        XCTAssertFalse(text.contains(AppStrings.text(.previewStateFullScreen)))
        XCTAssertFalse(text.contains(AppStrings.text(.previewStateHidden)))
        XCTAssertEqual(text, AppStrings.format(.previewDisplay, "Main"))
    }
}

final class PreviewWindowStateMatchingTests: XCTestCase {
    func testAmbiguousOrConflictingIdentitiesDoNotBorrowState() {
        let source = window(id: 10, hidden: true, fullScreen: true)
        let conflict = window(id: 20)
        let otherProcess = window(id: 10, pid: 99)
        for surface in [conflict, otherProcess] {
            let result = PreviewWindowCatalog.applyingAccessibilityState(to: surface, axWindows: [source])
            XCTAssertNil(result.isFullScreen)
            XCTAssertNil(result.isApplicationHidden)
        }
        let missingID = window(id: nil)
        let ambiguous = PreviewWindowCatalog.applyingAccessibilityState(to: missingID, axWindows: [source, source])
        XCTAssertNil(ambiguous.isFullScreen)
        let unique = PreviewWindowCatalog.applyingAccessibilityState(to: missingID, axWindows: [source])
        XCTAssertEqual(unique.isFullScreen, true)
    }

    func testStatusChangesInvalidatePresentationWithoutChangingWindowIdentity() {
        let initial = window(id: 10)
        for updated in [window(id: 10, hidden: true), window(id: 10, fullScreen: true)] {
            XCTAssertEqual(PreviewWindowIdentity(initial), PreviewWindowIdentity(updated))
            XCTAssertNotEqual(PreviewWindowPresentation(initial), PreviewWindowPresentation(updated))
        }
    }

    private func window(id: CGWindowID?, pid: pid_t = 42, hidden: Bool? = nil, fullScreen: Bool? = nil) -> PreviewWindowInfo {
        PreviewWindowInfo(id: "document", windowID: id, processIdentifier: pid, appName: "Editor",
                          title: "Document", frame: CGRect(x: 0, y: 0, width: 800, height: 600), isMinimized: false,
                          isApplicationHidden: hidden, isFullScreen: fullScreen)
    }
}
