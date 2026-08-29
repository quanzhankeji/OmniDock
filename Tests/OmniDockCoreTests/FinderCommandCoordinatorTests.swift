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
            revealFiles: { _ in didReveal = true },
            requestDirectoryAccess: { _ in nil }
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
            revealFiles: { _ in didReveal = true },
            requestDirectoryAccess: { _ in nil }
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
        let request = FinderCommandEnvelope(command: .openDirectory(
            shortcut: shortcut,
            directoryDisplayPath: downloads.path
        ))
        try mailbox.enqueue(request)

        var openedDirectory: URL?
        var openedApplication: URL?
        FinderFileCommandCoordinator(
            requestMailbox: mailbox,
            preferencesStore: preferences,
            directoryGrantStore: FinderDirectoryGrantStore(defaults: isolatedDefaults()),
            homeDirectory: home,
            openApplication: { directoryURL, applicationURL, completion in
                openedDirectory = directoryURL
                openedApplication = applicationURL
                completion(nil)
            }
        ).handle(requestID: request.id)

        XCTAssertEqual(openedDirectory, downloads)
        XCTAssertNotEqual(openedDirectory, selectedFile)
        XCTAssertEqual(openedApplication, application)
    }

    func testCoordinatorNeverPassesAFileToAQuickOpenApplication() throws {
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
        let request = FinderCommandEnvelope(command: .openDirectory(
            shortcut: shortcut,
            directoryDisplayPath: selectedFile.path
        ))
        try mailbox.enqueue(request)

        var didOpenApplication = false
        FinderFileCommandCoordinator(
            requestMailbox: mailbox,
            preferencesStore: preferences,
            directoryGrantStore: FinderDirectoryGrantStore(defaults: isolatedDefaults()),
            homeDirectory: home,
            openApplication: { _, _, _ in didOpenApplication = true }
        ).handle(requestID: request.id)

        XCTAssertFalse(didOpenApplication)
    }

    func testUngrantedFolderAsksForAccessThenOpens() throws {
        let home = try makeTemporaryDirectory()
        // Deliberately outside Desktop/Documents/Downloads: the project folders
        // people right-click are usually somewhere else entirely.
        let project = home.appendingPathComponent("Developer/demo", isDirectory: true)
        let application = home.appendingPathComponent("Sample.app", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: application, withIntermediateDirectories: true)
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
        let grantStore = FinderDirectoryGrantStore(defaults: isolatedDefaults())
        let mailbox = FinderCommandMailbox(directoryProvider: { home })

        var promptCount = 0
        var openedDirectory: URL?
        func run() throws {
            let request = FinderCommandEnvelope(command: .openDirectory(
                shortcut: shortcut,
                directoryDisplayPath: project.path
            ))
            try mailbox.enqueue(request)
            FinderFileCommandCoordinator(
                requestMailbox: mailbox,
                preferencesStore: preferences,
                directoryGrantStore: grantStore,
                homeDirectory: home,
                requestDirectoryAccess: { directory in
                    promptCount += 1
                    return directory
                },
                openApplication: { directoryURL, _, completion in
                    openedDirectory = directoryURL
                    completion(nil)
                }
            ).handle(requestID: request.id)
        }

        try run()
        XCTAssertEqual(promptCount, 1)
        XCTAssertEqual(openedDirectory, project)

        // The grant is remembered, so the folder is not asked for again.
        openedDirectory = nil
        try run()
        XCTAssertEqual(promptCount, 1)
        XCTAssertEqual(openedDirectory, project)
    }

    func testDecliningTheAccessPanelOpensNothing() throws {
        let home = try makeTemporaryDirectory()
        let project = home.appendingPathComponent("Developer/demo", isDirectory: true)
        let application = home.appendingPathComponent("Sample.app", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: application, withIntermediateDirectories: true)
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
        let request = FinderCommandEnvelope(command: .openDirectory(
            shortcut: shortcut,
            directoryDisplayPath: project.path
        ))
        try mailbox.enqueue(request)

        var didOpen = false
        FinderFileCommandCoordinator(
            requestMailbox: mailbox,
            preferencesStore: preferences,
            directoryGrantStore: FinderDirectoryGrantStore(defaults: isolatedDefaults()),
            homeDirectory: home,
            requestDirectoryAccess: { _ in nil },
            openApplication: { _, _, _ in didOpen = true }
        ).handle(requestID: request.id)

        XCTAssertFalse(didOpen)
    }

    func testAccessPanelGrantMustCoverTheRequestedFolder() throws {
        let home = try makeTemporaryDirectory()
        let project = home.appendingPathComponent("Developer/demo", isDirectory: true)
        let unrelated = home.appendingPathComponent("Elsewhere", isDirectory: true)
        let application = home.appendingPathComponent("Sample.app", isDirectory: true)
        for url in [project, unrelated, application] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
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
        let request = FinderCommandEnvelope(command: .openDirectory(
            shortcut: shortcut,
            directoryDisplayPath: project.path
        ))
        try mailbox.enqueue(request)

        var didOpen = false
        FinderFileCommandCoordinator(
            requestMailbox: mailbox,
            preferencesStore: preferences,
            directoryGrantStore: FinderDirectoryGrantStore(defaults: isolatedDefaults()),
            homeDirectory: home,
            // Approving some other folder must not authorize this one.
            requestDirectoryAccess: { _ in unrelated },
            openApplication: { _, _, _ in didOpen = true }
        ).handle(requestID: request.id)

        XCTAssertFalse(didOpen)
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
