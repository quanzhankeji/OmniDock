import AppKit

public enum SettingsTab: Int {
    case settings = 0
    case preview = 1
    case hotkeys = 2
    case finderExtension = 3
}

@MainActor
public final class SettingsWindowController: NSObject, NSTextFieldDelegate, NSWindowDelegate {
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
    private var finderExtensionSwitch: NSSwitch?
    private var finderExtensionSetupView: NSView?
    private var finderLaunchShortcutsGroupedSwitch: NSSwitch?
    private var finderLaunchShortcutsStack: NSStackView?
    private var finderDocumentPresetsStack: NSStackView?
    private var hotkeyGuidanceField: NSTextField?
    private var hotkeyHeaderHeightConstraint: NSLayoutConstraint?
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
        presentationCoordinator: ApplicationPresentationCoordinator,
        onPermissionGateRequired: @escaping (PermissionFeature) -> Void,
        onOpenPermissionOnboarding: @escaping () -> Void
    ) {
        self.settings = settings
        self.permissionService = permissionService
        self.coordinator = coordinator
        self.hotkeyRegistrationStatus = hotkeyRegistrationStatus
        self.windowCycleRegistrationStatus = windowCycleRegistrationStatus
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
    }

    public func show(tab: SettingsTab = .settings) {
        presentationCoordinator.present(.settings)
        let window = window ?? makeWindow()
        self.window = window
        selectedTab = tab
        segmentedControl?.selectedSegment = tab.rawValue
        displaySelectedTab()
        refresh()
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    public func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === window else {
            return
        }
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
        finderExtensionSwitch?.state = settings.finderExtensionEnabled ? .on : .off
        finderLaunchShortcutsGroupedSwitch?.state = settings.finderLaunchShortcutsGrouped ? .on : .off
        refreshFinderExtensionSetupVisibility()
        refreshHotkeyGuidanceVisibility()

        let snapshot = permissionService.snapshot()
        for kind in PermissionKind.allCases {
            for view in permissionViews[kind] ?? [] {
                view.update(isGranted: permissionService.isGranted(kind, in: snapshot))
            }
        }

        reloadHotkeyRows()
        reloadFinderLaunchShortcuts()
        reloadFinderDocumentPresets()
        applicationPicker?.refreshLocalization()
    }

    @objc private func changeTab(_ sender: NSSegmentedControl) {
        selectedTab = SettingsTab(rawValue: sender.selectedSegment) ?? .settings
        displaySelectedTab()
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

    @objc private func toggleFinderExtension(_ sender: NSSwitch) {
        if sender.state == .on {
            guard canEnable(.finderExtension, sender: sender) else {
                return
            }
            settings.finderExtensionEnabled = true
        } else {
            settings.finderExtensionEnabled = false
        }
        refreshFinderExtensionSetupVisibility()
    }

    @objc private func toggleFinderLaunchShortcutGrouping(_ sender: NSSwitch) {
        settings.finderLaunchShortcutsGrouped = sender.state == .on
    }

    @objc private func openFinderExtensionManagement(_ sender: NSButton) {
        FinderExtensionActivation.showManagementInterface()
    }

    @objc private func commitLivePreviewLimit(_ sender: NSTextField) {
        settings.livePreviewWindowLimit = sender.integerValue
        refreshLivePreviewLimitControls()
    }

    @objc private func stepLivePreviewLimit(_ sender: NSStepper) {
        settings.livePreviewWindowLimit = Int(sender.doubleValue.rounded())
        refreshLivePreviewLimitControls()
    }

    public func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField,
              field === livePreviewLimitField
        else {
            return
        }
        settings.livePreviewWindowLimit = field.integerValue
        refreshLivePreviewLimitControls()
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

    @objc private func addFinderLaunchShortcut(_ sender: NSButton) {
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

    @objc private func removeFinderLaunchShortcut(_ sender: NSButton) {
        guard let rawValue = sender.identifier?.rawValue,
              let id = UUID(uuidString: rawValue)
        else {
            return
        }
        settings.deleteFinderLaunchShortcut(id: id)
    }

    @objc private func addFinderDocumentPreset(_ sender: NSButton) {
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

    @objc private func removeFinderDocumentPreset(_ sender: NSButton) {
        guard let rawValue = sender.identifier?.rawValue,
              let id = UUID(uuidString: rawValue)
        else {
            return
        }
        settings.deleteFinderDocumentPreset(id: id)
    }

    @objc private func openPermissionOnboarding(_ sender: NSButton) {
        onOpenPermissionOnboarding()
    }

    @objc private func settingsChanged() {
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

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 560, height: 550),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "OmniDock"
        window.delegate = self
        window.hidesOnDeactivate = false
        window.level = .normal
        window.isReleasedWhenClosed = false
        window.contentView = makeContentView()
        applyTheme(to: window)
        return window
    }

    private func rebuildContentView(in window: NSWindow) {
        permissionViews.removeAll()
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
        finderExtensionSwitch = nil
        finderExtensionSetupView = nil
        finderLaunchShortcutsGroupedSwitch = nil
        finderLaunchShortcutsStack = nil
        finderDocumentPresetsStack = nil
        hotkeyGuidanceField = nil
        hotkeyHeaderHeightConstraint = nil
        hotkeyRowsStack = nil
        window.contentView = makeContentView()
    }

    private func makeContentView() -> NSView {
        renderedLanguage = AppLocalization.currentResolvedLanguage
        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = OmniDockTheme.palette().canvas.cgColor

        let segmentedControl = NSSegmentedControl(
            labels: [
                AppStrings.text(.tabSettings),
                AppStrings.text(.tabPreview),
                AppStrings.text(.tabHotkeys),
                AppStrings.text(.tabFinderExtension)
            ],
            trackingMode: .selectOne,
            target: self,
            action: #selector(changeTab(_:))
        )
        segmentedControl.selectedSegment = selectedTab.rawValue
        segmentedControl.translatesAutoresizingMaskIntoConstraints = false
        self.segmentedControl = segmentedControl
        content.addSubview(segmentedControl)

        let contentContainer = NSView()
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        self.contentContainer = contentContainer
        content.addSubview(contentContainer)

        let generalContentView = makeScrollableTab(makeGeneralTab())
        let previewContentView = makeScrollableTab(makePreviewTab())
        let hotkeysContentView = makeHotkeysTab()
        let finderExtensionContentView = makeScrollableTab(makeFinderExtensionTab())
        self.generalContentView = generalContentView
        self.previewContentView = previewContentView
        self.hotkeysContentView = hotkeysContentView
        self.finderExtensionContentView = finderExtensionContentView
        embed(generalContentView, in: contentContainer)
        embed(previewContentView, in: contentContainer)
        embed(hotkeysContentView, in: contentContainer)
        embed(finderExtensionContentView, in: contentContainer)
        displaySelectedTab()

        NSLayoutConstraint.activate([
            segmentedControl.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            segmentedControl.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            segmentedControl.widthAnchor.constraint(equalToConstant: 448),

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
        stack.spacing = 12

        stack.addArrangedSubview(makeSettingRow(
            title: AppStrings.text(.languageTitle),
            detail: AppStrings.text(.languageDetail),
            control: makeLanguageControl()
        ))

        stack.addArrangedSubview(makeSettingRow(
            title: AppStrings.text(.appearanceTitle),
            detail: AppStrings.text(.appearanceDetail),
            control: makeAppearanceControl()
        ))

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

        for kind in [PermissionKind.accessibility, .screenRecording, .inputMonitoring] {
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
        stack.addArrangedSubview(permissions)

        NSLayoutConstraint.activate([
            toggles.widthAnchor.constraint(equalTo: stack.widthAnchor),
            permissions.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])

        return stack
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

        let guidanceField = NSTextField(labelWithString: HotkeyGuidancePresentation.message)
        guidanceField.font = .systemFont(ofSize: 12)
        guidanceField.textColor = .secondaryLabelColor
        guidanceField.lineBreakMode = .byWordWrapping
        guidanceField.maximumNumberOfLines = 2
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
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let rowsStack = NSStackView()
        rowsStack.orientation = .vertical
        rowsStack.alignment = .width
        rowsStack.spacing = 10
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
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

            scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scrollView.heightAnchor.constraint(equalToConstant: 250),
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

    private func makeFinderExtensionTab() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18

        let enabledSwitch = NSSwitch()
        enabledSwitch.target = self
        enabledSwitch.action = #selector(toggleFinderExtension(_:))
        finderExtensionSwitch = enabledSwitch
        stack.addArrangedSubview(makeSettingRow(
            title: AppStrings.text(.finderExtensionEnableTitle),
            detail: AppStrings.text(.finderExtensionEnableDetail),
            control: enabledSwitch
        ))

        let setupView = NSStackView()
        setupView.orientation = .horizontal
        setupView.alignment = .centerY
        setupView.spacing = 12
        setupView.translatesAutoresizingMaskIntoConstraints = false

        let setupHint = NSTextField(wrappingLabelWithString: AppStrings.text(.finderExtensionSetupRequired))
        setupHint.font = .systemFont(ofSize: 12)
        setupHint.textColor = .secondaryLabelColor
        setupHint.maximumNumberOfLines = 2

        let setupButton = NSButton(
            title: AppStrings.text(.finderExtensionOpenSettings),
            target: self,
            action: #selector(openFinderExtensionManagement(_:))
        )
        setupButton.bezelStyle = .rounded

        setupView.addArrangedSubview(setupHint)
        setupView.addArrangedSubview(setupButton)
        setupHint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setupButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        stack.addArrangedSubview(setupView)
        setupView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        finderExtensionSetupView = setupView

        let permissions = makeFinderPermissionSection()
        stack.addArrangedSubview(permissions)

        let groupingSwitch = NSSwitch()
        groupingSwitch.target = self
        groupingSwitch.action = #selector(toggleFinderLaunchShortcutGrouping(_:))
        finderLaunchShortcutsGroupedSwitch = groupingSwitch
        stack.addArrangedSubview(makeSettingRow(
            title: AppStrings.text(.finderQuickOpenGroupedTitle),
            detail: AppStrings.text(.finderQuickOpenGroupedDetail),
            control: groupingSwitch
        ))

        let launchShortcuts = makeFinderCollectionSection(
            title: AppStrings.text(.finderQuickOpenTitle),
            detail: AppStrings.text(.finderQuickOpenDetail),
            buttonTitle: AppStrings.text(.finderQuickOpenAdd),
            action: #selector(addFinderLaunchShortcut(_:))
        )
        finderLaunchShortcutsStack = launchShortcuts.rows
        stack.addArrangedSubview(launchShortcuts.view)

        let documentPresets = makeFinderCollectionSection(
            title: AppStrings.text(.finderDocumentTypesTitle),
            detail: AppStrings.text(.finderDocumentTypesDetail),
            buttonTitle: AppStrings.text(.finderDocumentTypeAdd),
            action: #selector(addFinderDocumentPreset(_:))
        )
        finderDocumentPresetsStack = documentPresets.rows
        stack.addArrangedSubview(documentPresets.view)

        for view in stack.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        return stack
    }

    private func makeFinderPermissionSection() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8

        let title = NSTextField(labelWithString: AppStrings.text(.finderPermissionStatus))
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .secondaryLabelColor
        stack.addArrangedSubview(title)

        for kind in [PermissionKind.finderExtension, .folderAccess, .accessibility] {
            let view = PermissionStatusView(kind: kind)
            view.onRequestPermission = { [weak self] kind in
                self?.openPermissionSettings(kind)
            }
            permissionViews[kind, default: []].append(view)
            stack.addArrangedSubview(view)
        }
        return stack
    }

    private func makeFinderCollectionSection(
        title: String,
        detail: String,
        buttonTitle: String,
        action: Selector
    ) -> (view: NSView, rows: NSStackView) {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 8

        let button = NSButton(title: buttonTitle, target: self, action: action)
        button.bezelStyle = .rounded
        container.addArrangedSubview(makeSettingRow(
            title: title,
            detail: detail,
            control: button
        ))

        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 6
        container.addArrangedSubview(rows)
        rows.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
        return (container, rows)
    }

    private func refreshFinderExtensionSetupVisibility() {
        finderExtensionSetupView?.isHidden = !FinderExtensionActivation.requiresManualActivation(
            isFeatureEnabled: settings.finderExtensionEnabled,
            isExtensionEnabledInFinder: FinderExtensionActivation.isEnabledInFinder
        )
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

        let detailField = NSTextField(labelWithString: detail)
        detailField.font = .systemFont(ofSize: 12)
        detailField.textColor = .secondaryLabelColor
        detailField.lineBreakMode = .byWordWrapping

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
        generalContentView?.isHidden = selectedTab != .settings
        previewContentView?.isHidden = selectedTab != .preview
        hotkeysContentView?.isHidden = selectedTab != .hotkeys
        finderExtensionContentView?.isHidden = selectedTab != .finderExtension
    }

    private func reloadHotkeyRows() {
        guard let hotkeyRowsStack else {
            return
        }
        hotkeyRowsStack.removeAllArrangedSubviews()

        let bindings = settings.appHotkeyBindings
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

        if let reason = ShortcutRecorderValidation.rejectionReason(
            for: shortcut,
            existingBindings: settings.appHotkeyBindings,
            excluding: binding.id
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
            ?? binding.recordedShortcut.flatMap { ShortcutRecorderValidation.rejectionReason(for: $0) }
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

    private func reloadFinderLaunchShortcuts() {
        guard let stack = finderLaunchShortcutsStack else {
            return
        }
        stack.removeAllArrangedSubviews()

        let shortcuts = settings.finderLaunchShortcuts
        guard !shortcuts.isEmpty else {
            stack.addArrangedSubview(makeFinderEmptyLabel(
                AppStrings.text(.finderQuickOpenEmpty)
            ))
            return
        }

        for shortcut in shortcuts {
            stack.addArrangedSubview(makeFinderListRow(
                title: shortcut.displayName,
                detail: shortcut.bundleIdentifier ?? shortcut.bundleURL?.path ?? "",
                id: shortcut.id,
                action: #selector(removeFinderLaunchShortcut(_:)),
                icon: shortcut.bundleURL.map {
                    NSWorkspace.shared.icon(forFile: $0.path)
                }
            ))
        }
    }

    private func reloadFinderDocumentPresets() {
        guard let stack = finderDocumentPresetsStack else {
            return
        }
        stack.removeAllArrangedSubviews()
        for preset in settings.finderDocumentPresets {
            stack.addArrangedSubview(makeFinderListRow(
                title: preset.displayName,
                detail: ".\(preset.fileExtension)",
                id: preset.id,
                action: #selector(removeFinderDocumentPreset(_:))
            ))
        }
    }

    private func makeFinderEmptyLabel(_ value: String) -> NSTextField {
        let label = NSTextField(labelWithString: value)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func makeFinderListRow(
        title: String,
        detail: String,
        id: UUID,
        action: Selector,
        icon: NSImage? = nil
    ) -> NSView {
        let row = NSView()
        let labels = NSStackView()
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2

        let titleField = NSTextField(labelWithString: title)
        titleField.font = .systemFont(ofSize: 13, weight: .medium)
        let detailField = NSTextField(labelWithString: detail)
        detailField.font = .systemFont(ofSize: 11)
        detailField.textColor = .secondaryLabelColor
        labels.addArrangedSubview(titleField)
        labels.addArrangedSubview(detailField)

        let removeButton = NSButton(
            title: AppStrings.text(.finderRemove),
            target: self,
            action: action
        )
        removeButton.bezelStyle = .rounded
        removeButton.identifier = NSUserInterfaceItemIdentifier(id.uuidString)

        row.addSubview(labels)
        row.addSubview(removeButton)
        labels.translatesAutoresizingMaskIntoConstraints = false
        removeButton.translatesAutoresizingMaskIntoConstraints = false

        var leadingAnchor = row.leadingAnchor
        if let icon {
            icon.size = CGSize(width: 28, height: 28)
            let iconView = NSImageView(image: icon)
            iconView.imageScaling = .scaleProportionallyUpOrDown
            iconView.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(iconView)
            NSLayoutConstraint.activate([
                iconView.leadingAnchor.constraint(equalTo: row.leadingAnchor),
                iconView.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                iconView.widthAnchor.constraint(equalToConstant: 28),
                iconView.heightAnchor.constraint(equalToConstant: 28)
            ])
            leadingAnchor = iconView.trailingAnchor
        }

        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 40),
            labels.leadingAnchor.constraint(equalTo: leadingAnchor, constant: icon == nil ? 0 : 10),
            labels.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: removeButton.leadingAnchor, constant: -12),
            removeButton.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            removeButton.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            row.widthAnchor.constraint(greaterThanOrEqualToConstant: 360)
        ])
        return row
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
