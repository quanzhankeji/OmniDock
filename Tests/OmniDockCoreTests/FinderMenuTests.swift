import AppKit
import XCTest
@testable import OmniDockCore

final class FinderMenuTests: XCTestCase {
    @MainActor
    func testFinderExtensionSettingsUsesTwoIndependentEditorSections() {
        let view = FinderExtensionSettingsView(
            settings: SettingsStore(
                defaults: isolatedDefaults(),
                livePreviewLimitProvider: { 6 }
            ),
            isExtensionEnabledInFinder: { false }
        )

        XCTAssertEqual(
            FinderExtensionSettingsSection.allCases,
            [.documentTypes, .quickActions]
        )
        XCTAssertEqual(view.selectedSection, .documentTypes)

        view.selectSection(.quickActions)

        XCTAssertEqual(view.selectedSection, .quickActions)
    }

    @MainActor
    func testFinderExtensionNavigationRowsFillTheSameLeftColumnWidth() {
        let view = FinderExtensionSettingsView(
            settings: SettingsStore(
                defaults: isolatedDefaults(),
                livePreviewLimitProvider: { 6 }
            ),
            isExtensionEnabledInFinder: { true }
        )
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        view.layoutSubtreeIfNeeded()

        let navigationButtons = descendantButtons(in: view).filter {
            FinderExtensionSettingsSection.allCases.map(\.title).contains($0.title)
        }

        XCTAssertEqual(navigationButtons.count, 2)
        XCTAssertEqual(
            navigationButtons[0].frame.minX,
            navigationButtons[1].frame.minX,
            accuracy: 0.5
        )
        XCTAssertEqual(
            navigationButtons[0].bounds.width,
            navigationButtons[1].bounds.width,
            accuracy: 0.5
        )
        XCTAssertGreaterThan(navigationButtons[0].bounds.width, 180)
    }

    func testMenuActionRegistryConsumesFrozenContextOnce() {
        let registry = FinderMenuActionRegistry()
        let directory = URL(fileURLWithPath: "/tmp/Documents", isDirectory: true)
        let binding = FinderMenuCommandBinding(
            action: .createDocument(FinderDocumentPreset.defaultPresets[0]),
            context: FinderMenuContext(
                location: .folderBackground,
                currentDirectory: directory,
                selectedURLs: []
            )
        )

        let token = registry.issueToken(for: binding)

        XCTAssertEqual(registry.consume(token: token), binding)
        XCTAssertNil(registry.consume(token: token))
    }

    func testMenuActionRegistryKeepsIndependentMenuBindings() {
        let registry = FinderMenuActionRegistry()
        let binding = FinderMenuCommandBinding(
            action: .copySelectedPaths,
            context: FinderMenuContext(
                location: .selection,
                currentDirectory: nil,
                selectedURLs: [URL(fileURLWithPath: "/tmp/Document.txt")]
            )
        )
        let firstToken = registry.issueToken(for: binding)
        let secondToken = registry.issueToken(for: binding)

        XCTAssertNotEqual(firstToken, secondToken)
        XCTAssertEqual(registry.consume(token: firstToken), binding)
        XCTAssertEqual(registry.consume(token: secondToken), binding)
    }

    func testMenuActionRegistryEvictsTheOldestStaleBinding() {
        let registry = FinderMenuActionRegistry(capacity: 2)
        let binding = FinderMenuCommandBinding(
            action: .copySelectedPaths,
            context: FinderMenuContext(
                location: .selection,
                currentDirectory: nil,
                selectedURLs: [URL(fileURLWithPath: "/tmp/Document.txt")]
            )
        )
        let firstToken = registry.issueToken(for: binding)
        let secondToken = registry.issueToken(for: binding)
        let thirdToken = registry.issueToken(for: binding)

        XCTAssertNil(registry.consume(token: firstToken))
        XCTAssertEqual(registry.consume(token: secondToken), binding)
        XCTAssertEqual(registry.consume(token: thirdToken), binding)
    }

    func testContainerMenuOffersNewFileAndCurrentPath() {
        let context = FinderMenuContext(
            location: .folderBackground,
            currentDirectory: URL(fileURLWithPath: "/tmp/OmniDock"),
            selectedURLs: []
        )

        XCTAssertEqual(
            FinderMenuCatalog.entries(
                for: context,
                preferences: FinderMenuPreferences(isEnabled: true)
            ),
            [
                .action(.copyCurrentDirectoryPath),
                .documentSubmenu(
                    FinderDocumentPreset.defaultPresets.map(FinderMenuAction.createDocument)
                )
            ]
        )
    }

    func testFinderCommandsCarryTheirRequiredMenuContext() {
        XCTAssertEqual(
            FinderMenuAction.createDocument(FinderDocumentPreset.defaultPresets[0]).location,
            .folderBackground
        )
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

        let enabled = FinderMenuPreferences(isEnabled: true)
        XCTAssertTrue(FinderMenuCatalog.entries(for: empty, preferences: enabled).isEmpty)
        XCTAssertEqual(
            FinderMenuCatalog.entries(for: selected, preferences: enabled),
            [.action(.copySelectedPaths)]
        )
        XCTAssertTrue(FinderMenuCatalog.entries(
            for: selected,
            preferences: FinderMenuPreferences(isEnabled: false)
        ).isEmpty)
    }

    func testConfiguredApplicationsCanBeGroupedOrShownDirectly() {
        let app = FinderLaunchShortcut(
            displayName: "Sample App",
            bundleURLString: URL(fileURLWithPath: "/Applications").absoluteString,
            bundleIdentifier: "com.example.sample"
        )
        let context = FinderMenuContext(
            location: .selection,
            currentDirectory: nil,
            selectedURLs: [URL(fileURLWithPath: "/tmp/item")]
        )

        XCTAssertEqual(
            FinderMenuCatalog.entries(
                for: context,
                preferences: FinderMenuPreferences(
                    isEnabled: true,
                    groupsLaunchShortcuts: true,
                    launchShortcuts: [app]
                )
            ),
            [.action(.copySelectedPaths), .applicationSubmenu([.openSelection(app)])]
        )
        XCTAssertEqual(
            FinderMenuCatalog.entries(
                for: context,
                preferences: FinderMenuPreferences(
                    isEnabled: true,
                    groupsLaunchShortcuts: false,
                    launchShortcuts: [app]
                )
            ),
            [.action(.copySelectedPaths), .action(.openSelection(app))]
        )
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

        let first = try BlankDocumentFactory.create(in: directory, fileExtension: "txt")
        let second = try BlankDocumentFactory.create(in: directory, fileExtension: ".txt")
        let markdown = try BlankDocumentFactory.create(in: directory, fileExtension: "md")

        XCTAssertEqual(first.lastPathComponent, "NewFile.txt")
        XCTAssertEqual(second.lastPathComponent, "NewFile 2.txt")
        XCTAssertEqual(markdown.lastPathComponent, "NewFile.md")
        XCTAssertEqual(try Data(contentsOf: first), Data())
        XCTAssertEqual(try Data(contentsOf: second), Data())
    }

    func testCreateDocumentCommandRoundTripsAndIsConsumedOnce() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let mailbox = FinderCommandMailbox(directoryProvider: { root })
        let request = FinderCommandEnvelope(
            command: .createDocument(
                fileExtension: "txt",
                directoryDisplayPath: "/tmp/OmniDock"
            )
        )

        try mailbox.enqueue(request)
        XCTAssertEqual(mailbox.take(id: request.id), request)
        XCTAssertNil(mailbox.take(id: request.id))
    }

    func testOpenSelectionCommandPreservesEverySelectedPath() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let mailbox = FinderCommandMailbox(directoryProvider: { root })
        let shortcut = FinderLaunchShortcut(
            displayName: "Sample App",
            bundleURLString: "file:///Applications/Sample.app/",
            bundleIdentifier: "com.example.sample"
        )
        let request = FinderCommandEnvelope(
            command: .openSelection(
                shortcut: shortcut,
                selectedDisplayPaths: ["/tmp/one.txt", "/tmp/two.txt"]
            )
        )

        try mailbox.enqueue(request)

        XCTAssertEqual(mailbox.take(id: request.id), request)
    }

    func testExpiredCommandRequestIsNotDelivered() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let mailbox = FinderCommandMailbox(directoryProvider: { root })
        let request = FinderCommandEnvelope(
            command: .createDocument(
                fileExtension: "txt",
                directoryDisplayPath: "/tmp/OmniDock"
            ),
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
            FinderMenuLabels.title(
                for: .createDocument(FinderDocumentPreset.defaultPresets[1]),
                languageIdentifier: "zhHans"
            ),
            "Markdown 文件"
        )
        XCTAssertEqual(
            FinderMenuLabels.applicationSubmenuTitle(languageIdentifier: "en"),
            "Open With"
        )
    }

    func testDocumentPresetValidationNormalizesSafeExtensions() {
        XCTAssertEqual(
            FinderDocumentPreset(displayName: "Log", fileExtension: ".LOG")?.fileExtension,
            "log"
        )
        XCTAssertNil(FinderDocumentPreset(displayName: "", fileExtension: "txt"))
        XCTAssertNil(FinderDocumentPreset(displayName: "Script", fileExtension: "../sh"))
    }

    func testEmptyDocumentPresetListOmitsTheNewFileSubmenu() {
        let context = FinderMenuContext(
            location: .folderBackground,
            currentDirectory: URL(fileURLWithPath: "/tmp"),
            selectedURLs: []
        )

        XCTAssertEqual(
            FinderMenuCatalog.entries(
                for: context,
                preferences: FinderMenuPreferences(
                    isEnabled: true,
                    documentPresets: []
                )
            ),
            [.action(.copyCurrentDirectoryPath)]
        )
    }

    func testOlderSharedPreferencesReceiveNewFeatureDefaults() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "isEnabled": true,
            "languageIdentifier": "en"
        ])

        let decoded = try JSONDecoder().decode(FinderMenuPreferences.self, from: data)

        XCTAssertTrue(decoded.isEnabled)
        XCTAssertTrue(decoded.groupsLaunchShortcuts)
        XCTAssertTrue(decoded.launchShortcuts.isEmpty)
        XCTAssertEqual(decoded.documentPresets, FinderDocumentPreset.defaultPresets)
    }

    func testCommandURLRouterAndSignalAcceptOnlyFinderCommandIdentifiers() {
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
        XCTAssertEqual(
            FinderCommandSignal.requestID(
                from: Notification(
                    name: FinderCommandSignal.notificationName,
                    object: identifier.uuidString
                )
            ),
            identifier
        )
        XCTAssertNil(
            FinderCommandSignal.requestID(
                from: Notification(
                    name: FinderCommandSignal.notificationName,
                    object: "not-a-uuid"
                )
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
        let app = FinderLaunchShortcut(
            displayName: "Sample",
            bundleURLString: URL(fileURLWithPath: "/Applications").absoluteString,
            bundleIdentifier: "com.example.sample"
        )
        settings.finderLaunchShortcutsGrouped = false
        settings.finderLaunchShortcuts = [app]
        let logPreset = FinderDocumentPreset(displayName: "Log", fileExtension: "log")!
        settings.finderDocumentPresets = [logPreset]

        XCTAssertEqual(
            groupStore.snapshot(),
            FinderMenuPreferences(
                isEnabled: true,
                languageIdentifier: AppLanguage.zhHans.rawValue,
                groupsLaunchShortcuts: false,
                launchShortcuts: [app],
                documentPresets: [logPreset]
            )
        )

        settings.appLanguage = .en
        XCTAssertEqual(
            groupStore.snapshot(),
            FinderMenuPreferences(
                isEnabled: true,
                languageIdentifier: AppLanguage.en.rawValue,
                groupsLaunchShortcuts: false,
                launchShortcuts: [app],
                documentPresets: [logPreset]
            )
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

    func testSettingsRejectDuplicateFinderAppsAndDocumentExtensions() {
        let defaults = isolatedDefaults()
        let settings = SettingsStore(defaults: defaults, livePreviewLimitProvider: { 6 })
        let app = FinderLaunchShortcut(
            displayName: "Sample",
            bundleURLString: URL(fileURLWithPath: "/Applications/Sample.app").absoluteString,
            bundleIdentifier: "com.example.sample"
        )

        settings.addFinderLaunchShortcut(app)
        settings.addFinderLaunchShortcut(FinderLaunchShortcut(
            displayName: "Renamed",
            bundleURLString: URL(fileURLWithPath: "/Applications/Renamed.app").absoluteString,
            bundleIdentifier: "com.example.sample"
        ))
        settings.addFinderDocumentPreset(
            FinderDocumentPreset(displayName: "Text copy", fileExtension: ".TXT")!
        )

        XCTAssertEqual(settings.finderLaunchShortcuts, [app])
        XCTAssertEqual(settings.finderDocumentPresets, FinderDocumentPreset.defaultPresets)
    }

    func testStandardFinderLocationsAreManagedAndDesktopIsUsedWhenTargetIsMissing() {
        let home = URL(fileURLWithPath: "/Users/omnidock-test", isDirectory: true)
        let desktop = home.appendingPathComponent("Desktop", isDirectory: true)
        let documents = home.appendingPathComponent("Documents", isDirectory: true)
        let downloads = home.appendingPathComponent("Downloads", isDirectory: true)

        let directories = FinderObservationRoots.registeredURLs(homeDirectory: home)

        XCTAssertEqual(
            directories,
            [
                desktop,
                documents,
                downloads
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

    func testAuthorizedFinderLocationsAreCanonicalizedAndDeduplicated() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let home = root.appendingPathComponent("Home", isDirectory: true)
        let projects = root.appendingPathComponent("Projects", isDirectory: true)
        let linkedProjects = root.appendingPathComponent("LinkedProjects", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: linkedProjects,
            withDestinationURL: projects
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let directories = FinderObservationRoots.registeredURLs(
            homeDirectory: home,
            authorizedDirectoryPaths: [
                projects.path,
                linkedProjects.path,
                projects.path
            ]
        )

        XCTAssertTrue(directories.contains(projects.standardizedFileURL))
        XCTAssertTrue(directories.contains(linkedProjects.standardizedFileURL))
        XCTAssertEqual(
            directories.filter { $0.resolvingSymlinksInPath() == projects }.count,
            2
        )
    }

    func testDirectoryGrantPublishesObservationRootsWithoutSharingBookmarks() throws {
        let defaults = isolatedDefaults()
        var publishedPaths: [String] = []
        let store = FinderDirectoryGrantStore(
            defaults: defaults,
            observationRootUpdater: { publishedPaths = $0 }
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try store.remember(directory: directory)

        XCTAssertEqual(publishedPaths, [directory.standardizedFileURL.path])
        XCTAssertNotNil(defaults.data(forKey: "finderExtensionDirectoryBookmarks"))

        publishedPaths = []
        XCTAssertTrue(store.hasUsableGrant())
        XCTAssertEqual(publishedPaths, [directory.standardizedFileURL.path])
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

    func testApplicationTargetResolverFallsBackToInstalledBundleLocation() {
        let storedURL = URL(fileURLWithPath: "/Applications/Old Sample.app")
        let installedURL = URL(fileURLWithPath: "/Applications/New Sample.app")
        let shortcut = FinderLaunchShortcut(
            displayName: "Sample",
            bundleURLString: storedURL.absoluteString,
            bundleIdentifier: "com.example.sample"
        )

        XCTAssertEqual(
            FinderApplicationTargetResolver.resolve(
                shortcut: shortcut,
                fileExists: { _ in false },
                installedApplicationURL: { identifier in
                    identifier == "com.example.sample" ? installedURL : nil
                }
            ),
            installedURL
        )
    }

    func testApplicationTargetResolverPrefersTheStoredBundleWhenItStillExists() {
        let storedURL = URL(fileURLWithPath: "/Applications/Sample.app")
        let shortcut = FinderLaunchShortcut(
            displayName: "Sample",
            bundleURLString: storedURL.absoluteString,
            bundleIdentifier: "com.example.sample"
        )

        XCTAssertEqual(
            FinderApplicationTargetResolver.resolve(
                shortcut: shortcut,
                fileExists: { $0 == storedURL.path },
                installedApplicationURL: { _ in nil }
            ),
            storedURL
        )
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

    private func descendantButtons(in view: NSView) -> [NSButton] {
        view.subviews.flatMap { child in
            (child as? NSButton).map { [$0] } ?? descendantButtons(in: child)
        }
    }
}
