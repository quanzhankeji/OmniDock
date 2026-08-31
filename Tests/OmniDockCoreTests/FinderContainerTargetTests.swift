import XCTest
@testable import OmniDockCore

final class FinderContainerTargetTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
    private let viewed = URL(fileURLWithPath: "/Users/tester/Projects", isDirectory: true)

    func testEmptySelectionUsesTheTargetedFolder() {
        XCTAssertEqual(
            FinderObservationRoots.containerURL(
                targetedURL: viewed,
                selectedURLs: [],
                homeDirectory: home
            ),
            viewed
        )
    }

    func testSelectedFolderReportedAsTheTargetResolvesToItsParent() {
        // Gallery view hands back the highlighted folder for a right-click on
        // the empty area around it, which would put a new document inside the
        // folder instead of beside it.
        let selected = viewed.appendingPathComponent("Archive", isDirectory: true)

        XCTAssertEqual(
            FinderObservationRoots.containerURL(
                targetedURL: selected,
                selectedURLs: [selected],
                homeDirectory: home
            ),
            viewed
        )
    }

    func testSelectedFileReportedAsTheTargetResolvesToItsFolder() {
        let selected = viewed.appendingPathComponent("Notes.md")

        XCTAssertEqual(
            FinderObservationRoots.containerURL(
                targetedURL: selected,
                selectedURLs: [selected],
                homeDirectory: home
            ),
            viewed
        )
    }

    func testTargetIsMatchedAgainstEverySelectedItem() {
        let first = viewed.appendingPathComponent("First.txt")
        let selected = viewed.appendingPathComponent("Archive", isDirectory: true)

        XCTAssertEqual(
            FinderObservationRoots.containerURL(
                targetedURL: selected,
                selectedURLs: [first, selected],
                homeDirectory: home
            ),
            viewed
        )
    }

    func testAFolderContainingTheSelectionIsLeftAlone() {
        // The ordinary case: the target is the folder on screen and the
        // selection sits inside it, so it must not be stepped up a level.
        XCTAssertEqual(
            FinderObservationRoots.containerURL(
                targetedURL: viewed,
                selectedURLs: [viewed.appendingPathComponent("Notes.md")],
                homeDirectory: home
            ),
            viewed
        )
    }

    func testTrailingSlashesDoNotHideAMatch() {
        let selected = URL(fileURLWithPath: "/Users/tester/Projects/Archive/")

        XCTAssertEqual(
            FinderObservationRoots.containerURL(
                targetedURL: URL(fileURLWithPath: "/Users/tester/Projects/Archive"),
                selectedURLs: [selected],
                homeDirectory: home
            ),
            viewed
        )
    }

    func testNoTargetFallsBackToTheDesktop() {
        XCTAssertEqual(
            FinderObservationRoots.containerURL(
                targetedURL: nil,
                selectedURLs: [],
                homeDirectory: home
            ),
            FinderObservationRoots.desktopURL(homeDirectory: home)
        )
    }
}
