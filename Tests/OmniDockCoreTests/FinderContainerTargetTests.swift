import XCTest
@testable import OmniDockCore

final class FinderContainerTargetTests: XCTestCase {

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
