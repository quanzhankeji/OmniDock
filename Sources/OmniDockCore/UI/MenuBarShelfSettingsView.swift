import AppKit

@MainActor
final class MenuBarShelfSettingsView: NSView {
    private let settings: SettingsStore
    private let enableSwitch = NSSwitch()
    private let autoHideSwitch = NSSwitch()
    private let delayPopup = NSPopUpButton()

    init(settings: SettingsStore) {
        self.settings = settings
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        buildInterface()
        reload()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func reload() {
        enableSwitch.state = settings.menuBarShelfEnabled ? .on : .off
        autoHideSwitch.state = settings.menuBarShelfAutoHideEnabled ? .on : .off
        autoHideSwitch.isEnabled = settings.menuBarShelfEnabled
        delayPopup.isEnabled = settings.menuBarShelfEnabled && settings.menuBarShelfAutoHideEnabled
        delayPopup.selectItem(withTag: settings.menuBarShelfAutoHideDelay)
    }

    @objc private func toggleFeature(_ sender: NSSwitch) {
        settings.menuBarShelfEnabled = sender.state == .on
        reload()
    }

    @objc private func toggleAutoHide(_ sender: NSSwitch) {
        settings.menuBarShelfAutoHideEnabled = sender.state == .on
        reload()
    }

    @objc private func changeDelay(_ sender: NSPopUpButton) {
        guard let delay = sender.selectedItem?.tag else {
            return
        }
        settings.menuBarShelfAutoHideDelay = delay
        reload()
    }

    private func buildInterface() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let illustration = makeIllustration()
        stack.addArrangedSubview(illustration)

        enableSwitch.target = self
        enableSwitch.action = #selector(toggleFeature(_:))
        stack.addArrangedSubview(makeSettingRow(
            title: AppStrings.text(.menuBarShelfEnableTitle),
            detail: AppStrings.text(.menuBarShelfEnableDetail),
            control: enableSwitch
        ))

        autoHideSwitch.target = self
        autoHideSwitch.action = #selector(toggleAutoHide(_:))
        configureDelayPopup()
        let autoHideControls = NSStackView(views: [delayPopup, autoHideSwitch])
        autoHideControls.orientation = .horizontal
        autoHideControls.alignment = .centerY
        autoHideControls.spacing = 10
        stack.addArrangedSubview(makeSettingRow(
            title: AppStrings.text(.menuBarShelfAutoHideTitle),
            detail: AppStrings.text(.menuBarShelfAutoHideDetail),
            control: autoHideControls
        ))

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            illustration.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    private func configureDelayPopup() {
        delayPopup.removeAllItems()
        for delay in MenuBarShelfAutoHidePolicy.allowedDelays {
            delayPopup.addItem(withTitle: AppStrings.format(.menuBarShelfSeconds, delay))
            delayPopup.lastItem?.tag = delay
        }
        delayPopup.target = self
        delayPopup.action = #selector(changeDelay(_:))
        delayPopup.setAccessibilityLabel(AppStrings.text(.menuBarShelfAutoHideTitle))
    }

    private func makeIllustration() -> NSView {
        let box = NSBox()
        box.boxType = .custom
        box.titlePosition = .noTitle
        box.cornerRadius = 8
        box.borderWidth = 1
        box.borderColor = .separatorColor
        box.fillColor = .controlBackgroundColor
        box.translatesAutoresizingMaskIntoConstraints = false

        let iconStrip = NSStackView()
        iconStrip.orientation = .horizontal
        iconStrip.alignment = .centerY
        iconStrip.spacing = 14
        iconStrip.translatesAutoresizingMaskIntoConstraints = false

        let hiddenIcons = makeSymbolStrip(["drop", "trash", "gamecontroller"])
        let shownIcons = makeSymbolStrip(["battery.75percent", "wifi", "magnifyingglass", "switch.2"])
        let divider = NSTextField(labelWithString: "│")
        divider.font = .systemFont(ofSize: 28, weight: .ultraLight)
        divider.textColor = .secondaryLabelColor

        iconStrip.addArrangedSubview(hiddenIcons)
        iconStrip.addArrangedSubview(divider)
        iconStrip.addArrangedSubview(shownIcons)

        let labels = NSStackView()
        labels.orientation = .horizontal
        labels.alignment = .centerY
        labels.distribution = .fillEqually
        labels.translatesAutoresizingMaskIntoConstraints = false
        labels.addArrangedSubview(makeSectionLabel(AppStrings.text(.menuBarShelfHiddenLabel)))
        labels.addArrangedSubview(makeSectionLabel(AppStrings.text(.menuBarShelfShownLabel)))

        let instruction = NSTextField(
            wrappingLabelWithString: AppStrings.text(.menuBarShelfInstruction)
        )
        instruction.font = .systemFont(ofSize: 12)
        instruction.textColor = .secondaryLabelColor
        instruction.alignment = .center
        instruction.maximumNumberOfLines = 2
        instruction.translatesAutoresizingMaskIntoConstraints = false

        box.addSubview(iconStrip)
        box.addSubview(labels)
        box.addSubview(instruction)

        NSLayoutConstraint.activate([
            box.heightAnchor.constraint(equalToConstant: 220),
            iconStrip.topAnchor.constraint(equalTo: box.topAnchor, constant: 30),
            iconStrip.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            labels.topAnchor.constraint(equalTo: iconStrip.bottomAnchor, constant: 18),
            labels.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            labels.widthAnchor.constraint(equalToConstant: 300),
            instruction.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 36),
            instruction.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -36),
            instruction.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -28)
        ])
        return box
    }

    private func makeSymbolStrip(_ names: [String]) -> NSStackView {
        let strip = NSStackView()
        strip.orientation = .horizontal
        strip.alignment = .centerY
        strip.spacing = 14
        for name in names {
            let imageView = NSImageView()
            imageView.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            imageView.contentTintColor = .labelColor
            imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 17, weight: .regular)
            imageView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                imageView.widthAnchor.constraint(equalToConstant: 22),
                imageView.heightAnchor.constraint(equalToConstant: 22)
            ])
            strip.addArrangedSubview(imageView)
        }
        return strip
    }

    private func makeSectionLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 16, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        return label
    }

    private func makeSettingRow(title: String, detail: String, control: NSView) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let labels = NSStackView()
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 3
        labels.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 14, weight: .medium)
        titleLabel.textColor = .labelColor
        let detailLabel = NSTextField(wrappingLabelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 2
        labels.addArrangedSubview(titleLabel)
        labels.addArrangedSubview(detailLabel)

        control.translatesAutoresizingMaskIntoConstraints = false
        control.setAccessibilityLabel(title)
        row.addSubview(labels)
        row.addSubview(control)

        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
            labels.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            labels.topAnchor.constraint(equalTo: row.topAnchor),
            labels.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: control.leadingAnchor, constant: -16),
            control.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            control.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])
        return row
    }
}
