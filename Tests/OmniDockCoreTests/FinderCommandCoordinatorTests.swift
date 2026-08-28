import XCTest
@testable import OmniDockCore

@MainActor
final class FinderCommandCoordinatorTests: XCTestCase {
    func testCoordinatorCreatesDocumentInsideConfiguredObservationRoot() throws {
        let root = try makeTemporaryDirectory()
        let destination = root.appendingPathComponent("Allowed", isDirectory: true)
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let preferences = makePreferencesStore(
            FinderMenuPreferences(
                isEnabled: true,
                observationRootPaths: [destination.path]
            )
        )

        let mailbox = FinderCommandMailbox(directoryProvider: { root })
        let request = FinderCommandEnvelope(
            command: .createDocument(
                fileExtension: "txt",
                directoryDisplayPath: destination.path
            )
        )
        try mailbox.enqueue(request)

        let grantStore = FinderDirectoryGrantStore(defaults: isolatedDefaults())
        try grantStore.remember(directory: destination)

        var revealedFiles: [URL] = []
        FinderFileCommandCoordinator(
            requestMailbox: mailbox,
            preferencesStore: preferences,
            directoryGrantStore: grantStore,
            homeDirectory: root.appendingPathComponent("Home", isDirectory: true),
            revealFiles: { revealedFiles = $0 }
        ).handle(requestID: request.id)

        let createdFile = destination.appendingPathComponent("NewFile.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: createdFile.path))
        XCTAssertEqual(revealedFiles, [createdFile])
        XCTAssertNil(mailbox.take(id: request.id))
    }

    func testCoordinatorRejectsDocumentOutsideConfiguredObservationRoots() throws {
        let root = try makeTemporaryDirectory()
        let allowed = root.appendingPathComponent("Allowed", isDirectory: true)
        let destination = root.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let preferences = makePreferencesStore(
            FinderMenuPreferences(
                isEnabled: true,
                observationRootPaths: [allowed.path]
            )
        )
        let mailbox = FinderCommandMailbox(directoryProvider: { root })
        let request = FinderCommandEnvelope(
            command: .createDocument(
                fileExtension: "txt",
                directoryDisplayPath: destination.path
            )
        )
        try mailbox.enqueue(request)

        let grantStore = FinderDirectoryGrantStore(defaults: isolatedDefaults())
        try grantStore.remember(directory: allowed)

        var didReveal = false
        FinderFileCommandCoordinator(
            requestMailbox: mailbox,
            preferencesStore: preferences,
            directoryGrantStore: grantStore,
            homeDirectory: root.appendingPathComponent("Home", isDirectory: true),
            revealFiles: { _ in didReveal = true }
        ).handle(requestID: request.id)

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("NewFile.txt").path
            )
        )
        XCTAssertFalse(didReveal)
        XCTAssertNil(mailbox.take(id: request.id))
    }

    func testObservationRootPathAloneDoesNotAuthorizeACommand() throws {
        let root = try makeTemporaryDirectory()
        let injected = root.appendingPathComponent("Injected", isDirectory: true)
        try FileManager.default.createDirectory(at: injected, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // The observation root list lives in the shared app-group defaults,
        // which any process running as this user can write. Without a matching
        // security-scoped bookmark it must not grant write access.
        let preferences = makePreferencesStore(
            FinderMenuPreferences(
                isEnabled: true,
                observationRootPaths: [injected.path]
            )
        )
        let mailbox = FinderCommandMailbox(directoryProvider: { root })
        let request = FinderCommandEnvelope(
            command: .createDocument(
                fileExtension: "txt",
                directoryDisplayPath: injected.path
            )
        )
        try mailbox.enqueue(request)

        var didReveal = false
        FinderFileCommandCoordinator(
            requestMailbox: mailbox,
            preferencesStore: preferences,
            directoryGrantStore: FinderDirectoryGrantStore(defaults: isolatedDefaults()),
            homeDirectory: root.appendingPathComponent("Home", isDirectory: true),
            revealFiles: { _ in didReveal = true }
        ).handle(requestID: request.id)

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: injected.appendingPathComponent("NewFile.txt").path
            )
        )
        XCTAssertFalse(didReveal)
    }

    func testAuthorizationUsesSavedShortcutInsteadOfMailboxPayload() {
        let configured = FinderLaunchShortcut(
            displayName: "Allowed Editor",
            bundleURLString: URL(fileURLWithPath: "/Applications/Allowed.app").absoluteString,
            bundleIdentifier: "example.allowed"
        )
        let forged = FinderLaunchShortcut(
            id: configured.id,
            displayName: "Forged Editor",
            bundleURLString: URL(fileURLWithPath: "/Applications/Forged.app").absoluteString,
            bundleIdentifier: "example.forged"
        )
        let preferences = FinderMenuPreferences(launchShortcuts: [configured])

        XCTAssertEqual(
            FinderCommandAuthorizationPolicy.launchShortcut(
                matching: forged,
                preferences: preferences
            ),
            configured
        )
    }

    func testAuthorizationRejectsDisabledDocumentPreset() {
        var preferences = FinderMenuPreferences()
        preferences.documentPresets = preferences.documentPresets.map { preset in
            var preset = preset
            if preset.fileExtension == "txt" {
                preset.isEnabled = false
            }
            return preset
        }

        XCTAssertNil(
            FinderCommandAuthorizationPolicy.documentPreset(
                for: "txt",
                preferences: preferences
            )
        )
    }

    func testAuthorizationDoesNotTreatFilesystemObservationRootAsACommandRoot() throws {
        let root = try makeTemporaryDirectory()
        let home = root.appendingPathComponent("Home", isDirectory: true)
        let unrelated = root.appendingPathComponent("Unrelated", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertFalse(
            FinderCommandAuthorizationPolicy.isAllowedTarget(
                unrelated,
                authorizedDirectoryPaths: [],
                homeDirectory: home
            )
        )
    }

    func testAuthorizationRejectsSymlinkThatEscapesAnAllowedRoot() throws {
        let root = try makeTemporaryDirectory()
        let allowed = root.appendingPathComponent("Allowed", isDirectory: true)
        let outside = root.appendingPathComponent("Outside", isDirectory: true)
        let escapingLink = allowed.appendingPathComponent("EscapingLink", isDirectory: true)
        try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: escapingLink,
            withDestinationURL: outside
        )
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertFalse(
            FinderCommandAuthorizationPolicy.isAllowedTarget(
                escapingLink,
                authorizedDirectoryPaths: [allowed.path],
                homeDirectory: root.appendingPathComponent("Home", isDirectory: true)
            )
        )
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

    private func makePreferencesStore(
        _ preferences: FinderMenuPreferences
    ) -> FinderMenuPreferencesStore {
        let defaults = isolatedDefaults()
        let store = FinderMenuPreferencesStore(
            suiteName: "OmniDockTests.FinderCommands.\(UUID().uuidString)",
            defaultsProvider: { defaults }
        )
        store.update(preferences)
        return store
    }
}
