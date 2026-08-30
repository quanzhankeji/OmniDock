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
            openApplication: { _, _, _ in didOpenApplication = true }
        ).handle(requestID: request.id)

        XCTAssertFalse(didOpenApplication)
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
        let request = FinderCommandEnvelope(command: .openDirectory(
            shortcut: shortcut,
            directoryDisplayPath: root.path
        ))
        try mailbox.enqueue(request)

        var promptCount = 0
        var openedDirectory: URL?
        FinderFileCommandCoordinator(
            requestMailbox: mailbox,
            preferencesStore: preferences,
            directoryGrantStore: FinderDirectoryGrantStore(defaults: isolatedDefaults()),
            requestDirectoryAccess: { promptCount += 1; return $0 },
            openApplication: { directoryURL, _, completion in
                openedDirectory = directoryURL
                completion(nil)
            }
        ).handle(requestID: request.id)

        XCTAssertEqual(openedDirectory, root.standardizedFileURL)
        XCTAssertEqual(promptCount, 0)
    }

    func testPasteCopiesTheItemsOnThePasteboardIntoTheFolder() throws {
        let root = try makeTemporaryDirectory()
        let source = root.appendingPathComponent("Source", isDirectory: true)
        let destination = root.appendingPathComponent("Destination", isDirectory: true)
        for url in [source, destination] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let file = source.appendingPathComponent("Report.txt")
        try Data("payload".utf8).write(to: file)

        let pasteboard = makePasteboard()
        XCTAssertTrue(FinderItemPasteboard.write([file], isCut: false, to: pasteboard))

        let preferences = makePreferencesStore(FinderMenuPreferences(isEnabled: true))
        let mailbox = FinderCommandMailbox(directoryProvider: { root })
        let request = FinderCommandEnvelope(
            command: .pasteItems(directoryDisplayPath: destination.path)
        )
        try mailbox.enqueue(request)

        var revealed: [URL] = []
        FinderFileCommandCoordinator(
            requestMailbox: mailbox,
            preferencesStore: preferences,
            directoryGrantStore: FinderDirectoryGrantStore(defaults: isolatedDefaults()),
            itemPasteboard: pasteboard,
            revealFiles: { revealed = $0 },
            requestDirectoryAccess: { _ in nil }
        ).handle(requestID: request.id)

        let pasted = destination.appendingPathComponent("Report.txt")
        XCTAssertEqual(try String(contentsOf: pasted), "payload")
        XCTAssertEqual(revealed, [pasted])
    }

    func testPasteNeverOverwritesAnExistingItem() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let existing = root.appendingPathComponent("Report.txt")
        try Data("original".utf8).write(to: existing)

        let incoming = FinderFileCommandCoordinator.availableDestination(
            for: existing,
            in: root
        )

        XCTAssertEqual(incoming.lastPathComponent, "Report 2.txt")
        XCTAssertEqual(try String(contentsOf: existing), "original")
    }

    func testPasteMovesTheItemsWhenTheyWereCut() throws {
        let root = try makeTemporaryDirectory()
        let source = root.appendingPathComponent("Source", isDirectory: true)
        let destination = root.appendingPathComponent("Destination", isDirectory: true)
        for url in [source, destination] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let file = source.appendingPathComponent("Report.txt")
        try Data("payload".utf8).write(to: file)

        let pasteboard = makePasteboard()
        XCTAssertTrue(FinderItemPasteboard.write([file], isCut: true, to: pasteboard))

        let preferences = makePreferencesStore(FinderMenuPreferences(isEnabled: true))
        let mailbox = FinderCommandMailbox(directoryProvider: { root })
        let request = FinderCommandEnvelope(
            command: .pasteItems(directoryDisplayPath: destination.path)
        )
        try mailbox.enqueue(request)

        FinderFileCommandCoordinator(
            requestMailbox: mailbox,
            preferencesStore: preferences,
            directoryGrantStore: FinderDirectoryGrantStore(defaults: isolatedDefaults()),
            itemPasteboard: pasteboard,
            revealFiles: { _ in },
            requestDirectoryAccess: { _ in nil }
        ).handle(requestID: request.id)

        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("Report.txt")),
            "payload"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        // The sources are gone, so a second paste must not be offered.
        XCTAssertFalse(FinderItemPasteboard.hasFiles(pasteboard))
    }

    func testCuttingIntoTheSameFolderLeavesTheItemAlone() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Report.txt")
        try Data("payload".utf8).write(to: file)

        let pasteboard = makePasteboard()
        XCTAssertTrue(FinderItemPasteboard.write([file], isCut: true, to: pasteboard))

        let preferences = makePreferencesStore(FinderMenuPreferences(isEnabled: true))
        let mailbox = FinderCommandMailbox(directoryProvider: { root })
        let request = FinderCommandEnvelope(
            command: .pasteItems(directoryDisplayPath: root.path)
        )
        try mailbox.enqueue(request)

        FinderFileCommandCoordinator(
            requestMailbox: mailbox,
            preferencesStore: preferences,
            directoryGrantStore: FinderDirectoryGrantStore(defaults: isolatedDefaults()),
            itemPasteboard: pasteboard,
            revealFiles: { _ in },
            requestDirectoryAccess: { _ in nil }
        ).handle(requestID: request.id)

        // Not renamed to "Report 2.txt", and not duplicated. (The mailbox keeps
        // its own directory alongside, so only the pasted names are compared.)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: root.path)
                .filter { $0.hasSuffix(".txt") }
                .sorted(),
            ["Report.txt"]
        )
    }

    func testPasteboardCarriesTheCutIntentOnlyWhenCut() {
        let file = URL(fileURLWithPath: "/tmp/OmniDock/Report.txt")
        let pasteboard = makePasteboard()

        XCTAssertTrue(FinderItemPasteboard.write([file], isCut: false, to: pasteboard))
        XCTAssertFalse(FinderItemPasteboard.read(from: pasteboard).isCut)

        XCTAssertTrue(FinderItemPasteboard.write([file], isCut: true, to: pasteboard))
        XCTAssertTrue(FinderItemPasteboard.read(from: pasteboard).isCut)

        // Anyone else writing to the pasteboard retires the intent.
        pasteboard.clearContents()
        pasteboard.setString("plain text", forType: .string)
        XCTAssertFalse(FinderItemPasteboard.read(from: pasteboard).isCut)
    }

    func testWritingNoItemsLeavesThePasteboardUntouched() {
        let pasteboard = makePasteboard()
        // An empty write must not produce a pasteboard that claims a cut but
        // carries nothing to paste.
        XCTAssertFalse(FinderItemPasteboard.write([], isCut: true, to: pasteboard))
        XCTAssertFalse(FinderItemPasteboard.read(from: pasteboard).isCut)
        XCTAssertTrue(FinderItemPasteboard.read(from: pasteboard).urls.isEmpty)
    }

    func testWrittenItemsAreReadableAsFileURLs() {
        let pasteboard = makePasteboard()
        let urls = [
            URL(fileURLWithPath: "/tmp/OmniDock/first file.txt"),
            URL(fileURLWithPath: "/tmp/OmniDock/second.txt")
        ]

        XCTAssertTrue(FinderItemPasteboard.write(urls, isCut: false, to: pasteboard))

        // Round-tripping through the pasteboard must preserve every item,
        // including names that need escaping.
        XCTAssertEqual(FinderItemPasteboard.read(from: pasteboard).urls, urls)
        XCTAssertTrue(FinderItemPasteboard.hasFiles(pasteboard))
    }

    func testCopyCommandPutsTheSelectionOnThePasteboard() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("First.txt")
        let second = root.appendingPathComponent("Second.txt")
        for url in [first, second] {
            try Data("payload".utf8).write(to: url)
        }

        let pasteboard = makePasteboard()
        let preferences = makePreferencesStore(FinderMenuPreferences(isEnabled: true))
        let mailbox = FinderCommandMailbox(directoryProvider: { root })
        let request = FinderCommandEnvelope(command: .copyItems(
            displayPaths: [first.path, second.path],
            isCut: false
        ))
        try mailbox.enqueue(request)

        FinderFileCommandCoordinator(
            requestMailbox: mailbox,
            preferencesStore: preferences,
            directoryGrantStore: FinderDirectoryGrantStore(defaults: isolatedDefaults()),
            itemPasteboard: pasteboard,
            requestDirectoryAccess: { _ in nil }
        ).handle(requestID: request.id)

        let written = FinderItemPasteboard.read(from: pasteboard)
        XCTAssertEqual(written.urls, [first, second])
        XCTAssertFalse(written.isCut)
    }

    func testCutCommandMarksThePasteboardAsAMove() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Report.txt")
        try Data("payload".utf8).write(to: file)

        let pasteboard = makePasteboard()
        let preferences = makePreferencesStore(FinderMenuPreferences(isEnabled: true))
        let mailbox = FinderCommandMailbox(directoryProvider: { root })
        let request = FinderCommandEnvelope(command: .copyItems(
            displayPaths: [file.path],
            isCut: true
        ))
        try mailbox.enqueue(request)

        FinderFileCommandCoordinator(
            requestMailbox: mailbox,
            preferencesStore: preferences,
            directoryGrantStore: FinderDirectoryGrantStore(defaults: isolatedDefaults()),
            itemPasteboard: pasteboard,
            requestDirectoryAccess: { _ in nil }
        ).handle(requestID: request.id)

        XCTAssertTrue(FinderItemPasteboard.read(from: pasteboard).isCut)
    }

    func testCopyCommandIsIgnoredWhenTheCommandIsSwitchedOff() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Report.txt")
        try Data("payload".utf8).write(to: file)

        let pasteboard = makePasteboard()
        var preferences = FinderMenuPreferences(isEnabled: true)
        preferences.showsCopyItemsCommand = false
        let mailbox = FinderCommandMailbox(directoryProvider: { root })
        let request = FinderCommandEnvelope(command: .copyItems(
            displayPaths: [file.path],
            isCut: false
        ))
        try mailbox.enqueue(request)

        FinderFileCommandCoordinator(
            requestMailbox: mailbox,
            preferencesStore: makePreferencesStore(preferences),
            directoryGrantStore: FinderDirectoryGrantStore(defaults: isolatedDefaults()),
            itemPasteboard: pasteboard,
            requestDirectoryAccess: { _ in nil }
        ).handle(requestID: request.id)

        XCTAssertTrue(FinderItemPasteboard.read(from: pasteboard).urls.isEmpty)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniDockFinderCommandTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makePasteboard() -> NSPasteboard {
        let name = NSPasteboard.Name("OmniDockTests.\(UUID().uuidString)")
        let pasteboard = NSPasteboard(name: name)
        pasteboard.clearContents()
        return pasteboard
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
