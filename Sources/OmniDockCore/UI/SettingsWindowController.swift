import AppKit

enum SettingsWindowLayoutMetrics {
    static let preferredContentSize = NSSize(width: 780, height: 700)
    static let minimumContentSize = NSSize(width: 760, height: 560)
    static let maximumContentSize = NSSize(width: 960, height: 900)

    static func normalizedContentSize(_ current: NSSize) -> NSSize {
        NSSize(
            width: min(
                max(current.width, minimumContentSize.width),
                maximumContentSize.width
            ),
            height: min(
                max(current.height, minimumContentSize.height),
                maximumContentSize.height
            )
        )
    }
}

public enum SettingsTab: Int, CaseIterable {
    case settings = 0
    case preview = 1
    case hotkeys = 2
    case finderExtension = 3
    case clipboardHistory = 4
    case windowPlacement = 5

    var titleKey: AppStringKey {
        switch self {
        case .settings:
            return .tabSettings
        case .preview:
            return .tabPreview
        case .hotkeys:
            return .tabHotkeys
        case .finderExtension:
            return .tabFinderExtension
        case .clipboardHistory:
            return .tabClipboardHistory
        case .windowPlacement:
            return .tabWindowPlacement
        }
    }

    var localizedTitle: String {
        AppStrings.text(titleKey)
    }
}

@MainActor
public final class SettingsWindowController: NSObject, NSTextFieldDelegate, NSSearchFieldDelegate, NSWindowDelegate {
    private static let privacyPolicyURL = URL(
        string: "https://github.com/quanzhankeji/OmniDock/blob/main/PRIVACY.md"
    )!
    private static let supportURL = URL(
        string: "https://github.com/quanzhankeji/OmniDock/blob/main/SUPPORT.md"
    )!

    private let settings: SettingsStore
    private let permissionService: PermissionService
    private weak var coordinator: DockInteractionCoordinator?
    private let hotkeyRegistrationStatus: AppHotkeyRegistrationStatusStore
    private let windowCycleRegistrationStatus: WindowCycleRegistrationStatusStore
    private let clipboardHistoryService: ClipboardHistoryService?
    private let clipboardHistoryRegistrationStatus: ClipboardHistoryRegistrationStatus
    private let windowPlacementRegistrationStatus: WindowPlacementRegistrationStatusStore
    private let presentationCoordinator: ApplicationPresentationCoordinator
    private let onPermissionGateRequired: (PermissionFeature) -> Void
    private let onOpenPermissionOnboarding: () -> Void

    private var window: NSWindow?
    private var segmentedControl: NSSegmentedControl?
    private var contentContainer: NSView?
    private var generalContentView: NSView?
    private var previewContentView: NSView?
    private var hotkeysContentView: NSView?
    private var finderExtensionContentView: NSView?
    private var clipboardHistoryContentView: NSView?
    private var windowPlacementContentView: NSView?
    private var windowPlacementSettingsView: WindowPlacementSettingsView?
    private var finderExtensionSettingsView: FinderExtensionSettingsView?
    private var languagePopupButton: NSPopUpButton?
    private var appearancePopupButton: NSPopUpButton?
    private var previewSwitch: NSSwitch?
    private var commandTabPreviewSwitch: NSSwitch?
    private var windowCycleSwitch: NSSwitch?
    private var windowCycleWarningField: NSTextField?
    private var livePreviewSwitch: NSSwitch?
    private var livePreviewLimitField: NSTextField?
    private var livePreviewLimitStepper: NSStepper?
    private var livePreviewLimitRangeField: NSTextField?
    private var dockClickSwitch: NSSwitch?
    private var minimizeDockClickSwitch: NSSwitch?
    private var hotkeysEnabledSwitch: NSSwitch?
    private var clipboardHistorySwitch: NSSwitch?
    private var clipboardHistoryLimitField: NSTextField?
    private var clipboardHistoryLimitStepper: NSStepper?
    private var clipboardHistoryWarningField: NSTextField?
    private var clipboardHistorySearchField: NSSearchField?
    private var clipboardHistoryListController: ClipboardHistoryListController?
    private var clipboardHistoryDetailPanel: ClipboardInspectorPanel?
    private var clipboardHistorySearchWorkItem: DispatchWorkItem?
    private var clipboardHistorySearchGeneration: UInt64 = 0
    private var clipboardHistoryAppliedRevision: UInt64?
    private var clipboardHistoryAppliedQuery = ""
    private var clipboardHistoryNeedsReload = true
    private var clipboardHistoryPreviewWorkItem: DispatchWorkItem?
    private var clipboardHistoryPendingPreviewRecordID: UUID?
    private var clipboardHistoryPreviewRecordID: UUID?
    private var clipboardHistoryPreviewGeneration = 0
    private var hotkeyGuidanceField: NSTextField?
    private var hotkeyHeaderHeightConstraint: NSLayoutConstraint?
    private var hotkeyBindingCountField: NSTextField?
    private var permissionViews: [PermissionKind: [PermissionStatusView]] = [:]
    private var hotkeyRowsStack: NSStackView?
    private var hotkeyWarnings: [UUID: String] = [:]
    private var applicationPicker: ApplicationPickerWindowController?
    private var applicationPickerGeneration: UInt = 0
    private var selectedTab: SettingsTab = .settings
    private var renderedLanguage: AppLanguage.Resolved?

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
            selector: #selector(settingsChanged(_:)),
            name: SettingsStore.changedNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowCycleRegistrationStatusChanged),
            name: WindowCycleRegistrationStatusStore.changedNotification,
            object: windowCycleRegistrationStatus
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(permissionStatusChanged),
            name: PermissionService.changedNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(hotkeyRegistrationStatusChanged),
            name: AppHotkeyRegistrationStatusStore.changedNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clipboardHistoryChanged),
            name: ClipboardHistoryService.changedNotification,
            object: clipboardHistoryService
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clipboardHistoryChanged),
            name: ClipboardHistoryRegistrationStatus.changedNotification,
            object: clipboardHistoryRegistrationStatus
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowPlacementStatusChanged),
            name: WindowPlacementRegistrationStatusStore.changedNotification,
            object: self.windowPlacementRegistrationStatus
        )
    }

    public func show(tab: SettingsTab = .settings) {
        presentationCoordinator.present(.settings)
        selectedTab = tab
        let isNewWindow = window == nil
        let window = window ?? makeWindow()
        self.window = window
        segmentedControl?.selectedSegment = tab.rawValue
        displaySelectedTab()
        refresh()
        if isNewWindow {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        if tab == .clipboardHistory {
            scheduleClipboardHistoryReload()
        }
    }

    public func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === window else {
            return
        }
        cancelClipboardHistoryReload()
        dismissClipboardHistoryPreview()
        applicationPickerGeneration &+= 1
        applicationPicker?.dismiss()
        applicationPicker = nil
        presentationCoordinator.dismiss(.settings)
    }

    public func refresh() {
        if let window {
            applyTheme(to: window)
        }
        if let window,
           renderedLanguage != AppLocalization.currentResolvedLanguage {
            hotkeyWarnings.removeAll()
            rebuildContentView(in: window)
        }
        refreshLanguageControl()
        refreshAppearanceControl()
        previewSwitch?.state = settings.showDockPreviews ? .on : .off
        commandTabPreviewSwitch?.state = settings.showCommandTabPreviews ? .on : .off
        commandTabPreviewSwitch?.isEnabled = settings.showDockPreviews
        windowCycleSwitch?.state = settings.windowCycleEnabled ? .on : .off
        windowCycleSwitch?.isEnabled = settings.showDockPreviews
        let switcherWarning = windowCycleRegistrationStatus.warning
        windowCycleWarningField?.stringValue = switcherWarning ?? ""
        windowCycleWarningField?.isHidden = switcherWarning == nil || !settings.showDockPreviews
        livePreviewSwitch?.state = settings.liveDockPreviewsEnabled ? .on : .off
        livePreviewSwitch?.isEnabled = settings.showDockPreviews
        refreshLivePreviewLimitControls()
        dockClickSwitch?.state = settings.toggleAppVisibilityOnDockClick ? .on : .off
        minimizeDockClickSwitch?.state = settings.minimizeWindowsOnDockClickInsteadOfHide ? .on : .off
        minimizeDockClickSwitch?.isEnabled = settings.toggleAppVisibilityOnDockClick
        hotkeysEnabledSwitch?.state = settings.hotkeysEnabled ? .on : .off
        clipboardHistorySwitch?.state = settings.clipboardHistoryEnabled ? .on : .off
        refreshClipboardHistoryLimitControls()
        refreshClipboardHistoryStatus()
        refreshHotkeyGuidanceVisibility()

        let snapshot = permissionService.snapshot()
        for kind in PermissionKind.allCases {
            for view in permissionViews[kind] ?? [] {
                view.update(isGranted: permissionService.isGranted(kind, in: snapshot))
            }
        }

        reloadHotkeyRows()
        finderExtensionSettingsView?.reload()
        if selectedTab == .clipboardHistory {
            scheduleClipboardHistoryReload()
        }
        windowPlacementSettingsView?.reload()
        applicationPicker?.refreshLocalization()
    }

    @objc private func changeTab(_ sender: NSSegmentedControl) {
        selectedTab = SettingsTab(rawValue: sender.selectedSegment) ?? .settings
        if selectedTab != .clipboardHistory {
            cancelClipboardHistoryReload()
            dismissClipboardHistoryPreview()
        }
        displaySelectedTab()
        refresh()
    }

    @objc private func windowCycleRegistrationStatusChanged() {
        refresh()
    }

    @objc private func changeLanguage(_ sender: NSPopUpButton) {
        guard let rawValue = sender.selectedItem?.representedObject as? String,
              let language = AppLanguage(rawValue: rawValue)
        else {
            return
        }
        settings.appLanguage = language
    }

    @objc private func togglePreview(_ sender: NSSwitch) {
        if sender.state == .on {
            guard canEnable(.dockPreview, sender: sender) else {
                return
            }
            settings.showDockPreviews = true
        } else {
            settings.showDockPreviews = false
            settings.windowCycleEnabled = false
        }
        livePreviewSwitch?.isEnabled = settings.showDockPreviews
        commandTabPreviewSwitch?.isEnabled = settings.showDockPreviews
        windowCycleSwitch?.isEnabled = settings.showDockPreviews
        refreshLivePreviewLimitControls()
    }

    @objc private func toggleCommandTabPreview(_ sender: NSSwitch) {
        if sender.state == .on {
            guard canEnable(.dockPreview, sender: sender) else {
                return
            }
            settings.showCommandTabPreviews = true
        } else {
            settings.showCommandTabPreviews = false
        }
    }

    @objc private func toggleWindowCycle(_ sender: NSSwitch) {
        if sender.state == .on {
            guard settings.showDockPreviews,
                  canEnable(.windowCycle, sender: sender)
            else {
                sender.state = .off
                return
            }
            settings.windowCycleEnabled = true
        } else {
            settings.windowCycleEnabled = false
        }
    }

    @objc private func toggleLivePreview(_ sender: NSSwitch) {
        if sender.state == .on {
            guard canEnable(.dockPreview, sender: sender) else {
                return
            }
            settings.liveDockPreviewsEnabled = true
        } else {
            settings.liveDockPreviewsEnabled = false
        }
        refreshLivePreviewLimitControls()
    }

    @objc private func commitLivePreviewLimit(_ sender: NSTextField) {
        settings.livePreviewWindowLimit = sender.integerValue
        refreshLivePreviewLimitControls()
    }

    @objc private func stepLivePreviewLimit(_ sender: NSStepper) {
        settings.livePreviewWindowLimit = Int(sender.doubleValue.rounded())
        refreshLivePreviewLimitControls()
    }

    @objc private func toggleClipboardHistory(_ sender: NSSwitch) {
        if sender.state == .off {
            clipboardHistoryRegistrationStatus.setWarning(nil)
        }
        settings.clipboardHistoryEnabled = sender.state == .on
        refresh()
    }

    @objc private func commitClipboardHistoryLimit(_ sender: NSTextField) {
        settings.clipboardHistoryLimit = sender.integerValue
        refreshClipboardHistoryLimitControls()
    }

    @objc private func stepClipboardHistoryLimit(_ sender: NSStepper) {
        settings.clipboardHistoryLimit = Int(sender.doubleValue.rounded())
        refreshClipboardHistoryLimitControls()
    }

    @objc private func clearClipboardHistory(_ sender: NSButton) {
        guard let window else {
            return
        }
        let alert = NSAlert()
        alert.messageText = AppStrings.text(.clipboardClearTitle)
        alert.informativeText = AppStrings.text(.clipboardClearDetail)
        alert.alertStyle = .warning
        alert.addButton(withTitle: AppStrings.text(.clipboardClearAll))
        alert.addButton(withTitle: AppStrings.text(.pickerCancel))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else {
                return
            }
            Task { @MainActor [weak self] in
                self?.clipboardHistoryService?.clear()
            }
        }
    }

    public func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else {
            return
        }
        if field === livePreviewLimitField {
            settings.livePreviewWindowLimit = field.integerValue
            refreshLivePreviewLimitControls()
        } else if field === clipboardHistoryLimitField {
            settings.clipboardHistoryLimit = field.integerValue
            refreshClipboardHistoryLimitControls()
        }
    }

    public func controlTextDidChange(_ obj: Notification) {
        guard obj.object as? NSSearchField === clipboardHistorySearchField else {
            return
        }
        clipboardHistoryNeedsReload = true
        scheduleClipboardHistoryReload(delay: 0.12)
    }

    private func refreshLivePreviewLimitControls() {
        let maximum = settings.livePreviewWindowLimitMaximum
        let value = settings.livePreviewWindowLimit
        let isEnabled = settings.showDockPreviews && settings.liveDockPreviewsEnabled

        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.allowsFloats = false
        formatter.minimum = 0
        formatter.maximum = NSNumber(value: maximum)

        livePreviewLimitField?.formatter = formatter
        livePreviewLimitField?.integerValue = value
        livePreviewLimitField?.isEnabled = isEnabled
        livePreviewLimitStepper?.minValue = 0
        livePreviewLimitStepper?.maxValue = Double(maximum)
        livePreviewLimitStepper?.doubleValue = Double(value)
        livePreviewLimitStepper?.isEnabled = isEnabled
        livePreviewLimitRangeField?.stringValue = "0-\(maximum)"
        livePreviewLimitRangeField?.textColor = isEnabled ? .secondaryLabelColor : .disabledControlTextColor
    }

    private func refreshClipboardHistoryLimitControls() {
        let value = settings.clipboardHistoryLimit
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.allowsFloats = false
        formatter.minimum = 1
        formatter.maximum = 999

        clipboardHistoryLimitField?.formatter = formatter
        clipboardHistoryLimitField?.integerValue = value
        clipboardHistoryLimitStepper?.minValue = 1
        clipboardHistoryLimitStepper?.maxValue = 999
        clipboardHistoryLimitStepper?.increment = 1
        clipboardHistoryLimitStepper?.integerValue = value
    }

    private func refreshLanguageControl() {
        guard let popup = languagePopupButton,
              let item = popup.itemArray.first(where: { $0.representedObject as? String == settings.appLanguage.rawValue })
        else {
            return
        }
        popup.select(item)
    }

    private func refreshAppearanceControl() {
        guard let popup = appearancePopupButton,
              let item = popup.itemArray.first(where: {
                  $0.representedObject as? String == settings.appAppearance.rawValue
              })
        else {
            return
        }
        popup.select(item)
    }

    @objc private func toggleDockClick(_ sender: NSSwitch) {
        if sender.state == .on {
            guard canEnable(.dockClick, sender: sender) else {
                return
            }
            settings.toggleAppVisibilityOnDockClick = true
        } else {
            settings.toggleAppVisibilityOnDockClick = false
        }
        minimizeDockClickSwitch?.isEnabled = settings.toggleAppVisibilityOnDockClick
    }

    @objc private func toggleMinimizeDockClick(_ sender: NSSwitch) {
        settings.minimizeWindowsOnDockClickInsteadOfHide = sender.state == .on
    }

    @objc private func toggleHotkeys(_ sender: NSSwitch) {
        if sender.state == .on {
            guard canEnable(.hotkeys, sender: sender) else {
                return
            }
            settings.hotkeysEnabled = true
        } else {
            settings.hotkeysEnabled = false
        }
        refreshHotkeyGuidanceVisibility()
    }

    private func canEnable(_ feature: PermissionFeature, sender: NSSwitch) -> Bool {
        let snapshot = permissionService.snapshot()
        guard PermissionFeatureGate.isSatisfied(for: feature, in: snapshot) else {
            sender.state = .off
            onPermissionGateRequired(feature)
            schedulePermissionRefreshes()
            refresh()
            return false
        }
        return true
    }

    @objc private func addApplication(_ sender: NSButton) {
        guard let window, applicationPicker == nil else {
            return
        }

        applicationPickerGeneration &+= 1
        let generation = applicationPickerGeneration
        let picker = ApplicationPickerWindowController(
            existingBindings: settings.appHotkeyBindings,
            onSelect: { [weak self] url in
                self?.addHotkeyTarget(at: url)
            },
            onClose: { [weak self] in
                guard self?.applicationPickerGeneration == generation else {
                    return
                }
                self?.applicationPicker = nil
            }
        )
        applicationPicker = picker
        picker.present(over: window)
    }

    private func presentFinderQuickActionPicker() {
        guard let window, applicationPicker == nil else {
            return
        }

        applicationPickerGeneration &+= 1
        let generation = applicationPickerGeneration
        let picker = ApplicationPickerWindowController(
            excluding: settings.finderLaunchShortcuts,
            onSelect: { [weak self] url in
                self?.addFinderLaunchShortcut(at: url)
            },
            onClose: { [weak self] in
                guard self?.applicationPickerGeneration == generation else {
                    return
                }
                self?.applicationPicker = nil
            }
        )
        applicationPicker = picker
        picker.present(over: window)
    }

    private func presentFinderDocumentTypeForm() {
        guard let window else {
            return
        }

        let form = FinderDocumentTypeFormView(
            nameLabel: AppStrings.text(.finderDocumentTypeName),
            fileExtensionLabel: AppStrings.text(.finderDocumentTypeExtension)
        )

        let alert = NSAlert()
        alert.messageText = AppStrings.text(.finderDocumentTypeAdd)
        alert.accessoryView = form
        alert.addButton(withTitle: AppStrings.text(.pickerSelect))
        alert.addButton(withTitle: AppStrings.text(.pickerCancel))
        alert.window.initialFirstResponder = form.nameField
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else {
                return
            }
            Task { @MainActor [weak self] in
                self?.saveFinderDocumentPreset(
                    name: form.nameField.stringValue,
                    fileExtension: form.fileExtensionField.stringValue
                )
            }
        }
    }

    @objc private func openPermissionOnboarding(_ sender: NSButton) {
        onOpenPermissionOnboarding()
    }

    @objc private func settingsChanged(_ notification: Notification) {
        if SettingsStore.change(in: notification) == .clipboardHistory {
            clipboardHistorySwitch?.state = settings.clipboardHistoryEnabled ? .on : .off
            refreshClipboardHistoryLimitControls()
            refreshClipboardHistoryStatus()
            return
        }
        refresh()
    }

    @objc private func changeAppearance(_ sender: NSPopUpButton) {
        guard let rawValue = sender.selectedItem?.representedObject as? String,
              let appearance = AppAppearance(rawValue: rawValue)
        else {
            refreshAppearanceControl()
            return
        }
        settings.appAppearance = appearance
    }

    @objc private func permissionStatusChanged() {
        refresh()
    }

    @objc private func hotkeyRegistrationStatusChanged() {
        refresh()
    }

    @objc private func clipboardHistoryChanged() {
        refreshClipboardHistoryStatus()
        clipboardHistoryNeedsReload = true
        scheduleClipboardHistoryReload()
    }

    @objc private func windowPlacementStatusChanged() {
        refresh()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: CGRect(
                origin: .zero,
                size: SettingsWindowLayoutMetrics.preferredContentSize
            ),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "OmniDock"
        window.delegate = self
        window.hidesOnDeactivate = false
        window.level = .normal
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.contentMinSize = SettingsWindowLayoutMetrics.minimumContentSize
        window.contentMaxSize = SettingsWindowLayoutMetrics.maximumContentSize
        window.contentView = makeContentView()
        applyTheme(to: window)
        return window
    }

    private func rebuildContentView(in window: NSWindow) {
        permissionViews.removeAll()
        generalContentView = nil
        previewContentView = nil
        hotkeysContentView = nil
        finderExtensionContentView = nil
        clipboardHistoryContentView = nil
        windowPlacementContentView = nil
        languagePopupButton = nil
        appearancePopupButton = nil
        previewSwitch = nil
        commandTabPreviewSwitch = nil
        windowCycleSwitch = nil
        windowCycleWarningField = nil
        livePreviewSwitch = nil
        livePreviewLimitField = nil
        livePreviewLimitStepper = nil
        livePreviewLimitRangeField = nil
        dockClickSwitch = nil
        minimizeDockClickSwitch = nil
        hotkeysEnabledSwitch = nil
        finderExtensionSettingsView = nil
        clipboardHistorySwitch = nil
        clipboardHistoryLimitField = nil
        clipboardHistoryLimitStepper = nil
        clipboardHistoryWarningField = nil
        clipboardHistorySearchField = nil
        clipboardHistoryListController = nil
        clipboardHistoryAppliedRevision = nil
        clipboardHistoryAppliedQuery = ""
        clipboardHistoryNeedsReload = true
        cancelClipboardHistoryReload()
        dismissClipboardHistoryPreview()
        windowPlacementSettingsView = nil
        hotkeyGuidanceField = nil
        hotkeyHeaderHeightConstraint = nil
        hotkeyBindingCountField = nil
        hotkeyRowsStack = nil
        window.contentView = makeContentView()
    }

    private func makeContentView() -> NSView {
        renderedLanguage = AppLocalization.currentResolvedLanguage
        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = OmniDockTheme.palette().canvas.cgColor

        let segmentedControl = NSSegmentedControl(
            labels: SettingsTab.allCases.map(\.localizedTitle),
            trackingMode: .selectOne,
            target: self,
            action: #selector(changeTab(_:))
        )
        segmentedControl.selectedSegment = selectedTab.rawValue
        segmentedControl.translatesAutoresizingMaskIntoConstraints = false
        segmentedControl.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )
        let segmentedControlWidth: CGFloat = 700
        let segmentWidth = segmentedControlWidth
            / CGFloat(segmentedControl.segmentCount)
        for index in 0..<segmentedControl.segmentCount {
            segmentedControl.setWidth(segmentWidth, forSegment: index)
        }
        self.segmentedControl = segmentedControl
        content.addSubview(segmentedControl)

        let contentContainer = NSView()
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        self.contentContainer = contentContainer
        content.addSubview(contentContainer)

        displaySelectedTab()

        NSLayoutConstraint.activate([
            segmentedControl.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            segmentedControl.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            segmentedControl.leadingAnchor.constraint(
                greaterThanOrEqualTo: content.leadingAnchor,
                constant: 24
            ),
            segmentedControl.trailingAnchor.constraint(
                lessThanOrEqualTo: content.trailingAnchor,
                constant: -24
            ),
            segmentedControl.widthAnchor.constraint(
                equalToConstant: segmentedControlWidth
            ),

            contentContainer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            contentContainer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            contentContainer.topAnchor.constraint(equalTo: segmentedControl.bottomAnchor, constant: 18),
            contentContainer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24)
        ])

        return content
    }

    private func makeGeneralTab() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18

        let settings = NSStackView()
        settings.orientation = .vertical
        settings.alignment = .leading
        settings.spacing = 12
        stack.addArrangedSubview(settings)

        settings.addArrangedSubview(makeSettingRow(
            title: AppStrings.text(.languageTitle),
            detail: AppStrings.text(.languageDetail),
            control: makeLanguageControl()
        ))

        settings.addArrangedSubview(makeSettingRow(
            title: AppStrings.text(.appearanceTitle),
            detail: AppStrings.text(.appearanceDetail),
            control: makeAppearanceControl()
        ))

        let permissions = makeCorePermissionSection()
        stack.addArrangedSubview(permissions)

        NSLayoutConstraint.activate([
            settings.widthAnchor.constraint(equalTo: stack.widthAnchor),
            permissions.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])

        return stack
    }

    private func makePreviewTab() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18

        let toggles = NSStackView()
        toggles.orientation = .vertical
        toggles.alignment = .leading
        toggles.spacing = 12
        stack.addArrangedSubview(toggles)

        let previewSwitch = NSSwitch()
        previewSwitch.target = self
        previewSwitch.action = #selector(togglePreview(_:))
        self.previewSwitch = previewSwitch
        toggles.addArrangedSubview(makeSettingRow(
            title: AppStrings.text(.settingsDockPreviewTitle),
            detail: AppStrings.text(.settingsDockPreviewDetail),
            control: previewSwitch
        ))

        let commandTabPreviewSwitch = NSSwitch()
        commandTabPreviewSwitch.target = self
        commandTabPreviewSwitch.action = #selector(toggleCommandTabPreview(_:))
        self.commandTabPreviewSwitch = commandTabPreviewSwitch
        toggles.addArrangedSubview(makeIndentedSettingRow(
            title: AppStrings.text(.settingsCommandTabPreviewTitle),
            detail: AppStrings.text(.settingsCommandTabPreviewDetail),
            control: commandTabPreviewSwitch
        ))

        let windowCycleSwitch = NSSwitch()
        windowCycleSwitch.target = self
        windowCycleSwitch.action = #selector(toggleWindowCycle(_:))
        self.windowCycleSwitch = windowCycleSwitch
        toggles.addArrangedSubview(makeSettingRow(
            title: AppStrings.text(.settingsWindowCycleTitle),
            detail: AppStrings.text(.settingsWindowCycleDetail),
            control: windowCycleSwitch
        ))

        let switcherWarning = NSTextField(labelWithString: "")
        switcherWarning.font = .systemFont(ofSize: 12)
        switcherWarning.textColor = .systemRed
        switcherWarning.lineBreakMode = .byWordWrapping
        switcherWarning.maximumNumberOfLines = 2
        switcherWarning.isHidden = true
        self.windowCycleWarningField = switcherWarning
        toggles.addArrangedSubview(makeIndentedAuxiliaryTextRow(switcherWarning))

        let livePreviewSwitch = NSSwitch()
        livePreviewSwitch.target = self
        livePreviewSwitch.action = #selector(toggleLivePreview(_:))
        self.livePreviewSwitch = livePreviewSwitch
        toggles.addArrangedSubview(makeIndentedSettingRow(
            title: AppStrings.text(.settingsLivePreviewTitle),
            detail: AppStrings.text(.settingsLivePreviewDetail),
            control: makeLivePreviewControl(switch: livePreviewSwitch)
        ))

        let dockClickSwitch = NSSwitch()
        dockClickSwitch.target = self
        dockClickSwitch.action = #selector(toggleDockClick(_:))
        self.dockClickSwitch = dockClickSwitch
        toggles.addArrangedSubview(makeSettingRow(
            title: AppStrings.text(.settingsDockClickTitle),
            detail: AppStrings.text(.settingsDockClickDetail),
            control: dockClickSwitch
        ))

        let minimizeDockClickSwitch = NSSwitch()
        minimizeDockClickSwitch.target = self
        minimizeDockClickSwitch.action = #selector(toggleMinimizeDockClick(_:))
        self.minimizeDockClickSwitch = minimizeDockClickSwitch
        toggles.addArrangedSubview(makeIndentedSettingRow(
            title: AppStrings.text(.settingsMinimizeTitle),
            detail: AppStrings.text(.settingsMinimizeDetail),
            control: minimizeDockClickSwitch
        ))

        toggles.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        return stack
    }

    private func makeCorePermissionSection() -> NSView {
        let permissions = NSStackView()
        permissions.orientation = .vertical
        permissions.alignment = .leading
        permissions.spacing = 8

        let permissionHeader = NSStackView()
        permissionHeader.orientation = .horizontal
        permissionHeader.alignment = .centerY
        permissionHeader.spacing = 8

        let permissionTitle = NSTextField(labelWithString: AppStrings.text(.settingsPermissionStatus))
        permissionTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        permissionTitle.textColor = .secondaryLabelColor

        let permissionGuideButton = NSButton(
            title: AppStrings.text(.settingsPermissionGuide),
            target: self,
            action: #selector(openPermissionOnboarding(_:))
        )
        permissionGuideButton.bezelStyle = .rounded

        permissionHeader.addArrangedSubview(permissionTitle)
        permissionHeader.addArrangedSubview(NSView())
        permissionHeader.addArrangedSubview(permissionGuideButton)
        permissions.addArrangedSubview(permissionHeader)
        permissionHeader.widthAnchor.constraint(equalTo: permissions.widthAnchor).isActive = true

        for kind in [
            PermissionKind.accessibility,
            .screenRecording,
            .inputMonitoring,
            .finderExtension,
            .folderAccess
        ] {
            let view = PermissionStatusView(kind: kind)
            view.onRequestPermission = { [weak self] kind in
                self?.openPermissionSettings(kind)
            }
            permissionViews[kind, default: []].append(view)
            permissions.addArrangedSubview(view)
        }

        let documentLinks = NSStackView()
        documentLinks.orientation = .horizontal
        documentLinks.alignment = .centerY
        documentLinks.spacing = 14
        documentLinks.addArrangedSubview(makeDocumentLinkButton(
            title: AppStrings.text(.settingsPrivacyPolicy),
            action: #selector(openPrivacyPolicy(_:))
        ))
        documentLinks.addArrangedSubview(makeDocumentLinkButton(
            title: AppStrings.text(.settingsSupport),
            action: #selector(openSupport(_:))
        ))
        permissions.addArrangedSubview(documentLinks)

        return permissions
    }

    private func makeHotkeysTab() -> NSView {
        let root = NSView()

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        let toolbar = NSView()
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        let hotkeysEnabledSwitch = NSSwitch()
        hotkeysEnabledSwitch.target = self
        hotkeysEnabledSwitch.action = #selector(toggleHotkeys(_:))
        self.hotkeysEnabledSwitch = hotkeysEnabledSwitch

        let enabledRow = makeSettingRow(
            title: AppStrings.text(.hotkeysEnableTitle),
            detail: AppStrings.text(.hotkeysEnableDetail),
            control: hotkeysEnabledSwitch
        )
        enabledRow.translatesAutoresizingMaskIntoConstraints = false

        let guidanceField = NSTextField(
            wrappingLabelWithString: HotkeyGuidancePresentation.message
        )
        guidanceField.font = .systemFont(ofSize: 12)
        guidanceField.textColor = .secondaryLabelColor
        guidanceField.lineBreakMode = .byWordWrapping
        guidanceField.maximumNumberOfLines = 2
        guidanceField.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )
        guidanceField.translatesAutoresizingMaskIntoConstraints = false
        self.hotkeyGuidanceField = guidanceField

        let addButton = NSButton(title: AppStrings.text(.hotkeysChooseApp), target: self, action: #selector(addApplication(_:)))
        addButton.bezelStyle = .rounded
        addButton.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(enabledRow)
        toolbar.addSubview(guidanceField)
        toolbar.addSubview(addButton)
        stack.addArrangedSubview(toolbar)

        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        scrollView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        let listHeader = NSStackView()
        listHeader.orientation = .horizontal
        listHeader.alignment = .centerY
        listHeader.translatesAutoresizingMaskIntoConstraints = false

        let listSpacer = NSView()
        let bindingCountField = NSTextField(labelWithString: "")
        bindingCountField.font = .systemFont(ofSize: 12)
        bindingCountField.textColor = .secondaryLabelColor
        bindingCountField.alignment = .right
        bindingCountField.translatesAutoresizingMaskIntoConstraints = false
        hotkeyBindingCountField = bindingCountField
        listHeader.addArrangedSubview(listSpacer)
        listHeader.addArrangedSubview(bindingCountField)
        stack.addArrangedSubview(listHeader)

        let rowsStack = NSStackView()
        rowsStack.orientation = .vertical
        rowsStack.alignment = .width
        rowsStack.spacing = 10
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        rowsStack.setContentHuggingPriority(.required, for: .vertical)
        rowsStack.setContentCompressionResistancePriority(.required, for: .vertical)
        self.hotkeyRowsStack = rowsStack

        let documentView = TopAnchoredDocumentView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(rowsStack)
        scrollView.documentView = documentView
        stack.addArrangedSubview(scrollView)

        let headerHeightConstraint = toolbar.heightAnchor.constraint(equalToConstant: HotkeyGuidancePresentation.headerHeight(
            hotkeysEnabled: settings.hotkeysEnabled
        ))
        self.hotkeyHeaderHeightConstraint = headerHeightConstraint

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            toolbar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            headerHeightConstraint,
            enabledRow.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor),
            enabledRow.topAnchor.constraint(equalTo: toolbar.topAnchor),
            enabledRow.trailingAnchor.constraint(lessThanOrEqualTo: addButton.leadingAnchor, constant: -16),
            guidanceField.leadingAnchor.constraint(equalTo: enabledRow.leadingAnchor),
            guidanceField.trailingAnchor.constraint(lessThanOrEqualTo: addButton.leadingAnchor, constant: -16),
            guidanceField.topAnchor.constraint(equalTo: enabledRow.bottomAnchor, constant: 4),
            addButton.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor),
            addButton.centerYAnchor.constraint(equalTo: enabledRow.centerYAnchor),

            listHeader.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            documentView.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.heightAnchor),
            rowsStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            rowsStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            rowsStack.topAnchor.constraint(equalTo: documentView.topAnchor),
            rowsStack.bottomAnchor.constraint(lessThanOrEqualTo: documentView.bottomAnchor)
        ])

        refreshHotkeyGuidanceVisibility()
        return root
    }

    private func makeClipboardHistoryTab() -> NSView {
        let root = NSView()

        let settingsStack = NSStackView()
        settingsStack.orientation = .vertical
        settingsStack.alignment = .leading
        settingsStack.spacing = 12
        settingsStack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(settingsStack)

        let enabledSwitch = NSSwitch()
        enabledSwitch.target = self
        enabledSwitch.action = #selector(toggleClipboardHistory(_:))
        clipboardHistorySwitch = enabledSwitch
        settingsStack.addArrangedSubview(makeSettingRow(
            title: AppStrings.text(.clipboardEnableTitle),
            detail: AppStrings.text(.clipboardEnableDetail),
            control: enabledSwitch
        ))

        let shortcutLabel = NSTextField(labelWithString: "⌘⇧C")
        shortcutLabel.font = .monospacedSystemFont(ofSize: 15, weight: .semibold)
        shortcutLabel.alignment = .center
        shortcutLabel.translatesAutoresizingMaskIntoConstraints = false
        shortcutLabel.widthAnchor.constraint(equalToConstant: 72).isActive = true
        settingsStack.addArrangedSubview(makeSettingRow(
            title: AppStrings.text(.clipboardShortcutTitle),
            detail: AppStrings.text(.clipboardShortcutDetail),
            control: shortcutLabel
        ))

        let warning = NSTextField(wrappingLabelWithString: "")
        warning.font = .systemFont(ofSize: 12)
        warning.textColor = .systemRed
        warning.maximumNumberOfLines = 3
        warning.isHidden = true
        clipboardHistoryWarningField = warning
        settingsStack.addArrangedSubview(makeIndentedAuxiliaryTextRow(warning))

        settingsStack.addArrangedSubview(makeSettingRow(
            title: AppStrings.text(.clipboardLimitTitle),
            detail: AppStrings.text(.clipboardLimitDetail),
            control: makeClipboardHistoryLimitControl()
        ))

        let privacyNote = NSTextField(wrappingLabelWithString: AppStrings.text(.clipboardPrivacyNote))
        privacyNote.font = .systemFont(ofSize: 12)
        privacyNote.textColor = .secondaryLabelColor
        privacyNote.maximumNumberOfLines = 3
        settingsStack.addArrangedSubview(privacyNote)

        let listHeader = NSStackView()
        listHeader.orientation = .horizontal
        listHeader.alignment = .centerY
        listHeader.spacing = 10
        listHeader.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(listHeader)

        let searchField = NSSearchField()
        searchField.placeholderString = AppStrings.text(.clipboardSearchPlaceholder)
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        clipboardHistorySearchField = searchField

        let clearButton = NSButton(
            title: AppStrings.text(.clipboardClearAll),
            target: self,
            action: #selector(clearClipboardHistory(_:))
        )
        clearButton.bezelStyle = .rounded
        listHeader.addArrangedSubview(searchField)
        listHeader.addArrangedSubview(clearButton)
        searchField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        clearButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        let listController = ClipboardHistoryListController()
        listController.onCopy = { [weak self] recordID in
            self?.clipboardHistoryService?.copy(id: recordID)
        }
        listController.onDelete = { [weak self] recordID in
            self?.clipboardHistoryService?.delete(id: recordID)
        }
        listController.onHoverChanged = { [weak self] recordID, hovering in
            self?.handleClipboardHistoryHover(
                recordID: recordID,
                hovering: hovering
            )
        }
        clipboardHistoryListController = listController
        let listView = listController.view
        listView.setContentHuggingPriority(.defaultLow, for: .vertical)
        listView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        root.addSubview(listView)

        for view in settingsStack.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: settingsStack.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            settingsStack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            settingsStack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            settingsStack.topAnchor.constraint(equalTo: root.topAnchor),

            listHeader.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            listHeader.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            listHeader.topAnchor.constraint(equalTo: settingsStack.bottomAnchor, constant: 16),

            listView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            listView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            listView.topAnchor.constraint(equalTo: listHeader.bottomAnchor, constant: 10),
            listView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            listView.heightAnchor.constraint(greaterThanOrEqualToConstant: 140)
        ])
        return root
    }

    private func makeLanguageControl() -> NSView {
        let popup = NSPopUpButton()
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.target = self
        popup.action = #selector(changeLanguage(_:))

        let items: [(AppLanguage, String)] = [
            (.system, AppStrings.text(.languageSystem)),
            (.zhHans, AppStrings.text(.languageChinese)),
            (.en, AppStrings.text(.languageEnglish))
        ]
        for (language, title) in items {
            popup.addItem(withTitle: title)
            popup.lastItem?.representedObject = language.rawValue
        }
        self.languagePopupButton = popup
        refreshLanguageControl()
        return popup
    }

    private func makeAppearanceControl() -> NSView {
        let popup = NSPopUpButton()
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.target = self
        popup.action = #selector(changeAppearance(_:))

        let items: [(AppAppearance, String)] = [
            (.system, AppStrings.text(.appearanceSystem)),
            (.light, AppStrings.text(.appearanceLight)),
            (.dark, AppStrings.text(.appearanceDark))
        ]
        for (appearance, title) in items {
            popup.addItem(withTitle: title)
            popup.lastItem?.representedObject = appearance.rawValue
        }
        appearancePopupButton = popup
        refreshAppearanceControl()
        return popup
    }

    private func applyTheme(to window: NSWindow) {
        OmniDockTheme.applyCurrentAppearance(to: window)
        window.contentView?.layer?.backgroundColor = OmniDockTheme.palette(
            for: window.appearance ?? window.effectiveAppearance
        ).canvas.cgColor
    }

    private func makeLivePreviewControl(switch livePreviewSwitch: NSSwitch) -> NSView {
        let controlStack = NSStackView()
        controlStack.orientation = .horizontal
        controlStack.alignment = .centerY
        controlStack.spacing = 8
        controlStack.translatesAutoresizingMaskIntoConstraints = false

        let countLabel = NSTextField(labelWithString: AppStrings.text(.settingsLiveWindowCount))
        countLabel.font = .systemFont(ofSize: 12)
        countLabel.textColor = .secondaryLabelColor

        let limitField = NSTextField()
        limitField.alignment = .right
        limitField.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        limitField.bezelStyle = .roundedBezel
        limitField.target = self
        limitField.action = #selector(commitLivePreviewLimit(_:))
        limitField.delegate = self
        self.livePreviewLimitField = limitField

        let stepper = NSStepper()
        stepper.increment = 1
        stepper.valueWraps = false
        stepper.target = self
        stepper.action = #selector(stepLivePreviewLimit(_:))
        self.livePreviewLimitStepper = stepper

        let rangeField = NSTextField(labelWithString: "")
        rangeField.font = .systemFont(ofSize: 12)
        rangeField.textColor = .secondaryLabelColor
        self.livePreviewLimitRangeField = rangeField

        controlStack.addArrangedSubview(countLabel)
        controlStack.addArrangedSubview(limitField)
        controlStack.addArrangedSubview(stepper)
        controlStack.addArrangedSubview(rangeField)
        controlStack.addArrangedSubview(livePreviewSwitch)

        NSLayoutConstraint.activate([
            limitField.widthAnchor.constraint(equalToConstant: 54)
        ])
        refreshLivePreviewLimitControls()
        return controlStack
    }

    private func makeClipboardHistoryLimitControl() -> NSView {
        let controlStack = NSStackView()
        controlStack.orientation = .horizontal
        controlStack.alignment = .centerY
        controlStack.spacing = 6

        let field = NSTextField()
        field.alignment = .right
        field.delegate = self
        field.target = self
        field.action = #selector(commitClipboardHistoryLimit(_:))
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 58).isActive = true
        clipboardHistoryLimitField = field

        let stepper = NSStepper()
        stepper.target = self
        stepper.action = #selector(stepClipboardHistoryLimit(_:))
        clipboardHistoryLimitStepper = stepper

        controlStack.addArrangedSubview(field)
        controlStack.addArrangedSubview(stepper)
        refreshClipboardHistoryLimitControls()
        return controlStack
    }

    private func makeSettingRow(title: String, detail: String, control: NSView) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let labels = NSStackView()
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 3
        labels.translatesAutoresizingMaskIntoConstraints = false

        let titleField = NSTextField(labelWithString: title)
        titleField.font = .systemFont(ofSize: 14, weight: .medium)
        titleField.textColor = .labelColor

        let detailField = NSTextField(wrappingLabelWithString: detail)
        detailField.font = .systemFont(ofSize: 12)
        detailField.textColor = .secondaryLabelColor
        detailField.lineBreakMode = .byWordWrapping
        detailField.maximumNumberOfLines = 2
        titleField.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )
        detailField.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )
        labels.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )

        labels.addArrangedSubview(titleField)
        labels.addArrangedSubview(detailField)

        control.translatesAutoresizingMaskIntoConstraints = false
        control.setAccessibilityLabel(title)
        row.addSubview(labels)
        row.addSubview(control)

        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            labels.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            labels.topAnchor.constraint(equalTo: row.topAnchor),
            labels.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: control.leadingAnchor, constant: -16),

            control.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            control.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            row.widthAnchor.constraint(greaterThanOrEqualToConstant: 360)
        ])

        return row
    }

    private func makeIndentedSettingRow(title: String, detail: String, control: NSView) -> NSView {
        let wrapper = NSView()
        wrapper.translatesAutoresizingMaskIntoConstraints = false

        let row = makeSettingRow(title: title, detail: detail, control: control)
        row.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(row)

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 24),
            row.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
            row.topAnchor.constraint(equalTo: wrapper.topAnchor),
            row.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor)
        ])

        return wrapper
    }

    private func makeIndentedAuxiliaryTextRow(_ textField: NSTextField) -> NSView {
        let wrapper = NSView()
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        textField.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(textField)
        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 24),
            textField.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
            textField.topAnchor.constraint(equalTo: wrapper.topAnchor),
            textField.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor)
        ])
        return wrapper
    }

    private func makeDocumentLinkButton(title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.isBordered = false
        button.font = .systemFont(ofSize: 12)
        button.contentTintColor = .linkColor
        return button
    }

    private func embed(_ view: NSView, in container: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
    }

    private func makeScrollableTab(_ content: NSView) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let documentView = TopAnchoredDocumentView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        content.setContentHuggingPriority(.required, for: .vertical)
        content.setContentCompressionResistancePriority(.required, for: .vertical)
        documentView.addSubview(content)
        scrollView.documentView = documentView

        NSLayoutConstraint.activate([
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            documentView.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.heightAnchor),
            content.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            content.topAnchor.constraint(equalTo: documentView.topAnchor),
            content.bottomAnchor.constraint(lessThanOrEqualTo: documentView.bottomAnchor)
        ])

        return scrollView
    }

    private func displaySelectedTab() {
        let existingViews: [(SettingsTab, NSView?)] = [
            (.settings, generalContentView),
            (.preview, previewContentView),
            (.hotkeys, hotkeysContentView),
            (.finderExtension, finderExtensionContentView),
            (.clipboardHistory, clipboardHistoryContentView),
            (.windowPlacement, windowPlacementContentView)
        ]
        guard let contentContainer,
              let selectedView = contentView(for: selectedTab) else {
            return
        }

        for (_, view) in existingViews where view !== selectedView {
            view?.removeFromSuperview()
        }
        selectedView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if selectedView.superview !== contentContainer {
            embed(selectedView, in: contentContainer)
        }
    }

    private func contentView(for tab: SettingsTab) -> NSView? {
        switch tab {
        case .settings:
            if generalContentView == nil {
                generalContentView = makeScrollableTab(makeGeneralTab())
            }
            return generalContentView
        case .preview:
            if previewContentView == nil {
                previewContentView = makeScrollableTab(makePreviewTab())
            }
            return previewContentView
        case .hotkeys:
            if hotkeysContentView == nil {
                hotkeysContentView = makeHotkeysTab()
            }
            return hotkeysContentView
        case .finderExtension:
            if finderExtensionContentView == nil {
                let settingsView = makeFinderExtensionSettingsView()
                finderExtensionSettingsView = settingsView
                finderExtensionContentView = settingsView
            }
            return finderExtensionContentView
        case .clipboardHistory:
            if clipboardHistoryContentView == nil {
                clipboardHistoryContentView = makeClipboardHistoryTab()
            }
            return clipboardHistoryContentView
        case .windowPlacement:
            if windowPlacementContentView == nil {
                let settingsView = WindowPlacementSettingsView(
                    settings: settings,
                    registrationStatus: windowPlacementRegistrationStatus
                )
                settingsView.onEnableRequest = { [weak self] sender in
                    self?.canEnable(.windowPlacement, sender: sender) ?? false
                }
                windowPlacementSettingsView = settingsView
                windowPlacementContentView = makeScrollableTab(settingsView)
            }
            return windowPlacementContentView
        }
    }

    private func makeFinderExtensionSettingsView() -> FinderExtensionSettingsView {
        let settingsView = FinderExtensionSettingsView(settings: settings)
        settingsView.onEnableRequest = { [weak self] sender in
            self?.canEnable(.finderExtension, sender: sender) ?? false
        }
        settingsView.onOpenExtensionManagement = {
            FinderExtensionActivation.showManagementInterface()
        }
        settingsView.onAddQuickAction = { [weak self] in
            self?.presentFinderQuickActionPicker()
        }
        settingsView.onRemoveQuickAction = { [weak self] id in
            self?.settings.deleteFinderLaunchShortcut(id: id)
        }
        settingsView.onAddDocumentType = { [weak self] in
            self?.presentFinderDocumentTypeForm()
        }
        settingsView.onRemoveDocumentType = { [weak self] id in
            self?.settings.deleteFinderDocumentPreset(id: id)
        }
        return settingsView
    }

    private func refreshClipboardHistoryStatus() {
        let warning = clipboardHistoryRegistrationStatus.warning
            ?? clipboardHistoryService?.snapshot().warning
            ?? ""
        clipboardHistoryWarningField?.stringValue = warning
        clipboardHistoryWarningField?.isHidden = warning.isEmpty
    }

    private func scheduleClipboardHistoryReload(delay: TimeInterval = 0) {
        guard selectedTab == .clipboardHistory,
              let listController = clipboardHistoryListController
        else {
            clipboardHistoryNeedsReload = true
            return
        }
        let snapshot = clipboardHistoryService?.snapshot()
            ?? ClipboardHistorySnapshot(records: [], warning: nil, revision: 0)
        let query = clipboardHistorySearchField?.stringValue ?? ""
        guard clipboardHistoryNeedsReload
            || clipboardHistoryAppliedRevision != snapshot.revision
            || clipboardHistoryAppliedQuery != query
        else {
            return
        }

        clipboardHistorySearchWorkItem?.cancel()
        clipboardHistorySearchGeneration &+= 1
        let generation = clipboardHistorySearchGeneration
        let workItem = DispatchWorkItem { [weak self, weak listController] in
            guard let self, let listController else {
                return
            }
            self.clipboardHistorySearchWorkItem = nil
            DispatchQueue.global(qos: .userInitiated).async {
                let filteredRecords = ClipboardArchiveSearch.filter(
                    snapshot.records,
                    query: query
                )
                DispatchQueue.main.async { [weak self, weak listController] in
                    guard let self,
                          let listController,
                          self.selectedTab == .clipboardHistory,
                          self.clipboardHistorySearchGeneration == generation
                    else {
                        return
                    }
                    self.applyClipboardHistoryRecords(
                        filteredRecords,
                        revision: snapshot.revision,
                        query: query,
                        to: listController
                    )
                }
            }
        }
        clipboardHistorySearchWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + delay,
            execute: workItem
        )
    }

    private func applyClipboardHistoryRecords(
        _ records: [ClipboardHistoryRecord],
        revision: UInt64,
        query: String,
        to listController: ClipboardHistoryListController
    ) {
        if let clipboardHistoryPendingPreviewRecordID,
           !records.contains(where: { $0.id == clipboardHistoryPendingPreviewRecordID }) {
            cancelPendingClipboardHistoryPreview()
        }
        if let clipboardHistoryPreviewRecordID,
           !records.contains(where: { $0.id == clipboardHistoryPreviewRecordID }) {
            dismissClipboardHistoryPreview()
        }
        listController.apply(records: records)
        clipboardHistoryAppliedRevision = revision
        clipboardHistoryAppliedQuery = query
        clipboardHistoryNeedsReload = false
    }

    private func cancelClipboardHistoryReload() {
        clipboardHistorySearchGeneration &+= 1
        clipboardHistorySearchWorkItem?.cancel()
        clipboardHistorySearchWorkItem = nil
    }

    private func handleClipboardHistoryHover(recordID: UUID, hovering: Bool) {
        switch ClipboardHoverPreviewPolicy.action(
            recordID: recordID,
            hovering: hovering,
            pendingRecordID: clipboardHistoryPendingPreviewRecordID,
            previewedRecordID: clipboardHistoryPreviewRecordID,
            previewVisible: clipboardHistoryDetailPanel?.isVisible == true
        ) {
        case .schedule:
            scheduleClipboardHistoryPreview(for: recordID)
        case .present:
            presentClipboardHistoryPreview(for: recordID)
        case .cancelPending:
            cancelPendingClipboardHistoryPreview()
        case .dismiss:
            dismissClipboardHistoryPreview()
        case .none:
            break
        }
    }

    private func scheduleClipboardHistoryPreview(for recordID: UUID) {
        cancelPendingClipboardHistoryPreview()
        clipboardHistoryPendingPreviewRecordID = recordID
        clipboardHistoryPreviewGeneration += 1
        let generation = clipboardHistoryPreviewGeneration
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.clipboardHistoryPreviewGeneration == generation,
                  self.clipboardHistoryPendingPreviewRecordID == recordID
            else {
                return
            }
            self.clipboardHistoryPreviewWorkItem = nil
            self.clipboardHistoryPendingPreviewRecordID = nil
            self.presentClipboardHistoryPreview(for: recordID)
        }
        clipboardHistoryPreviewWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + 0.4,
            execute: workItem
        )
    }

    private func presentClipboardHistoryPreview(for recordID: UUID) {
        cancelPendingClipboardHistoryPreview()
        guard selectedTab == .clipboardHistory,
              let window,
              window.isVisible,
              let content = clipboardHistoryService?.previewContent(id: recordID)
        else {
            dismissClipboardHistoryPreview()
            return
        }
        let detailPanel = clipboardHistoryDetailPanel ?? ClipboardInspectorPanel()
        clipboardHistoryDetailPanel = detailPanel
        clipboardHistoryPreviewRecordID = recordID
        detailPanel.present(content, beside: window)
    }

    private func cancelPendingClipboardHistoryPreview() {
        clipboardHistoryPreviewGeneration += 1
        clipboardHistoryPreviewWorkItem?.cancel()
        clipboardHistoryPreviewWorkItem = nil
        clipboardHistoryPendingPreviewRecordID = nil
    }

    private func dismissClipboardHistoryPreview() {
        cancelPendingClipboardHistoryPreview()
        clipboardHistoryDetailPanel?.dismiss()
        clipboardHistoryPreviewRecordID = nil
    }

    private func reloadHotkeyRows() {
        guard let hotkeyRowsStack else {
            return
        }
        hotkeyRowsStack.removeAllArrangedSubviews()

        let bindings = settings.appHotkeyBindings
        hotkeyBindingCountField?.stringValue = AppStrings.format(
            .hotkeysBoundCount,
            bindings.count
        )
        guard !bindings.isEmpty else {
            let label = NSTextField(labelWithString: AppStrings.text(.hotkeysEmpty))
            label.font = .systemFont(ofSize: 13)
            label.textColor = .secondaryLabelColor
            hotkeyRowsStack.addArrangedSubview(label)
            return
        }

        for binding in bindings {
            let row = AppHotkeyRowView(
                binding: binding,
                warning: HotkeyRowWarningPresentation.visibleWarning(warning(for: binding))
            )
            row.onShortcutChange = { [weak self] binding, shortcut in
                self?.applyRecordedShortcut(shortcut, to: binding)
            }
            row.onRemove = { [weak self] binding in
                self?.hotkeyWarnings[binding.id] = nil
                self?.hotkeyRegistrationStatus.clearWarning(for: binding.id)
                self?.settings.deleteAppHotkeyBinding(id: binding.id)
            }
            hotkeyRowsStack.addArrangedSubview(row)
        }
    }

    private func applyRecordedShortcut(_ shortcut: RecordedShortcut?, to binding: AppHotkeyBinding) {
        var updated = binding
        guard let shortcut else {
            updated.updateRecordedShortcut(nil)
            hotkeyWarnings[binding.id] = nil
            hotkeyRegistrationStatus.clearWarning(for: binding.id)
            settings.upsertAppHotkeyBinding(updated)
            return
        }

        let featureConflict = settings.windowPlacementConfiguration.commands.contains {
            $0.isEnabled && $0.shortcut == shortcut
        } || (settings.windowCycleEnabled && shortcut == WindowCycleShortcut.recorded)
        if featureConflict {
            updated.updateRecordedShortcut(nil)
            hotkeyWarnings[binding.id] = AppStrings.text(.windowPlacementShortcutConflict)
        } else if let reason = ShortcutRecorderValidation.rejectionReason(
            for: shortcut,
            existingBindings: settings.appHotkeyBindings,
            excluding: binding.id,
            reservedShortcuts: settings.clipboardHistoryEnabled
                ? [ClipboardHistoryShortcut.recorded]
                : []
        ) {
            updated.updateRecordedShortcut(nil)
            hotkeyWarnings[binding.id] = reason
        } else {
            updated.updateRecordedShortcut(shortcut)
            hotkeyWarnings[binding.id] = nil
            hotkeyRegistrationStatus.clearWarning(for: binding.id)
        }
        settings.upsertAppHotkeyBinding(updated)
    }

    private func warning(for binding: AppHotkeyBinding) -> String? {
        hotkeyWarnings[binding.id]
            ?? hotkeyRegistrationStatus.warning(for: binding.id)
            ?? binding.recordedShortcut.flatMap { shortcut in
                if settings.windowPlacementConfiguration.commands.contains(where: { command in
                    command.isEnabled && command.shortcut == shortcut
                }) || (settings.windowCycleEnabled && shortcut == WindowCycleShortcut.recorded) {
                    return AppStrings.text(.windowPlacementShortcutConflict)
                }
                return ShortcutRecorderValidation.rejectionReason(
                    for: shortcut,
                    reservedShortcuts: settings.clipboardHistoryEnabled
                        ? [ClipboardHistoryShortcut.recorded]
                        : []
                )
            }
    }

    private func refreshHotkeyGuidanceVisibility() {
        let isVisible = HotkeyGuidancePresentation.isVisible(hotkeysEnabled: settings.hotkeysEnabled)
        hotkeyGuidanceField?.isHidden = !isVisible
        hotkeyHeaderHeightConstraint?.constant = HotkeyGuidancePresentation.headerHeight(
            hotkeysEnabled: settings.hotkeysEnabled
        )
    }

    private func addHotkeyTarget(at url: URL) {
        guard let bundle = Bundle(url: url) else {
            return
        }

        let bindings = settings.appHotkeyBindings
        if bindings.contains(where: { $0.bundleURL == url || $0.bundleIdentifier == bundle.bundleIdentifier }) {
            return
        }

        let displayName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? FileManager.default.displayName(atPath: url.path)
        let binding = AppHotkeyBinding(
            appName: displayName,
            bundleURLString: url.absoluteString,
            bundleIdentifier: bundle.bundleIdentifier
        )
        settings.upsertAppHotkeyBinding(binding)
    }

    private func addFinderLaunchShortcut(at url: URL) {
        guard let bundle = Bundle(url: url) else {
            return
        }
        let displayName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? FileManager.default.displayName(atPath: url.path)
        settings.addFinderLaunchShortcut(FinderLaunchShortcut(
            displayName: displayName,
            bundleURLString: url.absoluteString,
            bundleIdentifier: bundle.bundleIdentifier
        ))
    }

    private func saveFinderDocumentPreset(name: String, fileExtension: String) {
        guard let preset = FinderDocumentPreset(
            displayName: name,
            fileExtension: fileExtension
        ) else {
            presentFinderConfigurationWarning(.finderDocumentTypeInvalid)
            return
        }
        guard !settings.finderDocumentPresets.contains(where: {
            $0.fileExtension.caseInsensitiveCompare(preset.fileExtension) == .orderedSame
        }) else {
            presentFinderConfigurationWarning(.finderDocumentTypeDuplicate)
            return
        }
        settings.addFinderDocumentPreset(preset)
    }

    private func presentFinderConfigurationWarning(_ key: AppStringKey) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = AppStrings.text(key)
        alert.addButton(withTitle: AppStrings.text(.finderExtensionFailureDismiss))
        if let window {
            alert.beginSheetModal(for: window)
        }
    }

    private func openPermissionSettings(_ kind: PermissionKind) {
        permissionService.openPrivacySettings(for: kind)
        schedulePermissionRefreshes()
        refresh()
    }

    @objc private func openPrivacyPolicy(_ sender: NSButton) {
        NSWorkspace.shared.open(Self.privacyPolicyURL)
    }

    @objc private func openSupport(_ sender: NSButton) {
        NSWorkspace.shared.open(Self.supportURL)
    }

    private func schedulePermissionRefreshes() {
        for delay in [0.5, 1.5, 3.0, 6.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                Task { @MainActor [weak self] in
                    self?.coordinator?.refreshPermissionsAndMonitors()
                    self?.refresh()
                }
            }
        }
    }
}
