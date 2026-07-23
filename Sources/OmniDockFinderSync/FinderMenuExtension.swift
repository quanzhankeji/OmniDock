import AppKit
import FinderSync

final class FinderMenuExtension: FIFinderSync {
    private let preferencesStore = FinderMenuPreferencesStore()
    private let requestMailbox = FinderFileRequestMailbox()

    override init() {
        super.init()
        let directories = FinderObservationRoots.registeredURLs()
        FIFinderSyncController.default().directoryURLs = directories
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        let preferences = preferencesStore.snapshot()
        guard preferences.isEnabled,
              let context = context(for: menuKind)
        else {
            return nil
        }

        let entries = FinderMenuCatalog.entries(for: context, isEnabled: preferences.isEnabled)
        guard !entries.isEmpty else {
            return nil
        }

        let menu = NSMenu(title: "OmniDock")
        for entry in entries {
            switch entry {
            case let .action(action):
                menu.addItem(menuItem(for: action, preferences: preferences))
            case let .documentSubmenu(actions):
                let parent = NSMenuItem(
                    title: FinderMenuLabels.documentSubmenuTitle(
                        languageIdentifier: preferences.languageIdentifier
                    ),
                    action: nil,
                    keyEquivalent: ""
                )
                let submenu = NSMenu(title: parent.title)
                for action in actions {
                    submenu.addItem(menuItem(for: action, preferences: preferences))
                }
                parent.submenu = submenu
                menu.addItem(parent)
            }
        }
        return menu
    }

    @objc private func performAction(_ sender: NSMenuItem) {
        guard preferencesStore.snapshot().isEnabled,
              let action = FinderMenuAction(menuTag: sender.tag),
              let context = context(for: action.location)
        else {
            return
        }

        switch action {
        case .copyCurrentDirectoryPath:
            copy(FinderPathList.text(for: context.currentDirectory.map { [$0] } ?? []))
        case .copySelectedPaths:
            copy(FinderPathList.text(for: context.selectedURLs))
        case .createTextFile, .createMarkdownFile:
            queueFileCreation(action, in: context.currentDirectory)
        }
    }

    private func menuItem(
        for action: FinderMenuAction,
        preferences: FinderMenuPreferences
    ) -> NSMenuItem {
        let item = NSMenuItem(
            title: FinderMenuLabels.title(for: action, languageIdentifier: preferences.languageIdentifier),
            action: #selector(performAction(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.tag = action.menuTag
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
            return FinderMenuContext(
                location: .selection,
                currentDirectory: nil,
                selectedURLs: controller.selectedItemURLs() ?? []
            )
        default:
            return nil
        }
    }

    private func context(for location: FinderMenuLocation) -> FinderMenuContext? {
        switch location {
        case .folderBackground:
            return context(for: .contextualMenuForContainer)
        case .selection:
            return context(for: .contextualMenuForItems)
        }
    }

    private func copy(_ string: String) {
        guard !string.isEmpty else {
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    private func queueFileCreation(_ action: FinderMenuAction, in directory: URL?) {
        guard let directory,
              action.documentKind != nil
        else {
            return
        }
        forwardFileCreation(action, directory: directory)
    }

    private func forwardFileCreation(_ action: FinderMenuAction, directory: URL) {
        do {
            let request = FinderFileRequest(
                action: action,
                directoryDisplayPath: directory.path
            )
            try requestMailbox.enqueue(request)
            if !NSWorkspace.shared.open(FinderActionRoute.url(for: request.id)) {
                requestMailbox.discard(id: request.id)
            }
        } catch {
            NSLog("OmniDock Finder extension could not create a file in %@: %@", directory.path, error.localizedDescription)
        }
    }
}
