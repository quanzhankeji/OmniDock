import AppKit

enum HotkeyGuidancePresentation {
    static var message: String {
        ShortcutRecorderValidation.regularKeyMinimumModifierMessage
    }

    static func isVisible(hotkeysEnabled: Bool) -> Bool {
        hotkeysEnabled
    }

    static func headerHeight(hotkeysEnabled: Bool) -> CGFloat {
        hotkeysEnabled ? 86 : 50
    }
}

enum HotkeyRowWarningPresentation {
    static func visibleWarning(_ warning: String?) -> String? {
        guard warning != ShortcutRecorderValidation.regularKeyMinimumModifierMessage else {
            return nil
        }
        return warning
    }
}

final class PermissionStatusView: NSControl {
    var onRequestPermission: ((PermissionKind) -> Void)?

    private let kind: PermissionKind
    private let dotView = NSView()
    private let label = NSTextField(labelWithString: "")
    private var isGranted = false

    init(kind: PermissionKind) {
        self.kind = kind
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(isGranted: Bool) {
        self.isGranted = isGranted
        let status = isGranted ? AppStrings.text(.permissionGranted) : AppStrings.text(.permissionNotGranted)
        label.stringValue = AppStrings.format(.permissionStatusFormat, kind.title, status)
        toolTip = isGranted ? nil : AppStrings.format(.permissionOpenTooltip, kind.title)
        applyTheme()
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    override func mouseDown(with event: NSEvent) {
        guard !isGranted else {
            return
        }
        onRequestPermission?(kind)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if !isGranted {
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }

    private func setup() {
        translatesAutoresizingMaskIntoConstraints = false

        dotView.translatesAutoresizingMaskIntoConstraints = false
        dotView.wantsLayer = true
        dotView.layer?.cornerRadius = 4

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 12)

        addSubview(dotView)
        addSubview(label)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 22),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 260),

            dotView.leadingAnchor.constraint(equalTo: leadingAnchor),
            dotView.centerYAnchor.constraint(equalTo: centerYAnchor),
            dotView.widthAnchor.constraint(equalToConstant: 8),
            dotView.heightAnchor.constraint(equalToConstant: 8),

            label.leadingAnchor.constraint(equalTo: dotView.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        applyTheme()
    }

    private func applyTheme() {
        let palette = OmniDockTheme.palette(for: effectiveAppearance)
        dotView.layer?.backgroundColor = (isGranted ? palette.success : palette.neutral).cgColor
        label.textColor = isGranted ? palette.secondaryText : palette.primaryText
    }
}

final class AppHotkeyRowView: NSView {
    var onShortcutChange: ((AppHotkeyBinding, RecordedShortcut?) -> Void)?
    var onRemove: ((AppHotkeyBinding) -> Void)?

    private let binding: AppHotkeyBinding
    private let warning: String?
    private let recorderView = ShortcutRecorderView(frame: .zero)

    init(binding: AppHotkeyBinding, warning: String?) {
        self.binding = binding
        self.warning = warning
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func remove(_ sender: NSButton) {
        onRemove?(binding)
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 8
        translatesAutoresizingMaskIntoConstraints = false

        let iconView = NSImageView()
        iconView.image = appIcon()
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let labels = NSStackView()
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        labels.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: binding.appName)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.textColor = .labelColor

        let detail = NSTextField(labelWithString: detailText())
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = isAvailable ? .secondaryLabelColor : .systemGray
        detail.lineBreakMode = .byTruncatingTail

        labels.addArrangedSubview(title)
        labels.addArrangedSubview(detail)

        if let warning {
            let warningField = NSTextField(labelWithString: warning)
            warningField.font = .systemFont(ofSize: 11)
            warningField.textColor = .systemRed
            warningField.lineBreakMode = .byTruncatingTail
            labels.addArrangedSubview(warningField)
        }

        recorderView.translatesAutoresizingMaskIntoConstraints = false
        recorderView.recordedShortcut = binding.recordedShortcut
        recorderView.isEnabled = isAvailable
        recorderView.onChange = { [weak self] shortcut in
            guard let self else {
                return
            }
            self.onShortcutChange?(self.binding, shortcut)
        }

        let removeButton = NSButton(title: AppStrings.text(.hotkeyRemove), target: self, action: #selector(remove(_:)))
        removeButton.bezelStyle = .rounded
        removeButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(labels)
        addSubview(recorderView)
        addSubview(removeButton)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: warning == nil ? 58 : 74),

            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 34),
            iconView.heightAnchor.constraint(equalToConstant: 34),

            labels.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: recorderView.leadingAnchor, constant: -12),

            recorderView.widthAnchor.constraint(equalToConstant: 160),
            recorderView.heightAnchor.constraint(equalToConstant: 28),
            recorderView.centerYAnchor.constraint(equalTo: centerYAnchor),

            removeButton.leadingAnchor.constraint(equalTo: recorderView.trailingAnchor, constant: 10),
            removeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            removeButton.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        applyTheme()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    private func applyTheme() {
        layer?.backgroundColor = OmniDockTheme.palette(for: effectiveAppearance)
            .raisedSurface
            .withAlphaComponent(0.88)
            .cgColor
    }

    private var isAvailable: Bool {
        guard let url = binding.bundleURL else {
            return false
        }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private func detailText() -> String {
        if !isAvailable {
            return AppStrings.text(.hotkeyAppUnavailable)
        }
        return binding.bundleIdentifier ?? binding.bundleURL?.path ?? ""
    }

    private func appIcon() -> NSImage? {
        guard let url = binding.bundleURL,
              FileManager.default.fileExists(atPath: url.path)
        else {
            return NSImage(named: NSImage.cautionName)
        }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.size = NSSize(width: 34, height: 34)
        return image
    }
}

extension NSStackView {
    func removeAllArrangedSubviews() {
        for view in arrangedSubviews {
            removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }
}
