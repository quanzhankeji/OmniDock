import AppKit

@MainActor
final class FinderDocumentTypeFormView: NSView {
    let nameField = NSTextField()
    let fileExtensionField = NSTextField()

    init(nameLabel: String, fileExtensionLabel: String) {
        super.init(frame: CGRect(x: 0, y: 0, width: 360, height: 70))

        let nameTitle = makeLabel(nameLabel)
        let fileExtensionTitle = makeLabel(fileExtensionLabel)

        configureTextField(nameField, accessibilityLabel: nameLabel)
        configureTextField(fileExtensionField, accessibilityLabel: fileExtensionLabel)
        nameField.nextKeyView = fileExtensionField

        for view in [nameTitle, fileExtensionTitle, nameField, fileExtensionField] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }

        NSLayoutConstraint.activate([
            nameTitle.leadingAnchor.constraint(equalTo: leadingAnchor),
            nameTitle.centerYAnchor.constraint(equalTo: nameField.centerYAnchor),
            fileExtensionTitle.leadingAnchor.constraint(equalTo: leadingAnchor),
            fileExtensionTitle.centerYAnchor.constraint(equalTo: fileExtensionField.centerYAnchor),
            fileExtensionTitle.trailingAnchor.constraint(equalTo: nameTitle.trailingAnchor),

            nameField.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            nameField.leadingAnchor.constraint(equalTo: nameTitle.trailingAnchor, constant: 12),
            nameField.trailingAnchor.constraint(equalTo: trailingAnchor),
            nameField.heightAnchor.constraint(equalToConstant: 26),

            fileExtensionField.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 10),
            fileExtensionField.leadingAnchor.constraint(equalTo: nameField.leadingAnchor),
            fileExtensionField.trailingAnchor.constraint(equalTo: trailingAnchor),
            fileExtensionField.heightAnchor.constraint(equalToConstant: 26),
            fileExtensionField.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),

            nameField.widthAnchor.constraint(greaterThanOrEqualToConstant: 250)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    private func makeLabel(_ value: String) -> NSTextField {
        let label = NSTextField(labelWithString: value)
        label.font = .systemFont(ofSize: 13)
        label.textColor = .labelColor
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        return label
    }

    private func configureTextField(
        _ field: NSTextField,
        accessibilityLabel: String
    ) {
        field.isEditable = true
        field.isSelectable = true
        field.isEnabled = true
        field.font = .systemFont(ofSize: 13)
        field.setAccessibilityLabel(accessibilityLabel)
    }
}
