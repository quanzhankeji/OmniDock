import AppKit
import FinderSync
import UniformTypeIdentifiers
import OSLog

final class FinderMenuExtension: FIFinderSync {
    private static let logger = Logger(
        subsystem: "com.quanzhankeji.OmniDock.FinderSync",
        category: "FinderMenu"
    )

    private let preferencesStore = FinderMenuPreferencesStore()
    private let commandMailbox = FinderCommandMailbox()
    private let actionRegistry = FinderMenuActionRegistry()
    private let menuCache = FinderMenuBuildCache()
    private var configuredObservationRoots: Set<URL> = []

    override init() {
        super.init()
        configureObservationRoots()
        Self.logger.info("Finder extension started")
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(preferencesDidChange),
            name: FinderMenuPreferencesStore.didChangeNotification,
            object: nil
        )
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    override func beginObservingDirectory(at url: URL) {
        Self.logger.debug(
            "Finder began observing \(Self.directoryKind(for: url), privacy: .public)"
        )
    }

    override func endObservingDirectory(at url: URL) {
        Self.logger.debug(
            "Finder stopped observing \(Self.directoryKind(for: url), privacy: .public)"
        )
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        let preferences = menuCache.preferences { self.preferencesStore.snapshot() }
        Self.logger.debug(
            "Finder requested \(Self.menuKindName(menuKind), privacy: .public); enabled: \(preferences.isEnabled)"
        )
        guard preferences.isEnabled,
              let context = context(for: menuKind)
        else {
            return nil
        }

        let entries = FinderMenuCatalog.entries(
            for: context,
            preferences: preferences,
            resolveApplication: { self.menuCache.applicationURL(for: $0) },
            acceptsDirectories: { self.menuCache.acceptsDirectories($0) }
        )
        guard !entries.isEmpty else {
            return nil
        }

        let menu = NSMenu(title: "OmniDock")
        for entry in entries {
            switch entry {
            case let .action(action):
                menu.addItem(menuItem(
                    for: action,
                    context: context,
                    preferences: preferences
                ))
            case let .documentSubmenu(actions):
                let parent = NSMenuItem(
                    title: FinderMenuLabels.documentSubmenuTitle(
                        languageIdentifier: preferences.languageIdentifier
                    ),
                    action: nil,
                    keyEquivalent: ""
                )
                parent.image = Self.symbol("plus.rectangle.on.folder")
                let submenu = NSMenu(title: parent.title)
                for action in actions {
                    submenu.addItem(menuItem(
                        for: action,
                        context: context,
                        preferences: preferences
                    ))
                }
                parent.submenu = submenu
                menu.addItem(parent)
            case let .commandSubmenu(actions):
                let parent = NSMenuItem(
                    title: FinderMenuLabels.commandSubmenuTitle(
                        languageIdentifier: preferences.languageIdentifier
                    ),
                    action: nil,
                    keyEquivalent: ""
                )
                parent.image = Self.symbol("list.bullet")
                let submenu = NSMenu(title: parent.title)
                for action in actions {
                    submenu.addItem(menuItem(
                        for: action,
                        context: context,
                        preferences: preferences
                    ))
                }
                parent.submenu = submenu
                menu.addItem(parent)
            case let .applicationSubmenu(actions):
                let parent = NSMenuItem(
                    title: FinderMenuLabels.applicationSubmenuTitle(
                        languageIdentifier: preferences.languageIdentifier
                    ),
                    action: nil,
                    keyEquivalent: ""
                )
                parent.image = Self.symbol("square.grid.2x2")
                let submenu = NSMenu(title: parent.title)
                for action in actions {
                    submenu.addItem(menuItem(
                        for: action,
                        context: context,
                        preferences: preferences
                    ))
                }
                parent.submenu = submenu
                menu.addItem(parent)
            }
        }
        return menu
    }

    @objc private func performAction(_ sender: NSMenuItem) {
        guard menuCache.preferences({ self.preferencesStore.snapshot() }).isEnabled,
              let binding = actionRegistry.consume(token: sender.tag)
        else {
            return
        }

        switch binding.action {
        case .copyCurrentDirectoryPath:
            copy(FinderPathList.text(
                for: binding.context.currentDirectory.map { [$0] } ?? []
            ))
        case .copySelectedPaths:
            copy(FinderPathList.text(for: binding.context.selectedURLs))
        case .showHiddenFiles:
            forward(.setHiddenFilesVisible(true))
        case .hideHiddenFiles:
            forward(.setHiddenFilesVisible(false))
        case let .createDocument(preset):
            guard let directory = binding.context.currentDirectory else {
                return
            }
            forward(.createDocument(
                fileExtension: preset.fileExtension,
                directoryDisplayPath: directory.path
            ))
        case let .openDirectory(shortcut):
            guard let directory = binding.context.currentDirectory else {
                return
            }
            forward(.openDirectory(
                shortcut: shortcut,
                directoryDisplayPath: directory.path
            ))
        }
    }

    fileprivate static let menuIconSize = CGSize(width: 16, height: 16)

    private static func symbol(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        image?.isTemplate = true
        image?.size = menuIconSize
        return image
    }

    private func icon(for action: FinderMenuAction) -> NSImage? {
        switch action {
        case .copyCurrentDirectoryPath, .copySelectedPaths:
            return Self.symbol("doc.on.doc")
        case .showHiddenFiles:
            return Self.symbol("eye")
        case .hideHiddenFiles:
            return Self.symbol("eye.slash")
        case let .createDocument(preset):
            // The real document icon for the type reads faster than a generic
            // symbol when a dozen of them are listed together.
            return menuCache.documentIcon(forFileExtension: preset.fileExtension)
                ?? Self.symbol("doc")
        case let .openDirectory(shortcut):
            // Resolved, not the stored path: an application that moved still
            // shows its own icon.
            guard let applicationURL = menuCache.applicationURL(for: shortcut) else {
                return Self.symbol("app")
            }
            return menuCache.applicationIcon(at: applicationURL)
        }
    }

    private func menuItem(
        for action: FinderMenuAction,
        context: FinderMenuContext,
        preferences: FinderMenuPreferences
    ) -> NSMenuItem {
        let item = NSMenuItem(
            title: FinderMenuLabels.title(for: action, languageIdentifier: preferences.languageIdentifier),
            action: #selector(performAction(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.tag = actionRegistry.issueToken(for: FinderMenuCommandBinding(
            action: action,
            context: context
        ))
        item.image = icon(for: action)
        return item
    }

    private func context(for menuKind: FIMenuKind) -> FinderMenuContext? {
        let controller = FIFinderSyncController.default()
        switch menuKind {
        case .contextualMenuForContainer:
            return FinderMenuContext(
                location: .folderBackground,
                currentDirectory: FinderObservationRoots.folderURL(
                    targetedURL: controller.targetedURL()
                ),
                selectedURLs: []
            )
        case .contextualMenuForItems:
            let selectedURLs = controller.selectedItemURLs() ?? []
            return FinderMenuContext(
                location: .selection,
                currentDirectory: FinderObservationRoots.folderURL(
                    targetedURL: controller.targetedURL(),
                    selectedURLs: selectedURLs
                ),
                selectedURLs: selectedURLs
            )
        default:
            return nil
        }
    }

    @objc private func preferencesDidChange() {
        menuCache.invalidate()
        DispatchQueue.main.async { [weak self] in
            self?.configureObservationRoots()
        }
    }

    private func configureObservationRoots() {
        let preferences = menuCache.preferences { self.preferencesStore.snapshot() }
        let roots = FinderObservationRoots.registeredURLs(
            authorizedDirectoryPaths: preferences.observationRootPaths
        )
        guard roots != configuredObservationRoots else {
            return
        }

        configuredObservationRoots = roots
        FIFinderSyncController.default().directoryURLs = roots
        Self.logger.info("Configured \(roots.count) Finder observation roots")
    }

    private func copy(_ string: String) {
        guard !string.isEmpty else {
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    private func forward(_ command: FinderCommand) {
        do {
            let request = FinderCommandEnvelope(command: command)
            try commandMailbox.enqueue(request)
            FinderCommandSignal.post(requestID: request.id)
            _ = NSWorkspace.shared.open(FinderActionRoute.url(for: request.id))
        } catch {
            NSLog(
                "OmniDock Finder extension could not forward a command: %@",
                error.localizedDescription
            )
        }
    }

    private static func directoryKind(for url: URL) -> String {
        let standardized = url.standardizedFileURL
        let home = FileManager.default.homeDirectoryForCurrentUser
        if standardized.path == "/" {
            return "filesystem-root"
        }
        if standardized == FinderObservationRoots.desktopURL(homeDirectory: home).standardizedFileURL {
            return "desktop"
        }
        if standardized == home.appendingPathComponent("Documents").standardizedFileURL {
            return "documents"
        }
        if standardized == home.appendingPathComponent("Downloads").standardizedFileURL {
            return "downloads"
        }
        return "authorized-directory"
    }

    private static func menuKindName(_ menuKind: FIMenuKind) -> String {
        switch menuKind {
        case .contextualMenuForContainer:
            return "container-menu"
        case .contextualMenuForItems:
            return "item-menu"
        case .contextualMenuForSidebar:
            return "sidebar-menu"
        case .toolbarItemMenu:
            return "toolbar-menu"
        @unknown default:
            return "unknown-menu"
        }
    }
}

// Finder blocks while it waits for the menu, and everything needed to build one
// is stable between changes: the preferences file, where each configured
// application lives, and whether it takes a folder. Reading and resolving all of
// it on every right-click is what made the menu appear late. The cache is
// dropped whenever the containing app reports a change.
private final class FinderMenuBuildCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cachedPreferences: FinderMenuPreferences?
    private var applicationURLs: [UUID: URL?] = [:]
    private var directorySupport: [String: Bool] = [:]
    private var icons: [String: NSImage] = [:]

    func preferences(_ load: () -> FinderMenuPreferences) -> FinderMenuPreferences {
        lock.lock()
        if let cachedPreferences {
            lock.unlock()
            return cachedPreferences
        }
        lock.unlock()

        // Loading outside the lock keeps a slow read from blocking a concurrent
        // menu request; both would produce the same value.
        let loaded = load()
        lock.lock()
        cachedPreferences = loaded
        lock.unlock()
        return loaded
    }

    func applicationURL(for shortcut: FinderLaunchShortcut) -> URL? {
        lock.lock()
        if let cached = applicationURLs[shortcut.id] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let resolved = FinderApplicationTargetResolver.resolve(shortcut: shortcut)
        lock.lock()
        applicationURLs[shortcut.id] = resolved
        lock.unlock()
        return resolved
    }

    func acceptsDirectories(_ applicationURL: URL) -> Bool {
        let key = applicationURL.path
        lock.lock()
        if let cached = directorySupport[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let accepts = FinderApplicationDirectorySupport.acceptsDirectories(
            applicationURL: applicationURL
        )
        lock.lock()
        directorySupport[key] = accepts
        lock.unlock()
        return accepts
    }

    func applicationIcon(at applicationURL: URL) -> NSImage {
        let key = applicationURL.path
        lock.lock()
        if let cached = icons[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let icon = NSWorkspace.shared.icon(forFile: key)
        icon.size = FinderMenuExtension.menuIconSize
        lock.lock()
        icons[key] = icon
        lock.unlock()
        return icon
    }

    func documentIcon(forFileExtension fileExtension: String) -> NSImage? {
        let key = "ext:\(fileExtension)"
        lock.lock()
        if let cached = icons[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        guard let type = UTType(filenameExtension: fileExtension) else {
            return nil
        }
        let icon = NSWorkspace.shared.icon(for: type)
        icon.size = FinderMenuExtension.menuIconSize
        lock.lock()
        icons[key] = icon
        lock.unlock()
        return icon
    }

    func invalidate() {
        lock.lock()
        cachedPreferences = nil
        applicationURLs.removeAll()
        directorySupport.removeAll()
        icons.removeAll()
        lock.unlock()
    }
}
