import AppKit

public enum SettingsTab: Int {
    case settings = 0
    case hotkeys = 1
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
    private let presentationCoordinator: ApplicationPresentationCoordinator
    private let onPermissionGateRequired: (PermissionFeature) -> Void
    private let onOpenPermissionOnboarding: () -> Void

    private var window: NSWindow?
    private var segmentedControl: NSSegmentedControl?
    private var contentContainer: NSView?
    private var settingsContentView: NSView?
    private var hotkeysContentView: NSView?
    private var languagePopupButton: NSPopUpButton?
    private var previewSwitch: NSSwitch?
    private var commandTabPreviewSwitch: NSSwitch?
    private var livePreviewSwitch: NSSwitch?
    private var livePreviewLimitField: NSTextField?
    private var livePreviewLimitStepper: NSStepper?
    private var livePreviewLimitRangeField: NSTextField?
    private var dockClickSwitch: NSSwitch?
    private var minimizeDockClickSwitch: NSSwitch?
    private var hotkeysEnabledSwitch: NSSwitch?
    private var hotkeyGuidanceField: NSTextField?
    private var hotkeyHeaderHeightConstraint: NSLayoutConstraint?
    private var permissionViews: [PermissionKind: PermissionStatusView] = [:]
    private var hotkeyRowsStack: NSStackView?
    private var hotkeyWarnings: [UUID: String] = [:]
    private var applicationPicker: ApplicationPickerWindowController?
    private var applicationPickerGeneration: UInt = 0
    private var selectedTab: SettingsTab = .settings
    private var renderedLanguage: AppLanguage.Resolved?

    public convenience init(
        settings: SettingsStore,
        permissionService: PermissionService,
        coordinator: DockInteractionCoordinator,
        hotkeyRegistrationStatus: AppHotkeyRegistrationStatusStore,
        onPermissionGateRequired: @escaping (PermissionFeature) -> Void,
        onOpenPermissionOnboarding: @escaping () -> Void = {}
    ) {
        self.init(
            settings: settings,
            permissionService: permissionService,
            coordinator: coordinator,
            hotkeyRegistrationStatus: hotkeyRegistrationStatus,
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
        presentationCoordinator: ApplicationPresentationCoordinator,
        onPermissionGateRequired: @escaping (PermissionFeature) -> Void,
        onOpenPermissionOnboarding: @escaping () -> Void
    ) {
        self.settings = settings
        self.permissionService = permissionService
        self.coordinator = coordinator
        self.hotkeyRegistrationStatus = hotkeyRegistrationStatus
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
        if let window,
           renderedLanguage != AppLocalization.currentResolvedLanguage {
            hotkeyWarnings.removeAll()
            rebuildContentView(in: window)
        }
        refreshLanguageControl()
        previewSwitch?.state = settings.showDockPreviews ? .on : .off
        commandTabPreviewSwitch?.state = settings.showCommandTabPreviews ? .on : .off
        commandTabPreviewSwitch?.isEnabled = settings.showDockPreviews
        livePreviewSwitch?.state = settings.liveDockPreviewsEnabled ? .on : .off
        livePreviewSwitch?.isEnabled = settings.showDockPreviews
        refreshLivePreviewLimitControls()
        dockClickSwitch?.state = settings.toggleAppVisibilityOnDockClick ? .on : .off
        minimizeDockClickSwitch?.state = settings.minimizeWindowsOnDockClickInsteadOfHide ? .on : .off
        minimizeDockClickSwitch?.isEnabled = settings.toggleAppVisibilityOnDockClick
        hotkeysEnabledSwitch?.state = settings.hotkeysEnabled ? .on : .off
        refreshHotkeyGuidanceVisibility()

        let snapshot = permissionService.snapshot()
        for kind in PermissionKind.allCases {
            permissionViews[kind]?.update(
                isGranted: permissionService.isGranted(kind, in: snapshot)
            )
        }

        reloadHotkeyRows()
        applicationPicker?.refreshLocalization()
    }

    @objc private func changeTab(_ sender: NSSegmentedControl) {
        selectedTab = SettingsTab(rawValue: sender.selectedSegment) ?? .settings
        displaySelectedTab()
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
        }
        livePreviewSwitch?.isEnabled = settings.showDockPreviews
        commandTabPreviewSwitch?.isEnabled = settings.showDockPreviews
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

    @objc private func openPermissionOnboarding(_ sender: NSButton) {
        onOpenPermissionOnboarding()
    }

    @objc private func settingsChanged() {
        refresh()
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
        return window
    }

    private func rebuildContentView(in window: NSWindow) {
        permissionViews.removeAll()
        languagePopupButton = nil
        previewSwitch = nil
        commandTabPreviewSwitch = nil
        livePreviewSwitch = nil
        livePreviewLimitField = nil
        livePreviewLimitStepper = nil
        livePreviewLimitRangeField = nil
        dockClickSwitch = nil
        minimizeDockClickSwitch = nil
        hotkeysEnabledSwitch = nil
        hotkeyGuidanceField = nil
        hotkeyHeaderHeightConstraint = nil
        hotkeyRowsStack = nil
        window.contentView = makeContentView()
    }

    private func makeContentView() -> NSView {
        renderedLanguage = AppLocalization.currentResolvedLanguage
        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let segmentedControl = NSSegmentedControl(
            labels: [AppStrings.text(.tabSettings), AppStrings.text(.tabHotkeys)],
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

        let settingsContentView = makeSettingsTab()
        let hotkeysContentView = makeHotkeysTab()
        self.settingsContentView = settingsContentView
        self.hotkeysContentView = hotkeysContentView
        embed(settingsContentView, in: contentContainer)
        embed(hotkeysContentView, in: contentContainer)
        displaySelectedTab()

        NSLayoutConstraint.activate([
            segmentedControl.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            segmentedControl.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            segmentedControl.widthAnchor.constraint(equalToConstant: 220),

            contentContainer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            contentContainer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            contentContainer.topAnchor.constraint(equalTo: segmentedControl.bottomAnchor, constant: 18),
            contentContainer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24)
        ])

        return content
    }

    private func makeSettingsTab() -> NSView {
        let root = NSView()

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        let toggles = NSStackView()
        toggles.orientation = .vertical
        toggles.alignment = .leading
        toggles.spacing = 12
        stack.addArrangedSubview(toggles)

        toggles.addArrangedSubview(makeSettingRow(
            title: AppStrings.text(.languageTitle),
            detail: AppStrings.text(.languageDetail),
            control: makeLanguageControl()
        ))

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

        for kind in PermissionKind.allCases {
            let view = PermissionStatusView(kind: kind)
            view.onRequestPermission = { [weak self] kind in
                self?.openPermissionSettings(kind)
            }
            permissionViews[kind] = view
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
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),

            toggles.widthAnchor.constraint(equalTo: stack.widthAnchor),
            permissions.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])

        return root
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
            rowsStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            rowsStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            rowsStack.topAnchor.constraint(equalTo: documentView.topAnchor),
            rowsStack.bottomAnchor.constraint(lessThanOrEqualTo: documentView.bottomAnchor)
        ])

        refreshHotkeyGuidanceVisibility()
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

    private func displaySelectedTab() {
        settingsContentView?.isHidden = selectedTab != .settings
        hotkeysContentView?.isHidden = selectedTab != .hotkeys
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
