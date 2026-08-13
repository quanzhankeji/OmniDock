import AppKit

enum MenuBarShelfState: Equatable {
    case tucked
    case visible

    var toggled: MenuBarShelfState {
        self == .tucked ? .visible : .tucked
    }
}

enum MenuBarShelfLayoutPolicy {
    static let visibleDividerLength: CGFloat = 10

    static func boundaryLength(
        for state: MenuBarShelfState,
        widestScreen: CGFloat
    ) -> CGFloat {
        switch state {
        case .visible:
            return visibleDividerLength
        case .tucked:
            return min(max(10_000, widestScreen * 2), 32_768)
        }
    }
}

enum MenuBarShelfAutoHidePolicy {
    static let allowedDelays = [5, 10, 15, 30, 60]

    static func normalizedDelay(_ value: Int) -> Int {
        allowedDelays.min { lhs, rhs in
            let lhsDistance = abs(lhs - value)
            let rhsDistance = abs(rhs - value)
            return lhsDistance == rhsDistance ? lhs < rhs : lhsDistance < rhsDistance
        } ?? 10
    }
}

@MainActor
final class MenuBarShelfService: NSObject {
    private let settings: SettingsStore
    private let onOpenSettings: () -> Void
    private var toggleItem: NSStatusItem?
    private var boundaryItem: NSStatusItem?
    private var boundaryMenu: NSMenu?
    private var autoHideTimer: Timer?
    private var state: MenuBarShelfState = .visible
    private var isRunning = false

    init(
        settings: SettingsStore,
        onOpenSettings: @escaping () -> Void = {}
    ) {
        self.settings = settings
        self.onOpenSettings = onOpenSettings
        super.init()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func start() {
        guard !isRunning else {
            return
        }
        isRunning = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsChanged(_:)),
            name: SettingsStore.changedNotification,
            object: settings
        )
        refresh()
    }

    func stop() {
        guard isRunning else {
            return
        }
        isRunning = false
        NotificationCenter.default.removeObserver(
            self,
            name: SettingsStore.changedNotification,
            object: settings
        )
        removeItems()
    }

    @objc private func settingsChanged(_ notification: Notification) {
        let change = SettingsStore.change(in: notification)
        guard change == .menuBarShelf || change == .language || change == .all else {
            return
        }
        refresh()
    }

    @objc private func toggleShelf(_ sender: NSStatusBarButton) {
        state = state.toggled
        applyState()
    }

    @objc private func autoHideTimerFired(_ timer: Timer) {
        guard settings.menuBarShelfEnabled, state == .visible else {
            return
        }
        state = .tucked
        applyState()
    }

    @objc func openSettings(_ sender: NSMenuItem) {
        onOpenSettings()
    }

    private func refresh() {
        guard settings.menuBarShelfEnabled else {
            removeItems()
            return
        }
        installItemsIfNeeded()
        updateLocalizedContent()
        applyState()
    }

    private func installItemsIfNeeded() {
        guard toggleItem == nil, boundaryItem == nil else {
            return
        }

        let toggleItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        toggleItem.autosaveName = "OmniDock.MenuBarShelf.Toggle"
        if let button = toggleItem.button {
            button.target = self
            button.action = #selector(toggleShelf(_:))
            button.sendAction(on: .leftMouseUp)
            button.imagePosition = .imageOnly
        }

        let boundaryItem = NSStatusBar.system.statusItem(
            withLength: MenuBarShelfLayoutPolicy.visibleDividerLength
        )
        boundaryItem.autosaveName = "OmniDock.MenuBarShelf.Boundary"
        if let button = boundaryItem.button {
            button.title = "│"
            button.font = .systemFont(ofSize: 14, weight: .regular)
        }
        let boundaryMenu = makeBoundaryMenu()
        boundaryItem.menu = boundaryMenu

        self.toggleItem = toggleItem
        self.boundaryItem = boundaryItem
        self.boundaryMenu = boundaryMenu
        state = .visible
    }

    func makeBoundaryMenu() -> NSMenu {
        let menu = NSMenu()
        let settingsItem = NSMenuItem(
            title: AppStrings.text(.menuSettings),
            action: #selector(openSettings(_:)),
            keyEquivalent: ""
        )
        settingsItem.target = self
        menu.addItem(settingsItem)
        return menu
    }

    private func applyState() {
        guard let boundaryItem, let button = toggleItem?.button else {
            return
        }
        boundaryItem.length = MenuBarShelfLayoutPolicy.boundaryLength(
            for: state,
            widestScreen: NSScreen.screens.map(\.frame.width).max() ?? 4_096
        )

        let symbolName = state == .tucked ? "chevron.left" : "chevron.right"
        let image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: AppStrings.text(.menuBarShelfToggleTooltip)
        )
        image?.isTemplate = true
        button.image = image
        button.toolTip = AppStrings.text(.menuBarShelfToggleTooltip)

        scheduleAutoHideIfNeeded()
    }

    private func updateLocalizedContent() {
        toggleItem?.button?.toolTip = AppStrings.text(.menuBarShelfToggleTooltip)
        if let button = boundaryItem?.button {
            let label = AppStrings.text(.menuBarShelfDividerTooltip)
            button.toolTip = label
            button.setAccessibilityLabel(label)
        }
        boundaryMenu?.item(at: 0)?.title = AppStrings.text(.menuSettings)
    }

    private func scheduleAutoHideIfNeeded() {
        autoHideTimer?.invalidate()
        autoHideTimer = nil
        guard state == .visible, settings.menuBarShelfAutoHideEnabled else {
            return
        }

        let timer = Timer(
            timeInterval: TimeInterval(settings.menuBarShelfAutoHideDelay),
            target: self,
            selector: #selector(autoHideTimerFired(_:)),
            userInfo: nil,
            repeats: false
        )
        RunLoop.main.add(timer, forMode: .common)
        autoHideTimer = timer
    }

    private func removeItems() {
        autoHideTimer?.invalidate()
        autoHideTimer = nil
        if let toggleItem {
            NSStatusBar.system.removeStatusItem(toggleItem)
        }
        if let boundaryItem {
            NSStatusBar.system.removeStatusItem(boundaryItem)
        }
        toggleItem = nil
        boundaryItem = nil
        boundaryMenu = nil
        state = .visible
    }
}
