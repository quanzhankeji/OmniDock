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

        var revealedFiles: [URL] = []
        FinderFileCommandCoordinator(
            requestMailbox: mailbox,
            preferencesStore: preferences,
            directoryGrantStore: FinderDirectoryGrantStore(defaults: isolatedDefaults()),
            revealFiles: { revealedFiles = $0 }
        ).handle(requestID: request.id)

        let createdFile = destination.appendingPathComponent("NewFile.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: createdFile.path))
        XCTAssertEqual(revealedFiles, [createdFile])
        XCTAssertNil(mailbox.take(id: request.id))
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

    func testCoordinatorOpensTheCurrentDirectoryInsteadOfTheSelectedFile() throws {
        let home = try makeTemporaryDirectory()
        let downloads = home.appendingPathComponent("Downloads", isDirectory: true)
        let selectedFile = downloads.appendingPathComponent("Installer.dmg")
        let application = home.appendingPathComponent("Sample.app", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: application, withIntermediateDirectories: true)
        try Data().write(to: selectedFile)
        defer { try? FileManager.default.removeItem(at: home) }

        let shortcut = FinderLaunchShortcut(
            displayName: "Sample App",
            bundleURLString: application.absoluteString,
            bundleIdentifier: "com.example.sample"
        )
        let preferences = makePreferencesStore(FinderMenuPreferences(
            isEnabled: true,
            launchShortcuts: [shortcut]
        ))
        let mailbox = FinderCommandMailbox(directoryProvider: { home })
        let request = FinderCommandEnvelope(command: .openWithApplication(
            shortcut: shortcut,
            displayPaths: [downloads.path]
        ))
        try mailbox.enqueue(request)

        var openedDirectory: URL?
        var openedApplication: URL?
        FinderFileCommandCoordinator(
            requestMailbox: mailbox,
            preferencesStore: preferences,
            directoryGrantStore: FinderDirectoryGrantStore(defaults: isolatedDefaults()),
            openApplication: { targetURLs, applicationURL, completion in
                openedDirectory = targetURLs.first
                openedApplication = applicationURL
                completion(nil)
            }
        ).handle(requestID: request.id)

        XCTAssertEqual(openedDirectory, downloads)
        XCTAssertNotEqual(openedDirectory, selectedFile)
        XCTAssertEqual(openedApplication, application)
    }

    func testAskingForTheFolderIsSkippedOutsideASandbox() throws {
        // The tests run unsandboxed, which is the case that must never prompt:
        // the folder is reachable, so asking would be a dialog for nothing.
        XCTAssertFalse(FinderFileCommandCoordinator.isSandboxed)

        let home = try makeTemporaryDirectory()
        let downloads = home.appendingPathComponent("Downloads", isDirectory: true)
        let application = home.appendingPathComponent("Sample.app", isDirectory: true)
        for url in [downloads, application] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: home) }

        let shortcut = FinderLaunchShortcut(
            displayName: "Sample App",
            bundleURLString: application.absoluteString,
            bundleIdentifier: "com.example.sample"
        )
        let mailbox = FinderCommandMailbox(directoryProvider: { home })
        let request = FinderCommandEnvelope(command: .openWithApplication(
            shortcut: shortcut,
            displayPaths: [downloads.path]
        ))
        try mailbox.enqueue(request)

        var promptCount = 0
        var openedTargets: [URL] = []
        FinderFileCommandCoordinator(
            requestMailbox: mailbox,
            preferencesStore: makePreferencesStore(FinderMenuPreferences(
                isEnabled: true,
                launchShortcuts: [shortcut]
            )),
            directoryGrantStore: FinderDirectoryGrantStore(defaults: isolatedDefaults()),
            requestDirectoryAccess: { promptCount += 1; return $0 },
            openApplication: { targetURLs, _, _ in openedTargets = targetURLs }
        ).handle(requestID: request.id)

        XCTAssertEqual(promptCount, 0)
        XCTAssertEqual(openedTargets, [downloads.standardizedFileURL])
    }

    func testTheFolderIsStillOpenedWhenNoGrantCoversIt() throws {
        // A folder the sandbox already reaches needs no grant, so a missing one
        // must not turn into a command that does nothing.
        let home = try makeTemporaryDirectory()
        let downloads = home.appendingPathComponent("Downloads", isDirectory: true)
        let application = home.appendingPathComponent("Sample.app", isDirectory: true)
        for url in [downloads, application] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: home) }

        let shortcut = FinderLaunchShortcut(
            displayName: "Sample App",
            bundleURLString: application.absoluteString,
            bundleIdentifier: "com.example.sample"
        )
        let mailbox = FinderCommandMailbox(directoryProvider: { home })
        let request = FinderCommandEnvelope(command: .openWithApplication(
            shortcut: shortcut,
            displayPaths: [downloads.path]
        ))
        try mailbox.enqueue(request)

        var openedTargets: [URL] = []
        FinderFileCommandCoordinator(
            requestMailbox: mailbox,
            preferencesStore: makePreferencesStore(FinderMenuPreferences(
                isEnabled: true,
                launchShortcuts: [shortcut]
            )),
            directoryGrantStore: FinderDirectoryGrantStore(defaults: isolatedDefaults()),
            openApplication: { targetURLs, _, _ in openedTargets = targetURLs }
        ).handle(requestID: request.id)

        XCTAssertEqual(openedTargets, [downloads.standardizedFileURL])
    }

    func testASelectedFileIsHandedToTheApplicationItself() throws {
        let home = try makeTemporaryDirectory()
        let downloads = home.appendingPathComponent("Downloads", isDirectory: true)
        let selectedFile = downloads.appendingPathComponent("Installer.dmg")
        let application = home.appendingPathComponent("Sample.app", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: application, withIntermediateDirectories: true)
        try Data().write(to: selectedFile)
        defer { try? FileManager.default.removeItem(at: home) }

        let shortcut = FinderLaunchShortcut(
            displayName: "Sample App",
            bundleURLString: application.absoluteString,
            bundleIdentifier: "com.example.sample"
        )
        let preferences = makePreferencesStore(FinderMenuPreferences(
            isEnabled: true,
            launchShortcuts: [shortcut]
        ))
        let mailbox = FinderCommandMailbox(directoryProvider: { home })
        let request = FinderCommandEnvelope(command: .openWithApplication(
            shortcut: shortcut,
            displayPaths: [selectedFile.path]
        ))
        try mailbox.enqueue(request)

        var openedTargets: [URL] = []
        FinderFileCommandCoordinator(
            requestMailbox: mailbox,
            preferencesStore: preferences,
            directoryGrantStore: FinderDirectoryGrantStore(defaults: isolatedDefaults()),
            openApplication: { targetURLs, _, _ in openedTargets = targetURLs }
        ).handle(requestID: request.id)

        // Picking a file and choosing an application means that file, the way
        // Open With does everywhere else.
        XCTAssertEqual(openedTargets, [selectedFile.standardizedFileURL])
    }

    func testCreatingADocumentInAnUngrantedFolderDoesNotAsk() throws {
        // A folder macOS already lets us write to needs no grant, so the user
        // is never interrupted for one.
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let preferences = makePreferencesStore(FinderMenuPreferences(isEnabled: true))
        let mailbox = FinderCommandMailbox(directoryProvider: { root })
        let request = FinderCommandEnvelope(command: .createDocument(
            fileExtension: "txt",
            directoryDisplayPath: root.path
        ))
        try mailbox.enqueue(request)

        var promptCount = 0
        FinderFileCommandCoordinator(
            requestMailbox: mailbox,
            preferencesStore: preferences,
            directoryGrantStore: FinderDirectoryGrantStore(defaults: isolatedDefaults()),
            revealFiles: { _ in },
            requestDirectoryAccess: { promptCount += 1; return $0 }
        ).handle(requestID: request.id)

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("NewFile.txt").path
        ))
        XCTAssertEqual(promptCount, 0)
    }

    func testCreatingADocumentAsksOnlyWhenTheFolderRefusesWrites() throws {
        let root = try makeTemporaryDirectory()
        let locked = root.appendingPathComponent("Locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: locked.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: locked.path
            )
            try? FileManager.default.removeItem(at: root)
        }

        let preferences = makePreferencesStore(FinderMenuPreferences(isEnabled: true))
        let mailbox = FinderCommandMailbox(directoryProvider: { root })
        let request = FinderCommandEnvelope(command: .createDocument(
            fileExtension: "txt",
            directoryDisplayPath: locked.path
        ))
        try mailbox.enqueue(request)

        var promptedFor: URL?
        FinderFileCommandCoordinator(
            requestMailbox: mailbox,
            preferencesStore: preferences,
            directoryGrantStore: FinderDirectoryGrantStore(defaults: isolatedDefaults()),
            revealFiles: { _ in },
            // Declining keeps the run clear of the failure alert, which cannot
            // be presented from a test.
            requestDirectoryAccess: { promptedFor = $0; return nil }
        ).handle(requestID: request.id)

        XCTAssertEqual(promptedFor, locked)
    }

    func testOpeningAFolderDoesNotAskForAccess() throws {
        // Handing a folder to another application needs no access of our own.
        let root = try makeTemporaryDirectory()
        let application = root.appendingPathComponent("Sample.app", isDirectory: true)
        try FileManager.default.createDirectory(at: application, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let shortcut = FinderLaunchShortcut(
            displayName: "Sample App",
            bundleURLString: application.absoluteString,
            bundleIdentifier: "com.example.sample"
        )
        let preferences = makePreferencesStore(FinderMenuPreferences(
            isEnabled: true,
            launchShortcuts: [shortcut]
        ))
        let mailbox = FinderCommandMailbox(directoryProvider: { root })
        let request = FinderCommandEnvelope(command: .openWithApplication(
            shortcut: shortcut,
            displayPaths: [root.path]
        ))
        try mailbox.enqueue(request)

        var promptCount = 0
        var openedDirectory: URL?
        FinderFileCommandCoordinator(
            requestMailbox: mailbox,
            preferencesStore: preferences,
            directoryGrantStore: FinderDirectoryGrantStore(defaults: isolatedDefaults()),
            requestDirectoryAccess: { promptCount += 1; return $0 },
            openApplication: { targetURLs, _, completion in
                openedDirectory = targetURLs.first
                completion(nil)
            }
        ).handle(requestID: request.id)

        XCTAssertEqual(openedDirectory, root.standardizedFileURL)
        XCTAssertEqual(promptCount, 0)
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
