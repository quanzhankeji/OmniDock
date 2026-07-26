import AppKit

@MainActor
public final class StatusMenuController: NSObject, NSMenuDelegate {
    private let settings: SettingsStore
    private let permissionService: PermissionService
    private let coordinator: DockInteractionCoordinator
    private let hotkeyRegistrationStatus: AppHotkeyRegistrationStatusStore
    private let windowCycleRegistrationStatus: WindowCycleRegistrationStatusStore
    private let clipboardHistoryService: ClipboardHistoryService?
    private let clipboardHistoryRegistrationStatus: ClipboardHistoryRegistrationStatus
    private let windowPlacementRegistrationStatus: WindowPlacementRegistrationStatusStore
    private let presentationCoordinator: ApplicationPresentationCoordinator
    private let onPermissionGateRequired: (PermissionFeature) -> Void
    private let onOpenPermissionOnboarding: () -> Void
    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    private lazy var settingsWindowController = SettingsWindowController(
        settings: settings,
        permissionService: permissionService,
        coordinator: coordinator,
        hotkeyRegistrationStatus: hotkeyRegistrationStatus,
        windowCycleRegistrationStatus: windowCycleRegistrationStatus,
        clipboardHistoryService: clipboardHistoryService,
        clipboardHistoryRegistrationStatus: clipboardHistoryRegistrationStatus,
        windowPlacementRegistrationStatus: windowPlacementRegistrationStatus,
        presentationCoordinator: presentationCoordinator,
        onPermissionGateRequired: onPermissionGateRequired,
        onOpenPermissionOnboarding: onOpenPermissionOnboarding
    )

    convenience init(
        settings: SettingsStore,
        permissionService: PermissionService,
        coordinator: DockInteractionCoordinator,
        hotkeyRegistrationStatus: AppHotkeyRegistrationStatusStore,
        windowCycleRegistrationStatus: WindowCycleRegistrationStatusStore? = nil,
        clipboardHistoryService: ClipboardHistoryService? = nil,
        clipboardHistoryRegistrationStatus: ClipboardHistoryRegistrationStatus? = nil,
        windowPlacementRegistrationStatus: WindowPlacementRegistrationStatusStore? = nil,
        onPermissionGateRequired: @escaping (PermissionFeature) -> Void,
        onOpenPermissionOnboarding: @escaping () -> Void = {}
    ) {
        self.init(
            settings: settings,
            permissionService: permissionService,
            coordinator: coordinator,
            hotkeyRegistrationStatus: hotkeyRegistrationStatus,
            windowCycleRegistrationStatus: windowCycleRegistrationStatus
                ?? WindowCycleRegistrationStatusStore(),
            clipboardHistoryService: clipboardHistoryService,
            clipboardHistoryRegistrationStatus: clipboardHistoryRegistrationStatus
                ?? ClipboardHistoryRegistrationStatus(),
            windowPlacementRegistrationStatus: windowPlacementRegistrationStatus
                ?? WindowPlacementRegistrationStatusStore(),
            presentationCoordinator: ApplicationPresentationCoordinator(),
            onPermissionGateRequired: onPermissionGateRequired,
            onOpenPermissionOnboarding: onOpenPermissionOnboarding
        )
    }

    init(
        settings: SettingsStore,
        permissionService: PermissionService,
        coordinator: DockInteractionCoordinator,
        hotkeyRegistrationStatus: AppHotkeyRegistrationStatusStore,
        windowCycleRegistrationStatus: WindowCycleRegistrationStatusStore,
        clipboardHistoryService: ClipboardHistoryService? = nil,
        clipboardHistoryRegistrationStatus: ClipboardHistoryRegistrationStatus? = nil,
        windowPlacementRegistrationStatus: WindowPlacementRegistrationStatusStore? = nil,
        presentationCoordinator: ApplicationPresentationCoordinator,
        onPermissionGateRequired: @escaping (PermissionFeature) -> Void,
        onOpenPermissionOnboarding: @escaping () -> Void
    ) {
        self.settings = settings
        self.permissionService = permissionService
        self.coordinator = coordinator
        self.hotkeyRegistrationStatus = hotkeyRegistrationStatus
        self.windowCycleRegistrationStatus = windowCycleRegistrationStatus
        self.clipboardHistoryService = clipboardHistoryService
        self.clipboardHistoryRegistrationStatus = clipboardHistoryRegistrationStatus
            ?? ClipboardHistoryRegistrationStatus()
        self.windowPlacementRegistrationStatus = windowPlacementRegistrationStatus
            ?? WindowPlacementRegistrationStatusStore()
        self.presentationCoordinator = presentationCoordinator
        self.onPermissionGateRequired = onPermissionGateRequired
        self.onOpenPermissionOnboarding = onOpenPermissionOnboarding
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsChanged),
            name: SettingsStore.changedNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    public func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "OD"
        item.button?.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        item.button?.image = nil
        item.button?.imagePosition = .noImage
        item.button?.toolTip = "OmniDock"
        statusItem = item

        let menu = NSMenu()
        menu.delegate = self
        statusMenu = menu
        item.menu = menu
        rebuildMenu()
    }

    public func menuWillOpen(_ menu: NSMenu) {
        coordinator.suspendDockClickMonitoring()
        rebuildMenu(menu)
    }

    public func menuDidClose(_ menu: NSMenu) {
        coordinator.resumeDockClickMonitoring()
    }

    @objc private func openSettingsTab(_ sender: NSMenuItem) {
        guard let tab = SettingsTab(rawValue: sender.tag) else {
            return
        }
        show(tab: tab)
    }

    func show(tab: SettingsTab) {
        settingsWindowController.show(tab: tab)
    }

    @objc private func quit(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }

    @objc private func settingsChanged(_ notification: Notification) {
        if SettingsStore.change(in: notification).affectsDockInteraction {
            coordinator.refreshForSettingsChange()
        }
        rebuildMenu()
    }

    @objc private func appDidBecomeActive() {
        coordinator.refreshPermissionsAndMonitors()
        settingsWindowController.refresh()
    }

    private func rebuildMenu() {
        guard let menu = statusMenu else {
            return
        }
        rebuildMenu(menu)
    }

    private func rebuildMenu(_ menu: NSMenu) {
        while menu.numberOfItems > 0 {
            menu.removeItem(at: 0)
        }

        for tab in SettingsTab.allCases {
            let item = NSMenuItem(
                title: tab.localizedTitle,
                action: #selector(openSettingsTab(_:)),
                keyEquivalent: tab == .settings ? "," : ""
            )
            item.target = self
            item.tag = tab.rawValue
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: AppStrings.text(.menuQuit), action: #selector(quit(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }
}
