import AppKit
import UniformTypeIdentifiers

enum FinderExtensionSettingsSection: CaseIterable {
    case documentTypes
    case quickActions

    var title: String {
        switch self {
        case .documentTypes:
            AppStrings.text(.finderDocumentTypesTitle)
        case .quickActions:
            AppStrings.text(.finderQuickOpenTitle)
        }
    }

    var detail: String {
        switch self {
        case .documentTypes:
            AppStrings.text(.finderDocumentTypesDetail)
        case .quickActions:
            AppStrings.text(.finderQuickOpenDetail)
        }
    }

    var symbolName: String {
        switch self {
        case .documentTypes:
            "doc.badge.plus"
        case .quickActions:
            "bolt"
        }
    }
}

@MainActor
final class FinderExtensionSettingsView: NSView {
    var onEnableRequest: ((NSSwitch) -> Bool)?
    var onOpenExtensionManagement: (() -> Void)?
    var onAddQuickAction: (() -> Void)?
    var onRemoveQuickAction: ((UUID) -> Void)?
    var onAddDocumentType: (() -> Void)?
    var onRemoveDocumentType: ((UUID) -> Void)?

    private(set) var selectedSection: FinderExtensionSettingsSection = .documentTypes

    private let settings: SettingsStore
    // Injectable because the default implementation queries Finder over XPC,
    // which unit tests must not depend on.
    private let isExtensionEnabledInFinder: () -> Bool
    private let masterSwitch = FinderSettingsSwitch()
    private let groupingSwitch = FinderSettingsSwitch()
    private let setupView = NSStackView()
    private let navigationStack = NSStackView()
    private let detailStack = NSStackView()
    private let detailTitle = NSTextField(labelWithString: "")
    private let detailDescription = NSTextField(wrappingLabelWithString: "")
    private let addButton = FinderSettingsButton()
    private let itemRows = NSStackView()
    private var sectionButtons: [FinderExtensionSettingsSection: FinderSettingsSectionButton] = [:]

    init(
        settings: SettingsStore,
        isExtensionEnabledInFinder: @escaping () -> Bool = {
            FinderExtensionActivation.isEnabledInFinder
        }
    ) {
        self.settings = settings
        self.isExtensionEnabledInFinder = isExtensionEnabledInFinder
        super.init(frame: .zero)
        build()
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func reload() {
        masterSwitch.state = settings.finderExtensionEnabled ? .on : .off
        groupingSwitch.state = settings.finderLaunchShortcutsGrouped ? .on : .off
        setupView.isHidden = !FinderExtensionActivation.requiresManualActivation(
            isFeatureEnabled: settings.finderExtensionEnabled,
            isExtensionEnabledInFinder: isExtensionEnabledInFinder()
        )
        updateSectionSelection()
        rebuildDetail()
    }

    func selectSection(_ section: FinderExtensionSettingsSection) {
        guard selectedSection != section else {
            return
        }
        selectedSection = section
        updateSectionSelection()
        rebuildDetail()
    }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false

        let header = NSStackView()
        header.orientation = .vertical
        header.alignment = .width
        header.spacing = 8
        header.setContentHuggingPriority(.required, for: .vertical)
        header.setContentCompressionResistancePriority(.required, for: .vertical)
        header.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)

        masterSwitch.target = self
        masterSwitch.action = #selector(toggleExtension(_:))
        header.addArrangedSubview(makeSettingRow(
            title: AppStrings.text(.finderExtensionEnableTitle),
            detail: AppStrings.text(.finderExtensionEnableDetail),
            control: masterSwitch
        ))
        configureSetupView()
        header.addArrangedSubview(setupView)

        let split = makeSplitView()
        split.translatesAutoresizingMaskIntoConstraints = false
        addSubview(split)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.topAnchor.constraint(equalTo: topAnchor),

            split.leadingAnchor.constraint(equalTo: leadingAnchor),
            split.trailingAnchor.constraint(equalTo: trailingAnchor),
            split.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 16),
            split.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    private func configureSetupView() {
        setupView.orientation = .horizontal
        setupView.alignment = .centerY
        setupView.spacing = 12

        let hint = NSTextField(
            wrappingLabelWithString: AppStrings.text(.finderExtensionSetupRequired)
        )
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        hint.maximumNumberOfLines = 2
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let button = FinderSettingsButton()
        button.title = AppStrings.text(.finderExtensionOpenSettings)
        button.target = self
        button.action = #selector(openExtensionManagement(_:))
        button.bezelStyle = .rounded
        button.setContentCompressionResistancePriority(.required, for: .horizontal)

        setupView.addArrangedSubview(hint)
        setupView.addArrangedSubview(button)
        setupView.heightAnchor.constraint(greaterThanOrEqualToConstant: 34).isActive = true
    }

    private func makeSplitView() -> NSView {
        let split = NSView()

        let navigation = makeNavigationColumn()
        let editor = makeDetailColumn()
        navigation.translatesAutoresizingMaskIntoConstraints = false
        editor.translatesAutoresizingMaskIntoConstraints = false
        split.addSubview(navigation)
        split.addSubview(editor)

        NSLayoutConstraint.activate([
            navigation.leadingAnchor.constraint(equalTo: split.leadingAnchor),
            navigation.topAnchor.constraint(equalTo: split.topAnchor),
            navigation.bottomAnchor.constraint(lessThanOrEqualTo: split.bottomAnchor),
            navigation.widthAnchor.constraint(equalToConstant: 200),

            editor.leadingAnchor.constraint(equalTo: navigation.trailingAnchor, constant: 16),
            editor.topAnchor.constraint(equalTo: split.topAnchor),
            editor.trailingAnchor.constraint(equalTo: split.trailingAnchor),
            editor.bottomAnchor.constraint(equalTo: split.bottomAnchor),
            editor.widthAnchor.constraint(greaterThanOrEqualToConstant: 360)
        ])
        return split
    }

    private func makeNavigationColumn() -> NSView {
        let container = NSView()

        navigationStack.orientation = .vertical
        navigationStack.alignment = .leading
        navigationStack.distribution = .fill
        navigationStack.spacing = 8
        navigationStack.translatesAutoresizingMaskIntoConstraints = false
        navigationStack.setContentHuggingPriority(.required, for: .vertical)
        navigationStack.setContentCompressionResistancePriority(.required, for: .vertical)
        container.addSubview(navigationStack)

        for section in FinderExtensionSettingsSection.allCases {
            let button = FinderSettingsSectionButton(section: section)
            button.target = self
            button.action = #selector(selectSectionButton(_:))
            button.setContentHuggingPriority(.defaultLow, for: .horizontal)
            button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            sectionButtons[section] = button
            navigationStack.addArrangedSubview(button)
            button.widthAnchor.constraint(equalTo: navigationStack.widthAnchor).isActive = true
        }

        NSLayoutConstraint.activate([
            navigationStack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            navigationStack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            navigationStack.topAnchor.constraint(equalTo: container.topAnchor),
            navigationStack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor)
        ])
        return container
    }

    private func makeDetailColumn() -> NSView {
        detailStack.orientation = .vertical
        detailStack.alignment = .width
        detailStack.spacing = 10

        let header = makeDetailHeader()
        detailStack.addArrangedSubview(header)
        header.heightAnchor.constraint(equalToConstant: 58).isActive = true

        groupingSwitch.target = self
        groupingSwitch.action = #selector(toggleGrouping(_:))
        let groupingRow = makeSettingRow(
            title: AppStrings.text(.finderQuickOpenGroupedTitle),
            detail: AppStrings.text(.finderQuickOpenGroupedDetail),
            control: groupingSwitch
        )
        detailStack.addArrangedSubview(groupingRow)

        let scrollView = makeItemList()
        detailStack.addArrangedSubview(scrollView)
        scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        scrollView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        return detailStack
    }

    private func makeDetailHeader() -> NSView {
        let header = NSView()
        detailTitle.font = .systemFont(ofSize: 16, weight: .semibold)
        detailTitle.translatesAutoresizingMaskIntoConstraints = false
        detailDescription.font = .systemFont(ofSize: 12)
        detailDescription.textColor = .secondaryLabelColor
        detailDescription.maximumNumberOfLines = 2
        detailDescription.translatesAutoresizingMaskIntoConstraints = false
        addButton.target = self
        addButton.action = #selector(addItem(_:))
        addButton.bezelStyle = .rounded
        addButton.translatesAutoresizingMaskIntoConstraints = false

        header.addSubview(detailTitle)
        header.addSubview(detailDescription)
        header.addSubview(addButton)
        NSLayoutConstraint.activate([
            detailTitle.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            detailTitle.topAnchor.constraint(equalTo: header.topAnchor),
            detailTitle.trailingAnchor.constraint(lessThanOrEqualTo: addButton.leadingAnchor, constant: -12),
            detailDescription.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            detailDescription.trailingAnchor.constraint(lessThanOrEqualTo: addButton.leadingAnchor, constant: -12),
            detailDescription.topAnchor.constraint(equalTo: detailTitle.bottomAnchor, constant: 3),
            addButton.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            addButton.centerYAnchor.constraint(equalTo: header.centerYAnchor)
        ])
        return header
    }

    private func makeItemList() -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        let documentView = TopAnchoredDocumentView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        itemRows.orientation = .vertical
        itemRows.alignment = .width
        itemRows.spacing = 8
        itemRows.translatesAutoresizingMaskIntoConstraints = false
        itemRows.setContentHuggingPriority(.required, for: .vertical)
        documentView.addSubview(itemRows)
        scrollView.documentView = documentView

        let contentBottom = itemRows.bottomAnchor.constraint(equalTo: documentView.bottomAnchor)
        contentBottom.priority = .defaultHigh

        NSLayoutConstraint.activate([
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            documentView.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.heightAnchor),
            itemRows.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            itemRows.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            itemRows.topAnchor.constraint(equalTo: documentView.topAnchor),
            itemRows.bottomAnchor.constraint(lessThanOrEqualTo: documentView.bottomAnchor),
            contentBottom
        ])
        return scrollView
    }

    private func rebuildDetail() {
        detailTitle.stringValue = selectedSection.title
        detailDescription.stringValue = selectedSection.detail
        addButton.title = selectedSection == .documentTypes
            ? AppStrings.text(.finderDocumentTypeAdd)
            : AppStrings.text(.finderQuickOpenAdd)
        detailStack.arrangedSubviews[1].isHidden = selectedSection != .quickActions

        itemRows.removeAllArrangedSubviews()
        switch selectedSection {
        case .documentTypes:
            itemRows.addArrangedSubview(makeDocumentTypeHeader())
            for preset in settings.finderDocumentPresets {
                itemRows.addArrangedSubview(makeDocumentTypeRow(preset))
            }
        case .quickActions:
            rebuildQuickActions()
        }
    }

    private func makeDocumentTypeHeader() -> NSView {
        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.heightAnchor.constraint(equalToConstant: 24).isActive = true

        let enabled = makeColumnHeader(AppStrings.text(.finderDocumentTypeEnabled))
        let name = makeColumnHeader(AppStrings.text(.finderDocumentTypeName))
        let suffix = makeColumnHeader(AppStrings.text(.finderDocumentTypeExtension))
        for view in [enabled, name, suffix] {
            view.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(view)
        }

        NSLayoutConstraint.activate([
            enabled.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 12),
            enabled.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            enabled.widthAnchor.constraint(equalToConstant: 48),

            name.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 78),
            name.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            suffix.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -84),
            suffix.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            suffix.widthAnchor.constraint(equalToConstant: 82)
        ])
        return header
    }

    private func makeColumnHeader(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 10, weight: .medium)
        label.textColor = .tertiaryLabelColor
        return label
    }

    private func makeDocumentTypeRow(_ preset: FinderDocumentPreset) -> NSView {
        let row = FinderSettingsSurfaceView(style: .item)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: 50).isActive = true

        let enabled = NSButton(
            checkboxWithTitle: "",
            target: self,
            action: #selector(toggleDocumentType(_:))
        )
        enabled.state = preset.isEnabled ? .on : .off
        enabled.identifier = NSUserInterfaceItemIdentifier(preset.id.uuidString)
        enabled.setAccessibilityLabel(
            "\(AppStrings.text(.finderDocumentTypeEnabled)): \(preset.displayName)"
        )
        enabled.translatesAutoresizingMaskIntoConstraints = false

        let iconView = NSImageView()
        if let contentType = UTType(filenameExtension: preset.fileExtension) {
            iconView.image = NSWorkspace.shared.icon(for: contentType)
        } else {
            iconView.image = NSImage(
                systemSymbolName: "doc",
                accessibilityDescription: preset.displayName
            )
        }
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let name = NSTextField(labelWithString: preset.displayName)
        name.font = .systemFont(ofSize: 13, weight: .medium)
        name.lineBreakMode = .byTruncatingTail
        name.translatesAutoresizingMaskIntoConstraints = false

        let suffix = NSTextField(labelWithString: preset.fileExtension)
        suffix.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        suffix.textColor = .secondaryLabelColor
        suffix.alignment = .left
        suffix.translatesAutoresizingMaskIntoConstraints = false

        row.addSubview(enabled)
        row.addSubview(iconView)
        row.addSubview(name)
        row.addSubview(suffix)

        var trailingAnchor = row.trailingAnchor
        var trailingConstant: CGFloat = -84
        if !preset.isBuiltIn {
            let removeButton = FinderSettingsButton()
            removeButton.title = AppStrings.text(.finderRemove)
            removeButton.bezelStyle = .rounded
            removeButton.identifier = NSUserInterfaceItemIdentifier(preset.id.uuidString)
            removeButton.target = self
            removeButton.action = #selector(removeItem(_:))
            removeButton.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(removeButton)
            NSLayoutConstraint.activate([
                removeButton.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -12),
                removeButton.centerYAnchor.constraint(equalTo: row.centerYAnchor)
            ])
            trailingAnchor = removeButton.leadingAnchor
            trailingConstant = -12
        }

        NSLayoutConstraint.activate([
            enabled.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 12),
            enabled.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            enabled.widthAnchor.constraint(equalToConstant: 18),

            iconView.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 42),
            iconView.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 26),
            iconView.heightAnchor.constraint(equalToConstant: 26),

            name.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 78),
            name.centerYAnchor.constraint(equalTo: row.centerYAnchor),

            suffix.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 12),
            suffix.trailingAnchor.constraint(equalTo: trailingAnchor, constant: trailingConstant),
            suffix.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            suffix.widthAnchor.constraint(equalToConstant: 82)
        ])
        return row
    }

    private func rebuildQuickActions() {
        let actions = settings.finderLaunchShortcuts
        guard !actions.isEmpty else {
            let empty = NSTextField(labelWithString: AppStrings.text(.finderQuickOpenEmpty))
            empty.font = .systemFont(ofSize: 12)
            empty.textColor = .secondaryLabelColor
            itemRows.addArrangedSubview(empty)
            return
        }

        itemRows.addArrangedSubview(makeQuickActionHeader())
        for action in actions {
            itemRows.addArrangedSubview(makeQuickActionRow(action))
        }
    }

    private func makeQuickActionHeader() -> NSView {
        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.heightAnchor.constraint(equalToConstant: 24).isActive = true

        let enabled = makeColumnHeader(AppStrings.text(.finderQuickOpenEnabled))
        let application = makeColumnHeader(AppStrings.text(.finderQuickOpenApplication))
        let status = makeColumnHeader(AppStrings.text(.finderQuickOpenStatus))
        for view in [enabled, application, status] {
            view.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(view)
        }

        NSLayoutConstraint.activate([
            enabled.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 12),
            enabled.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            enabled.widthAnchor.constraint(equalToConstant: 48),

            application.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 78),
            application.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            status.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -84),
            status.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            status.widthAnchor.constraint(equalToConstant: 104)
        ])
        return header
    }

    private func makeQuickActionRow(_ shortcut: FinderLaunchShortcut) -> NSView {
        let row = FinderSettingsSurfaceView(style: .item)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: 50).isActive = true

        let applicationURL = resolvedApplicationURL(for: shortcut)
        let isAvailable = applicationURL != nil
        let enabled = NSButton(
            checkboxWithTitle: "",
            target: self,
            action: #selector(toggleQuickAction(_:))
        )
        enabled.state = shortcut.isEnabled ? .on : .off
        enabled.isEnabled = isAvailable || shortcut.isEnabled
        enabled.identifier = NSUserInterfaceItemIdentifier(shortcut.id.uuidString)
        enabled.setAccessibilityLabel(
            "\(AppStrings.text(.finderQuickOpenEnabled)): \(shortcut.displayName)"
        )
        enabled.translatesAutoresizingMaskIntoConstraints = false

        let iconView = NSImageView()
        iconView.image = applicationURL.map {
            NSWorkspace.shared.icon(forFile: $0.path)
        } ?? NSImage(named: NSImage.applicationIconName)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.alphaValue = isAvailable ? 1 : 0.45
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let name = NSTextField(labelWithString: shortcut.displayName)
        name.font = .systemFont(ofSize: 13, weight: .medium)
        name.textColor = isAvailable ? .labelColor : .secondaryLabelColor
        name.lineBreakMode = .byTruncatingTail
        name.translatesAutoresizingMaskIntoConstraints = false

        let status = NSTextField(labelWithString: AppStrings.text(
            isAvailable ? .finderQuickOpenInstalled : .finderQuickOpenNotInstalled
        ))
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.alignment = .left
        status.translatesAutoresizingMaskIntoConstraints = false

        row.addSubview(enabled)
        row.addSubview(iconView)
        row.addSubview(name)
        row.addSubview(status)

        var trailingAnchor = row.trailingAnchor
        var trailingConstant: CGFloat = -84
        if !shortcut.isBuiltIn {
            let removeButton = FinderSettingsButton()
            removeButton.title = AppStrings.text(.finderRemove)
            removeButton.bezelStyle = .rounded
            removeButton.identifier = NSUserInterfaceItemIdentifier(shortcut.id.uuidString)
            removeButton.target = self
            removeButton.action = #selector(removeItem(_:))
            removeButton.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(removeButton)
            NSLayoutConstraint.activate([
                removeButton.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -12),
                removeButton.centerYAnchor.constraint(equalTo: row.centerYAnchor)
            ])
            trailingAnchor = removeButton.leadingAnchor
            trailingConstant = -12
        }

        NSLayoutConstraint.activate([
            enabled.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 12),
            enabled.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            enabled.widthAnchor.constraint(equalToConstant: 18),

            iconView.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 42),
            iconView.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 26),
            iconView.heightAnchor.constraint(equalToConstant: 26),

            name.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 78),
            name.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            name.trailingAnchor.constraint(lessThanOrEqualTo: status.leadingAnchor, constant: -12),

            status.trailingAnchor.constraint(equalTo: trailingAnchor, constant: trailingConstant),
            status.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            status.widthAnchor.constraint(equalToConstant: 104)
        ])
        return row
    }

    private func resolvedApplicationURL(for shortcut: FinderLaunchShortcut) -> URL? {
        FinderApplicationTargetResolver.resolve(
            shortcut: shortcut,
            fileExists: FileManager.default.fileExists(atPath:),
            installedApplicationURL: { bundleIdentifier in
                NSWorkspace.shared.urlForApplication(
                    withBundleIdentifier: bundleIdentifier
                )
            }
        )
    }

    private func makeSettingRow(title: String, detail: String, control: NSView) -> NSView {
        let row = FinderSettingsSurfaceView(style: .setting)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: 68).isActive = true

        let labels = NSStackView()
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 3
        let titleField = NSTextField(labelWithString: title)
        titleField.font = .systemFont(ofSize: 14, weight: .semibold)
        let detailField = NSTextField(labelWithString: detail)
        detailField.font = .systemFont(ofSize: 12)
        detailField.textColor = .secondaryLabelColor
        detailField.lineBreakMode = .byTruncatingTail
        labels.addArrangedSubview(titleField)
        labels.addArrangedSubview(detailField)

        labels.translatesAutoresizingMaskIntoConstraints = false
        control.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(labels)
        row.addSubview(control)
        NSLayoutConstraint.activate([
            labels.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 14),
            labels.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: control.leadingAnchor, constant: -16),
            labels.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor, constant: 10),
            labels.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor, constant: -10),
            control.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -14),
            control.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])
        return row
    }

    private func updateSectionSelection() {
        for (section, button) in sectionButtons {
            button.isSelected = section == selectedSection
        }
    }

    @objc private func toggleExtension(_ sender: NSSwitch) {
        if sender.state == .on {
            guard onEnableRequest?(sender) ?? false else {
                sender.state = .off
                return
            }
            settings.finderExtensionEnabled = true
        } else {
            settings.finderExtensionEnabled = false
        }
        reload()
    }

    @objc private func openExtensionManagement(_ sender: NSButton) {
        onOpenExtensionManagement?()
    }

    @objc private func selectSectionButton(_ sender: FinderSettingsSectionButton) {
        selectSection(sender.section)
    }

    @objc private func toggleGrouping(_ sender: NSSwitch) {
        settings.finderLaunchShortcutsGrouped = sender.state == .on
    }

    @objc private func toggleDocumentType(_ sender: NSButton) {
        guard let rawValue = sender.identifier?.rawValue,
              let id = UUID(uuidString: rawValue)
        else {
            return
        }
        settings.setFinderDocumentPresetEnabled(id: id, isEnabled: sender.state == .on)
        rebuildDetail()
    }

    @objc private func toggleQuickAction(_ sender: NSButton) {
        guard let rawValue = sender.identifier?.rawValue,
              let id = UUID(uuidString: rawValue),
              let shortcut = settings.finderLaunchShortcuts.first(where: { $0.id == id })
        else {
            return
        }

        if sender.state == .on {
            guard let applicationURL = resolvedApplicationURL(for: shortcut) else {
                sender.state = .off
                NSSound.beep()
                return
            }
            settings.setFinderLaunchShortcutEnabled(
                id: id,
                isEnabled: true,
                resolvedApplicationURL: applicationURL
            )
        } else {
            settings.setFinderLaunchShortcutEnabled(id: id, isEnabled: false)
        }
        rebuildDetail()
    }

    @objc private func addItem(_ sender: NSButton) {
        switch selectedSection {
        case .documentTypes:
            onAddDocumentType?()
        case .quickActions:
            onAddQuickAction?()
        }
    }

    @objc private func removeItem(_ sender: NSButton) {
        guard let rawValue = sender.identifier?.rawValue,
              let id = UUID(uuidString: rawValue)
        else {
            return
        }
        switch selectedSection {
        case .documentTypes:
            onRemoveDocumentType?(id)
        case .quickActions:
            onRemoveQuickAction?(id)
        }
    }
}

private final class FinderSettingsSectionButton: NSButton {
    let section: FinderExtensionSettingsSection

    override var alignmentRectInsets: NSEdgeInsets {
        NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    }

    var isSelected = false {
        didSet {
            updateAppearance()
        }
    }

    init(section: FinderExtensionSettingsSection) {
        self.section = section
        super.init(frame: .zero)
        title = section.title
        image = NSImage(systemSymbolName: section.symbolName, accessibilityDescription: section.title)
        imagePosition = .imageLeading
        alignment = .left
        imageHugsTitle = true
        isBordered = false
        font = .systemFont(ofSize: 13, weight: .medium)
        wantsLayer = true
        layer?.cornerRadius = 6
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 44).isActive = true
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    private func updateAppearance() {
        let palette = OmniDockTheme.palette(for: effectiveAppearance)
        layer?.backgroundColor = isSelected
            ? NSColor.controlAccentColor.withAlphaComponent(0.16).cgColor
            : palette.raisedSurface.cgColor
        contentTintColor = isSelected ? .controlAccentColor : palette.primaryText
    }
}

private final class FinderSettingsSurfaceView: NSView {
    enum Style {
        case setting
        case item
    }

    private let style: Style

    init(style: Style) {
        self.style = style
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    private func updateAppearance() {
        let palette = OmniDockTheme.palette(for: effectiveAppearance)
        layer?.backgroundColor = switch style {
        case .setting:
            palette.raisedSurface.cgColor
        case .item:
            palette.surface.cgColor
        }
    }
}

private final class FinderSettingsButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

private final class FinderSettingsSwitch: NSSwitch {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}
