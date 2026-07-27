import AppKit

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

        NSLayoutConstraint.activate([
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            documentView.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.heightAnchor),
            itemRows.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            itemRows.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            itemRows.topAnchor.constraint(equalTo: documentView.topAnchor)
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
            for preset in settings.finderDocumentPresets {
                itemRows.addArrangedSubview(makeListRow(
                    title: preset.displayName,
                    detail: ".\(preset.fileExtension)",
                    id: preset.id,
                    icon: nil
                ))
            }
        case .quickActions:
            rebuildQuickActions()
        }
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

        for action in actions {
            itemRows.addArrangedSubview(makeListRow(
                title: action.displayName,
                detail: action.bundleIdentifier ?? action.bundleURL?.path ?? "",
                id: action.id,
                icon: action.bundleURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
            ))
        }
    }

    private func makeListRow(
        title: String,
        detail: String,
        id: UUID,
        icon: NSImage?
    ) -> NSView {
        let row = FinderSettingsSurfaceView(style: .item)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: 56).isActive = true

        let labels = NSStackView()
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        labels.translatesAutoresizingMaskIntoConstraints = false

        let titleField = NSTextField(labelWithString: title)
        titleField.font = .systemFont(ofSize: 13, weight: .medium)
        let detailField = NSTextField(labelWithString: detail)
        detailField.font = .systemFont(ofSize: 11)
        detailField.textColor = .secondaryLabelColor
        detailField.lineBreakMode = .byTruncatingMiddle
        labels.addArrangedSubview(titleField)
        labels.addArrangedSubview(detailField)

        let removeButton = FinderSettingsButton()
        removeButton.title = AppStrings.text(.finderRemove)
        removeButton.bezelStyle = .rounded
        removeButton.identifier = NSUserInterfaceItemIdentifier(id.uuidString)
        removeButton.target = self
        removeButton.action = #selector(removeItem(_:))
        removeButton.translatesAutoresizingMaskIntoConstraints = false

        row.addSubview(labels)
        row.addSubview(removeButton)

        var labelsLeadingAnchor = row.leadingAnchor
        if let icon {
            let iconView = NSImageView(image: icon)
            iconView.imageScaling = .scaleProportionallyUpOrDown
            iconView.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(iconView)
            NSLayoutConstraint.activate([
                iconView.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 12),
                iconView.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                iconView.widthAnchor.constraint(equalToConstant: 26),
                iconView.heightAnchor.constraint(equalToConstant: 26)
            ])
            labelsLeadingAnchor = iconView.trailingAnchor
        }

        NSLayoutConstraint.activate([
            labels.leadingAnchor.constraint(
                equalTo: labelsLeadingAnchor,
                constant: icon == nil ? 12 : 9
            ),
            labels.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: removeButton.leadingAnchor, constant: -12),
            removeButton.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -12),
            removeButton.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])
        return row
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
