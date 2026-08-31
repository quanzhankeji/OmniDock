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

    func testAPathNamingAFileResolvesToTheFolderHoldingIt() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Notes.md")
        try Data("payload".utf8).write(to: file)

        XCTAssertEqual(
            FinderFileCommandCoordinator.enclosingDirectory(for: file.path),
            root.standardizedFileURL
        )
    }

    func testAPathNamingAFolderIsUsedAsGiven() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertEqual(
            FinderFileCommandCoordinator.enclosingDirectory(for: root.path),
            root.standardizedFileURL
        )
    }

    func testAPathThatDoesNotExistIsLeftAlone() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("Gone", isDirectory: true)

        // Creating there fails with an error worth showing, which beats
        // quietly writing the document into some other folder.
        XCTAssertEqual(
            FinderFileCommandCoordinator.enclosingDirectory(for: missing.path).path,
            missing.standardizedFileURL.path
        )
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniDockContainerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url.standardizedFileURL
    }
}
