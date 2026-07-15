import AppKit

@MainActor
final class ApplicationMainMenuController: NSObject, NSMenuItemValidation {
    private let onOpenSettings: () -> Void

    init(onOpenSettings: @escaping () -> Void) {
        self.onOpenSettings = onOpenSettings
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsChanged),
            name: SettingsStore.changedNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func install() {
        rebuild()
    }

    func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        let applicationMenu = NSMenu(title: "OmniDock")
        applicationMenu.addItem(menuItem(
            title: AppStrings.text(.mainMenuSettings),
            action: #selector(openSettings(_:)),
            keyEquivalent: ",",
            target: self
        ))
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(menuItem(
            title: AppStrings.text(.mainMenuHide),
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h",
            target: NSApp
        ))
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(menuItem(
            title: AppStrings.text(.mainMenuQuit),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q",
            target: NSApp
        ))
        addSubmenu(applicationMenu, title: "OmniDock", to: mainMenu)

        let editMenu = NSMenu(title: AppStrings.text(.mainMenuEdit))
        editMenu.addItem(menuItem(
            title: AppStrings.text(.mainMenuUndo),
            action: #selector(performUndo(_:)),
            keyEquivalent: "z",
            target: self
        ))
        editMenu.addItem(menuItem(
            title: AppStrings.text(.mainMenuRedo),
            action: #selector(performRedo(_:)),
            keyEquivalent: "z",
            modifiers: [.command, .shift],
            target: self
        ))
        editMenu.addItem(.separator())
        editMenu.addItem(menuItem(
            title: AppStrings.text(.mainMenuCut),
            action: #selector(NSText.cut(_:)),
            keyEquivalent: "x"
        ))
        editMenu.addItem(menuItem(
            title: AppStrings.text(.mainMenuCopy),
            action: #selector(NSText.copy(_:)),
            keyEquivalent: "c"
        ))
        editMenu.addItem(menuItem(
            title: AppStrings.text(.mainMenuPaste),
            action: #selector(NSText.paste(_:)),
            keyEquivalent: "v"
        ))
        editMenu.addItem(menuItem(
            title: AppStrings.text(.mainMenuSelectAll),
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"
        ))
        addSubmenu(editMenu, title: AppStrings.text(.mainMenuEdit), to: mainMenu)

        let windowMenu = NSMenu(title: AppStrings.text(.mainMenuWindow))
        windowMenu.addItem(menuItem(
            title: AppStrings.text(.mainMenuClose),
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        ))
        windowMenu.addItem(.separator())
        windowMenu.addItem(menuItem(
            title: AppStrings.text(.mainMenuBringAllToFront),
            action: #selector(NSApplication.arrangeInFront(_:)),
            keyEquivalent: "",
            target: NSApp
        ))
        addSubmenu(windowMenu, title: AppStrings.text(.mainMenuWindow), to: mainMenu)

        return mainMenu
    }

    @objc private func openSettings(_ sender: NSMenuItem) {
        onOpenSettings()
    }

    @objc private func performUndo(_ sender: NSMenuItem) {
        NSApp.sendAction(Selector(("undo:")), to: nil, from: sender)
    }

    @objc private func performRedo(_ sender: NSMenuItem) {
        NSApp.sendAction(Selector(("redo:")), to: nil, from: sender)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(performUndo(_:)):
            return NSApp.target(forAction: Selector(("undo:")), to: nil, from: menuItem) != nil
        case #selector(performRedo(_:)):
            return NSApp.target(forAction: Selector(("redo:")), to: nil, from: menuItem) != nil
        default:
            return true
        }
    }

    @objc private func settingsChanged() {
        rebuild()
    }

    private func rebuild() {
        let menu = makeMainMenu()
        NSApp.mainMenu = menu
        NSApp.windowsMenu = menu.items.last?.submenu
    }

    private func addSubmenu(_ submenu: NSMenu, title: String, to menu: NSMenu) {
        let rootItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menu.addItem(rootItem)
        menu.setSubmenu(submenu, for: rootItem)
    }

    private func menuItem(
        title: String,
        action: Selector?,
        keyEquivalent: String,
        modifiers: NSEvent.ModifierFlags = .command,
        target: AnyObject? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.keyEquivalentModifierMask = modifiers
        item.target = target
        return item
    }
}
