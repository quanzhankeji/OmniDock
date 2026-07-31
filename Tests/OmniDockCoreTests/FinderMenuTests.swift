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

    @MainActor
    func testFinderDocumentTypeListCreatesScrollableContent() throws {
        let view = FinderExtensionSettingsView(
            settings: SettingsStore(
                defaults: isolatedDefaults(),
                livePreviewLimitProvider: { 6 }
            ),
            isExtensionEnabledInFinder: { true }
        )
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 440)
        view.layoutSubtreeIfNeeded()

        let scrollView = try XCTUnwrap(descendantScrollViews(in: view).first)
        let documentView = try XCTUnwrap(scrollView.documentView)
        let viewportHeight = scrollView.contentView.bounds.height

        XCTAssertGreaterThan(documentView.bounds.height, viewportHeight)

        let maximumOffset = documentView.bounds.height - viewportHeight
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: maximumOffset))
        scrollView.reflectScrolledClipView(scrollView.contentView)

        XCTAssertGreaterThan(scrollView.contentView.bounds.minY, 0)
    }

    @MainActor
    func testFinderQuickActionCatalogCreatesScrollableContent() throws {
        let view = FinderExtensionSettingsView(
            settings: SettingsStore(
                defaults: isolatedDefaults(),
                livePreviewLimitProvider: { 6 }
            ),
            isExtensionEnabledInFinder: { true }
        )
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 440)
        view.selectSection(.quickActions)
        view.layoutSubtreeIfNeeded()

        let scrollView = try XCTUnwrap(descendantScrollViews(in: view).first)
        let documentView = try XCTUnwrap(scrollView.documentView)

        XCTAssertGreaterThan(
            documentView.bounds.height,
            scrollView.contentView.bounds.height
        )
    }

    @MainActor
    func testFinderQuickActionCatalogDoesNotWaitForApplicationDiscovery() {
        let providerStarted = expectation(description: "background provider started")
        let releaseProvider = DispatchSemaphore(value: 0)
        let probe = FinderQuickActionLoaderProbe()
        let loader = FinderQuickActionPresentationLoader(
            applicationURLProvider: { _ in
                if probe.markFirstLookup() {
                    providerStarted.fulfill()
                    _ = releaseProvider.wait(timeout: .now() + 2)
                }
                return nil
            },
            iconProvider: { _ in NSImage(size: NSSize(width: 26, height: 26)) },
            fileExistsProvider: { _ in false }
        )
        let view = FinderExtensionSettingsView(
            settings: SettingsStore(
                defaults: isolatedDefaults(),
                livePreviewLimitProvider: { 6 }
            ),
            quickActionPresentationLoader: loader,
            isExtensionEnabledInFinder: { true }
        )

        view.selectSection(.quickActions)

        XCTAssertEqual(view.selectedSection, .quickActions)
        wait(for: [providerStarted], timeout: 1)
        XCTAssertTrue(probe.firstLookupIsWaiting)
        releaseProvider.signal()
    }

    @MainActor
    func testFinderQuickActionLoaderRunsWorkspaceLookupsAwayFromMainThread() async {
        let probe = FinderQuickActionLoaderProbe()
        let shortcut = FinderLaunchShortcut(
            displayName: "Sample",
            bundleURLString: URL(fileURLWithPath: "/Applications/Missing.app").absoluteString,
            bundleIdentifier: "com.example.sample",
            isEnabled: false
        )
        let installedURL = URL(fileURLWithPath: "/Applications/Sample.app")
        let loader = FinderQuickActionPresentationLoader(
            applicationURLProvider: { _ in
                probe.recordLookupThread()
                return installedURL
            },
            iconProvider: { _ in NSImage(size: NSSize(width: 26, height: 26)) },
            fileExistsProvider: { _ in false }
        )

        let presentations = await loader.load(shortcuts: [shortcut])

        XCTAssertEqual(presentations[shortcut.id]?.applicationURL, installedURL)
        XCTAssertFalse(probe.lookupRanOnMainThread)
    }

    @MainActor
    func testFinderQuickActionCatalogUsesBundledBrandArtwork() throws {
        let shortcut = try XCTUnwrap(
            FinderLaunchShortcut.defaultShortcuts.first {
                $0.bundleIdentifier == "com.microsoft.VSCode"
            }
        )

        let image = FinderQuickActionBrandIcon.image(for: shortcut)

        XCTAssertTrue(image.representations.contains { $0.pixelsWide >= 128 })
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
                    FinderDocumentPreset.defaultPresets
                        .filter(\.isEnabled)
                        .map(FinderMenuAction.createDocument)
                ),
                .action(.showHiddenFiles),
                .action(.hideHiddenFiles)
            ]
        )
    }

    func testFinderCommandsCarryTheirRequiredMenuContext() {
        let create = FinderMenuAction.createDocument(FinderDocumentPreset.defaultPresets[0])
        XCTAssertTrue(create.isAvailable(in: .folderBackground))
        XCTAssertFalse(create.isAvailable(in: .selection))
        XCTAssertTrue(FinderMenuAction.copyCurrentDirectoryPath.isAvailable(in: .folderBackground))
        XCTAssertFalse(FinderMenuAction.copyCurrentDirectoryPath.isAvailable(in: .selection))
        XCTAssertTrue(FinderMenuAction.copySelectedPaths.isAvailable(in: .selection))
        XCTAssertFalse(FinderMenuAction.copySelectedPaths.isAvailable(in: .folderBackground))
        XCTAssertTrue(FinderMenuAction.showHiddenFiles.isAvailable(in: .folderBackground))
        XCTAssertTrue(FinderMenuAction.showHiddenFiles.isAvailable(in: .selection))
        XCTAssertTrue(FinderMenuAction.hideHiddenFiles.isAvailable(in: .folderBackground))
        XCTAssertTrue(FinderMenuAction.hideHiddenFiles.isAvailable(in: .selection))
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
            [
                .action(.copySelectedPaths),
                .action(.showHiddenFiles),
                .action(.hideHiddenFiles)
            ]
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
            [
                .action(.copySelectedPaths),
                .applicationSubmenu([.openSelection(app)]),
                .action(.showHiddenFiles),
                .action(.hideHiddenFiles)
            ]
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
            [
                .action(.copySelectedPaths),
                .action(.openSelection(app)),
                .action(.showHiddenFiles),
                .action(.hideHiddenFiles)
            ]
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
        XCTAssertEqual(
            FinderMenuLabels.title(for: .showHiddenFiles, languageIdentifier: "zhHans"),
            "显示所有文件"
        )
        XCTAssertEqual(
            FinderMenuLabels.title(for: .hideHiddenFiles, languageIdentifier: "zhHans"),
            "隐藏所有文件"
        )
        XCTAssertEqual(
            FinderMenuLabels.title(for: .hideHiddenFiles, languageIdentifier: "en"),
            "Hide Hidden Files"
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
            [
                .action(.copyCurrentDirectoryPath),
                .action(.showHiddenFiles),
                .action(.hideHiddenFiles)
            ]
        )
    }

    func testHiddenFilesVisibilityCommandRoundTrips() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let mailbox = FinderCommandMailbox(directoryProvider: { root })
        let request = FinderCommandEnvelope(command: .setHiddenFilesVisible(true))

        try mailbox.enqueue(request)

        XCTAssertEqual(mailbox.take(id: request.id), request)
    }

    @MainActor
    func testHiddenFilesControllerOnlyTogglesWhenStateMustChange() {
        var toggleCount = 0
        let alreadyVisible = FinderHiddenFilesController(
            isShowingHiddenFiles: { true },
            sendVisibilityToggle: {
                toggleCount += 1
                return true
            }
        )

        XCTAssertTrue(alreadyVisible.setHiddenFilesVisible(true))
        XCTAssertEqual(toggleCount, 0)

        let currentlyHidden = FinderHiddenFilesController(
            isShowingHiddenFiles: { false },
            sendVisibilityToggle: {
                toggleCount += 1
                return true
            }
        )

        XCTAssertTrue(currentlyHidden.setHiddenFilesVisible(true))
        XCTAssertEqual(toggleCount, 1)
    }

    func testOlderSharedPreferencesReceiveNewFeatureDefaults() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "isEnabled": true,
            "languageIdentifier": "en"
        ])

        let decoded = try JSONDecoder().decode(FinderMenuPreferences.self, from: data)

        XCTAssertTrue(decoded.isEnabled)
        XCTAssertTrue(decoded.groupsLaunchShortcuts)
        XCTAssertEqual(decoded.launchShortcuts, FinderLaunchShortcut.defaultShortcuts)
        XCTAssertTrue(decoded.launchShortcuts.allSatisfy { !$0.isEnabled })
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
        let expectedPresets = FinderDocumentPreset.catalog(
            merging: [logPreset],
            missingBuiltInsUseDefaults: false
        )

        XCTAssertEqual(
            groupStore.snapshot(),
            FinderMenuPreferences(
                isEnabled: true,
                languageIdentifier: AppLanguage.zhHans.rawValue,
                groupsLaunchShortcuts: false,
                launchShortcuts: [app],
                documentPresets: expectedPresets
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
                documentPresets: expectedPresets
            )
        )
    }

    func testDocumentMenuIncludesOnlyEnabledPresets() {
        let context = FinderMenuContext(
            location: .folderBackground,
            currentDirectory: URL(fileURLWithPath: "/tmp"),
            selectedURLs: []
        )
        let enabled = FinderDocumentPreset(
            displayName: "Log",
            fileExtension: "log",
            isEnabled: true
        )!
        let disabled = FinderDocumentPreset(
            displayName: "Config",
            fileExtension: "conf",
            isEnabled: false
        )!

        XCTAssertEqual(
            FinderMenuCatalog.entries(
                for: context,
                preferences: FinderMenuPreferences(
                    isEnabled: true,
                    documentPresets: [enabled, disabled]
                )
            ),
            [
                .action(.copyCurrentDirectoryPath),
                .documentSubmenu([.createDocument(enabled)]),
                .action(.showHiddenFiles),
                .action(.hideHiddenFiles)
            ]
        )
    }

    func testOlderDocumentPresetsRemainEnabledAndGainDisabledBuiltIns() throws {
        let legacyPreset = FinderDocumentPreset(
            displayName: "Legacy",
            fileExtension: "legacy"
        )!
        let legacyData = try JSONSerialization.data(withJSONObject: [
            "id": legacyPreset.id.uuidString,
            "displayName": legacyPreset.displayName,
            "fileExtension": legacyPreset.fileExtension
        ])
        let decodedLegacy = try JSONDecoder().decode(
            FinderDocumentPreset.self,
            from: legacyData
        )

        XCTAssertTrue(decodedLegacy.isEnabled)

        let catalog = FinderDocumentPreset.catalog(
            merging: [decodedLegacy],
            missingBuiltInsUseDefaults: false
        )
        XCTAssertTrue(catalog.contains {
            $0.id == decodedLegacy.id && $0.isEnabled
        })
        XCTAssertTrue(catalog.filter(\.isBuiltIn).allSatisfy { !$0.isEnabled })
    }

    func testBuiltInDocumentPresetCanBeDisabledButNotDeleted() {
        let defaults = isolatedDefaults()
        let settings = SettingsStore(defaults: defaults, livePreviewLimitProvider: { 6 })
        let text = FinderDocumentPreset.defaultPresets[0]

        settings.setFinderDocumentPresetEnabled(id: text.id, isEnabled: false)
        XCTAssertFalse(settings.finderDocumentPresets.first { $0.id == text.id }!.isEnabled)

        settings.deleteFinderDocumentPreset(id: text.id)
        XCTAssertNotNil(settings.finderDocumentPresets.first { $0.id == text.id })
        XCTAssertFalse(settings.finderDocumentPresets.first { $0.id == text.id }!.isEnabled)
    }

    func testCustomDocumentPresetCanBeRemoved() {
        let defaults = isolatedDefaults()
        let settings = SettingsStore(defaults: defaults, livePreviewLimitProvider: { 6 })
        let custom = FinderDocumentPreset(displayName: "Log", fileExtension: "log")!

        settings.addFinderDocumentPreset(custom)
        XCTAssertTrue(settings.finderDocumentPresets.contains { $0.id == custom.id })

        settings.deleteFinderDocumentPreset(id: custom.id)
        XCTAssertFalse(settings.finderDocumentPresets.contains { $0.id == custom.id })
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
        XCTAssertTrue(store.update(expected))
        XCTAssertFalse(store.update(expected))

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

        XCTAssertEqual(
            settings.finderLaunchShortcuts,
            FinderLaunchShortcut.catalog(
                merging: [app],
                missingBuiltInsUseDefaults: false
            )
        )
        XCTAssertEqual(settings.finderDocumentPresets, FinderDocumentPreset.defaultPresets)
    }

    func testQuickActionCatalogListsCommonApplicationsDisabledByDefault() {
        XCTAssertEqual(
            FinderLaunchShortcut.defaultShortcuts.map(\.displayName),
            [
                "Terminal",
                "iTerm2",
                "Visual Studio Code",
                "Sublime Text",
                "Sublime Merge",
                "Warp",
                "MarkText",
                "Obsidian",
                "Tabby",
                "Visual Studio",
                "Hyper",
                "Emacs",
                "CLion",
                "CotEditor",
                "HBuilderX",
                "PhpStorm",
                "PyCharm",
                "Typora",
                "WebStorm",
                "IntelliJ IDEA",
                "Android Studio",
                "AppCode",
                "DataGrip",
                "GoLand",
                "Rider",
                "RubyMine"
            ]
        )
        XCTAssertTrue(FinderLaunchShortcut.defaultShortcuts.allSatisfy { !$0.isEnabled })
        XCTAssertEqual(
            Set(FinderLaunchShortcut.defaultShortcuts.map(\.id)).count,
            FinderLaunchShortcut.defaultShortcuts.count
        )
        XCTAssertEqual(
            Set(FinderLaunchShortcut.defaultShortcuts.compactMap(\.bundleIdentifier)).count,
            FinderLaunchShortcut.defaultShortcuts.count
        )
    }

    func testLegacyQuickActionRemainsEnabledAndMergesIntoBuiltInCatalog() throws {
        let visualStudioCode = FinderLaunchShortcut.defaultShortcuts.first {
            $0.bundleIdentifier == "com.microsoft.VSCode"
        }!
        let legacyData = try JSONSerialization.data(withJSONObject: [
            "id": UUID().uuidString,
            "displayName": "Code",
            "bundleURLString": URL(
                fileURLWithPath: "/Applications/Visual Studio Code.app"
            ).absoluteString,
            "bundleIdentifier": "com.microsoft.VSCode"
        ])
        let decodedLegacy = try JSONDecoder().decode(
            FinderLaunchShortcut.self,
            from: legacyData
        )

        XCTAssertTrue(decodedLegacy.isEnabled)

        let catalog = FinderLaunchShortcut.catalog(
            merging: [decodedLegacy],
            missingBuiltInsUseDefaults: false
        )
        let merged = catalog.first { $0.id == visualStudioCode.id }

        XCTAssertEqual(merged?.displayName, "Visual Studio Code")
        XCTAssertTrue(merged?.isEnabled == true)
    }

    func testBuiltInQuickActionCanBeDisabledButNotDeleted() {
        let defaults = isolatedDefaults()
        let settings = SettingsStore(defaults: defaults, livePreviewLimitProvider: { 6 })
        let terminal = FinderLaunchShortcut.defaultShortcuts[0]

        settings.setFinderLaunchShortcutEnabled(id: terminal.id, isEnabled: true)
        XCTAssertTrue(settings.finderLaunchShortcuts.first { $0.id == terminal.id }!.isEnabled)

        settings.deleteFinderLaunchShortcut(id: terminal.id)
        XCTAssertNotNil(settings.finderLaunchShortcuts.first { $0.id == terminal.id })
        XCTAssertFalse(settings.finderLaunchShortcuts.first { $0.id == terminal.id }!.isEnabled)
    }

    func testChoosingBuiltInApplicationEnablesItsExistingCatalogEntry() {
        let defaults = isolatedDefaults()
        let settings = SettingsStore(defaults: defaults, livePreviewLimitProvider: { 6 })
        let builtIn = FinderLaunchShortcut.defaultShortcuts.first {
            $0.bundleIdentifier == "com.microsoft.VSCode"
        }!
        let installedURL = URL(fileURLWithPath: "/Custom/Visual Studio Code.app")

        settings.addFinderLaunchShortcut(FinderLaunchShortcut(
            displayName: "Code",
            bundleURLString: installedURL.absoluteString,
            bundleIdentifier: builtIn.bundleIdentifier
        ))

        let saved = settings.finderLaunchShortcuts.first { $0.id == builtIn.id }
        XCTAssertEqual(saved?.bundleURL, installedURL)
        XCTAssertTrue(saved?.isEnabled == true)
        XCTAssertEqual(
            settings.finderLaunchShortcuts.filter {
                $0.bundleIdentifier == builtIn.bundleIdentifier
            }.count,
            1
        )
    }

    func testFinderMenuOmitsDisabledQuickActions() {
        let context = FinderMenuContext(
            location: .selection,
            currentDirectory: nil,
            selectedURLs: [URL(fileURLWithPath: "/tmp/item")]
        )
        let disabled = FinderLaunchShortcut(
            displayName: "Disabled",
            bundleURLString: URL(fileURLWithPath: "/Applications").absoluteString,
            bundleIdentifier: "com.example.disabled",
            isEnabled: false
        )

        XCTAssertEqual(
            FinderMenuCatalog.entries(
                for: context,
                preferences: FinderMenuPreferences(
                    isEnabled: true,
                    launchShortcuts: [disabled]
                )
            ),
            [
                .action(.copySelectedPaths),
                .action(.showHiddenFiles),
                .action(.hideHiddenFiles)
            ]
        )
    }

    func testFinderRoutingRootAndStandardLocationsAreManaged() {
        let home = URL(fileURLWithPath: "/Users/omnidock-test", isDirectory: true)
        let desktop = home.appendingPathComponent("Desktop", isDirectory: true)
        let documents = home.appendingPathComponent("Documents", isDirectory: true)
        let downloads = home.appendingPathComponent("Downloads", isDirectory: true)
        let cloudDrive = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Mobile Documents", isDirectory: true)
            .appendingPathComponent("com~apple~CloudDocs", isDirectory: true)

        let directories = FinderObservationRoots.registeredURLs(homeDirectory: home)

        XCTAssertEqual(
            directories,
            [
                URL(fileURLWithPath: "/", isDirectory: true),
                desktop,
                documents,
                downloads,
                cloudDrive.appendingPathComponent("Desktop", isDirectory: true),
                cloudDrive.appendingPathComponent("Documents", isDirectory: true)
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

    private func descendantScrollViews(in view: NSView) -> [NSScrollView] {
        view.subviews.flatMap { child in
            (child as? NSScrollView).map { [$0] } ?? descendantScrollViews(in: child)
        }
    }
}

private final class FinderQuickActionLoaderProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var hasStartedFirstLookup = false
    private var isWaiting = false
    private var ranOnMainThread = false

    var firstLookupIsWaiting: Bool {
        lock.withLock { isWaiting }
    }

    var lookupRanOnMainThread: Bool {
        lock.withLock { ranOnMainThread }
    }

    func markFirstLookup() -> Bool {
        lock.withLock {
            guard !hasStartedFirstLookup else {
                return false
            }
            hasStartedFirstLookup = true
            isWaiting = true
            return true
        }
    }

    func recordLookupThread() {
        lock.withLock {
            ranOnMainThread = Thread.isMainThread
        }
    }
}
