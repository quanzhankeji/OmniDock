import AppKit
import FinderSync

final class FinderMenuExtension: FIFinderSync {
    private let preferencesStore = FinderMenuPreferencesStore()
    private let commandMailbox = FinderCommandMailbox()
    private let actionRegistry = FinderMenuActionRegistry()

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

        let entries = FinderMenuCatalog.entries(for: context, preferences: preferences)
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
        guard preferencesStore.snapshot().isEnabled,
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
        case let .createDocument(preset):
            guard let directory = binding.context.currentDirectory else {
                return
            }
            forward(.createDocument(
                fileExtension: preset.fileExtension,
                directoryDisplayPath: directory.path
            ))
        case let .openSelection(shortcut):
            let paths = binding.context.selectedURLs.map(\.path)
            guard !paths.isEmpty else {
                return
            }
            forward(.openSelection(
                shortcut: shortcut,
                selectedDisplayPaths: paths
            ))
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
        if case let .openSelection(shortcut) = action,
           let applicationURL = shortcut.bundleURL {
            let icon = NSWorkspace.shared.icon(forFile: applicationURL.path)
            icon.size = CGSize(width: 16, height: 16)
            item.image = icon
        }
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
}
