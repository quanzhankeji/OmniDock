import XCTest
@testable import OmniDockCore

@MainActor
final class FinderCommandCoordinatorTests: XCTestCase {
    func testCoordinatorConsumesSignaledCreateCommand() throws {
        let root = try makeTemporaryDirectory()
        let destination = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: destination)
        }

        let preferencesDefaults = isolatedDefaults()
        let preferences = FinderMenuPreferencesStore(
            suiteName: "OmniDockTests.FinderCommands.\(UUID().uuidString)",
            defaultsProvider: { preferencesDefaults }
        )
        preferences.update(FinderMenuPreferences(isEnabled: true))

        let mailbox = FinderCommandMailbox(directoryProvider: { root })
        let request = FinderCommandEnvelope(
            command: .createDocument(
                fileExtension: "txt",
                directoryDisplayPath: destination.path
            )
        )
        try mailbox.enqueue(request)

        let coordinator = FinderFileCommandCoordinator(
            requestMailbox: mailbox,
            preferencesStore: preferences,
            directoryGrantStore: FinderDirectoryGrantStore(defaults: isolatedDefaults())
        )

        coordinator.handle(requestID: request.id)

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("NewFile.txt").path
            )
        )
        XCTAssertNil(mailbox.take(id: request.id))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniDockFinderCommandTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func isolatedDefaults() -> UserDefaults {
        let name = "OmniDockTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }
}
