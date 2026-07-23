import XCTest
@testable import OmniDockCore

final class FinderMenuTests: XCTestCase {
    func testContainerMenuOffersNewFileAndCurrentPath() {
        let context = FinderMenuContext(
            location: .folderBackground,
            currentDirectory: URL(fileURLWithPath: "/tmp/OmniDock"),
            selectedURLs: []
        )

        XCTAssertEqual(
            FinderMenuCatalog.entries(for: context),
            [
                .action(.copyCurrentDirectoryPath),
                .documentSubmenu([.createTextFile, .createMarkdownFile])
            ]
        )
    }

    func testFinderMenuTagsRoundTripEveryCommand() {
        for action in FinderMenuAction.allCases {
            XCTAssertEqual(FinderMenuAction(menuTag: action.menuTag), action)
        }
        XCTAssertNil(FinderMenuAction(menuTag: -1))
    }

    func testFinderCommandsCarryTheirRequiredMenuContext() {
        XCTAssertEqual(FinderMenuAction.createTextFile.location, .folderBackground)
        XCTAssertEqual(FinderMenuAction.createMarkdownFile.location, .folderBackground)
        XCTAssertEqual(FinderMenuAction.copyCurrentDirectoryPath.location, .folderBackground)
        XCTAssertEqual(FinderMenuAction.copySelectedPaths.location, .selection)
    }

    func testItemMenuOnlyAppearsForSelectedItems() {
        let empty = FinderMenuContext(location: .selection, currentDirectory: nil, selectedURLs: [])
        let selected = FinderMenuContext(
            location: .selection,
            currentDirectory: nil,
            selectedURLs: [URL(fileURLWithPath: "/tmp/first.txt")]
        )

        XCTAssertTrue(FinderMenuCatalog.entries(for: empty).isEmpty)
        XCTAssertEqual(FinderMenuCatalog.entries(for: selected), [.action(.copySelectedPaths)])
        XCTAssertTrue(FinderMenuCatalog.entries(for: selected, isEnabled: false).isEmpty)
    }

    func testPathFormatterKeepsEverySelectedPath() {
        let urls = [
            URL(fileURLWithPath: "/tmp/one file.txt"),
            URL(fileURLWithPath: "/tmp/two.txt")
        ]

        XCTAssertEqual(
            FinderPathList.text(for: urls),
            "/tmp/one file.txt\n/tmp/two.txt"
        )
    }

    func testFileCreationUsesAUniqueIncrementingName() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = try BlankDocumentFactory.create(in: directory, kind: .text)
        let second = try BlankDocumentFactory.create(in: directory, kind: .text)
        let markdown = try BlankDocumentFactory.create(in: directory, kind: .markdown)

        XCTAssertEqual(first.lastPathComponent, "NewFile.txt")
        XCTAssertEqual(second.lastPathComponent, "NewFile 2.txt")
        XCTAssertEqual(markdown.lastPathComponent, "NewFile.md")
        XCTAssertEqual(try Data(contentsOf: first), Data())
        XCTAssertEqual(try Data(contentsOf: second), Data())
    }

    func testCommandRequestRoundTripsAndIsConsumedOnce() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let mailbox = FinderFileRequestMailbox(directoryProvider: { root })
        let request = FinderFileRequest(
            action: .createTextFile,
            directoryDisplayPath: "/tmp/OmniDock"
        )

        try mailbox.enqueue(request)
        XCTAssertEqual(mailbox.take(id: request.id), request)
        XCTAssertNil(mailbox.take(id: request.id))
    }

    func testExpiredCommandRequestIsNotDelivered() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let mailbox = FinderFileRequestMailbox(directoryProvider: { root })
        let request = FinderFileRequest(
            action: .createTextFile,
            directoryDisplayPath: "/tmp/OmniDock",
            createdAt: Date(timeIntervalSinceNow: -301)
        )

        try mailbox.enqueue(request)
        XCTAssertNil(mailbox.take(id: request.id))
    }

    func testMenuTextIsLocalizedForNewFileAndCopyPath() {
        XCTAssertEqual(
            FinderMenuLabels.documentSubmenuTitle(languageIdentifier: "en"),
            "New File"
        )
        XCTAssertEqual(
            FinderMenuLabels.title(for: .copyCurrentDirectoryPath, languageIdentifier: "en"),
            "Copy Path"
        )
        XCTAssertEqual(
            FinderMenuLabels.documentSubmenuTitle(languageIdentifier: "zhHans"),
            "新建文件"
        )
        XCTAssertEqual(
            FinderMenuLabels.title(for: .createMarkdownFile, languageIdentifier: "zhHans"),
            "Markdown 文件"
        )
    }

    func testCommandURLRouterAcceptsOnlyFinderCommandURLs() {
        let identifier = UUID()

        XCTAssertEqual(
            FinderActionRoute.requestID(
                from: FinderActionRoute.url(for: identifier)
            ),
            identifier
        )
        XCTAssertNil(
            FinderActionRoute.requestID(
                from: URL(string: "omnidock://other?id=\(identifier.uuidString)")!
            )
        )
    }

    func testSettingsDefaultToDisabledAndSyncWithTheMainStore() {
        let defaults = isolatedDefaults()
        let groupDefaults = isolatedDefaults()
        let groupStore = FinderMenuPreferencesStore(
            suiteName: "OmniDockTests.FinderExtension.(UUID().uuidString)",
            defaultsProvider: { groupDefaults }
        )
        let settings = SettingsStore(
            defaults: defaults,
            livePreviewLimitProvider: { 6 },
            finderMenuPreferencesStore: groupStore
        )

        XCTAssertFalse(settings.finderExtensionEnabled)
        XCTAssertEqual(groupStore.snapshot(), FinderMenuPreferences())

        settings.finderExtensionEnabled = true
        settings.appLanguage = .zhHans

        XCTAssertEqual(
            groupStore.snapshot(),
            FinderMenuPreferences(isEnabled: true, languageIdentifier: AppLanguage.zhHans.rawValue)
        )

        settings.appLanguage = .en
        XCTAssertEqual(
            groupStore.snapshot(),
            FinderMenuPreferences(isEnabled: true, languageIdentifier: AppLanguage.en.rawValue)
        )
    }

    func testSettingsRoundTripThroughTheSharedContainerFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = FinderMenuPreferencesStore(
            containerProvider: { directory }
        )
        XCTAssertEqual(store.snapshot(), FinderMenuPreferences())

        let expected = FinderMenuPreferences(isEnabled: true, languageIdentifier: "en")
        store.update(expected)

        XCTAssertEqual(store.snapshot(), expected)
    }

    func testRootIsManagedAndDesktopIsUsedWhenFinderOmitsTheContainerTarget() {
        let home = URL(fileURLWithPath: "/Users/omnidock-test", isDirectory: true)
        let desktop = home.appendingPathComponent("Desktop", isDirectory: true)

        let directories = FinderObservationRoots.registeredURLs(homeDirectory: home)

        XCTAssertEqual(
            directories,
            [
                URL(fileURLWithPath: "/", isDirectory: true),
                desktop
            ]
        )
        XCTAssertEqual(
            FinderObservationRoots.folderURL(targetedURL: nil, homeDirectory: home),
            desktop
        )
        let folder = home.appendingPathComponent("Documents", isDirectory: true)
        XCTAssertEqual(
            FinderObservationRoots.folderURL(targetedURL: folder, homeDirectory: home),
            folder
        )
    }

    func testFinderExtensionActivationOnlyNeedsManualSetupWhenFeatureIsOn() {
        XCTAssertFalse(FinderExtensionActivation.requiresManualActivation(
            isFeatureEnabled: false,
            isExtensionEnabledInFinder: false
        ))
        XCTAssertFalse(FinderExtensionActivation.requiresManualActivation(
            isFeatureEnabled: true,
            isExtensionEnabledInFinder: true
        ))
        XCTAssertTrue(FinderExtensionActivation.requiresManualActivation(
            isFeatureEnabled: true,
            isExtensionEnabledInFinder: false
        ))
    }

    func testDirectoryAuthorizationCoversTheSelectedDirectoryAndDescendantsOnly() {
        let root = URL(fileURLWithPath: "/Users/example/Documents", isDirectory: true)

        XCTAssertTrue(FinderDirectoryGrantStore.contains(root, in: root))
        XCTAssertTrue(FinderDirectoryGrantStore.contains(
            root.appendingPathComponent("Project", isDirectory: true),
            in: root
        ))
        XCTAssertFalse(FinderDirectoryGrantStore.contains(
            URL(fileURLWithPath: "/Users/example/Desktop", isDirectory: true),
            in: root
        ))
        XCTAssertFalse(FinderDirectoryGrantStore.contains(
            URL(fileURLWithPath: "/Users/example/Documents-Archive", isDirectory: true),
            in: root
        ))
    }

    func testPermissionFailureClassificationDoesNotTreatOrdinaryWriteErrorsAsAuthorization() {
        XCTAssertTrue(FinderFileCommandCoordinator.isPermissionFailure(
            CocoaError(.fileWriteNoPermission)
        ))
        XCTAssertTrue(FinderFileCommandCoordinator.isPermissionFailure(
            POSIXError(.EPERM)
        ))
        XCTAssertFalse(FinderFileCommandCoordinator.isPermissionFailure(
            CocoaError(.fileWriteFileExists)
        ))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniDockFinderExtensionTests-\(UUID().uuidString)", isDirectory: true)
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
