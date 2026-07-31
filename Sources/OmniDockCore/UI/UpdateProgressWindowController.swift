import AppKit

@MainActor
final class UpdateProgressWindowController {
    private var window: NSWindow?
    private var progressIndicator: NSProgressIndicator?
    private var statusField: NSTextField?
    var onCancel: (() -> Void)?

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        update(progress: 0)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func update(progress: Double) {
        progressIndicator?.doubleValue = min(max(progress, 0), 1) * 100
        statusField?.stringValue = AppStrings.format(
            .updateDownloadProgress,
            Int((min(max(progress, 0), 1) * 100).rounded())
        )
    }

    func showInstalling() {
        progressIndicator?.isIndeterminate = true
        progressIndicator?.startAnimation(nil)
        statusField?.stringValue = AppStrings.text(.updateInstalling)
    }

    func close() {
        progressIndicator?.stopAnimation(nil)
        window?.orderOut(nil)
    }

    @objc private func cancel(_ sender: NSButton) {
        onCancel?()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 132),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = AppStrings.text(.updateWindowTitle)
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false

        let statusField = NSTextField(
            labelWithString: AppStrings.text(.updatePreparingDownload)
        )
        statusField.font = .systemFont(ofSize: 13, weight: .medium)
        statusField.translatesAutoresizingMaskIntoConstraints = false
        self.statusField = statusField

        let progressIndicator = NSProgressIndicator()
        progressIndicator.style = .bar
        progressIndicator.isIndeterminate = false
        progressIndicator.minValue = 0
        progressIndicator.maxValue = 100
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false
        self.progressIndicator = progressIndicator

        let cancelButton = NSButton(
            title: AppStrings.text(.updateCancel),
            target: self,
            action: #selector(cancel(_:))
        )
        cancelButton.bezelStyle = .rounded
        cancelButton.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(statusField)
        content.addSubview(progressIndicator)
        content.addSubview(cancelButton)
        window.contentView = content

        NSLayoutConstraint.activate([
            statusField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            statusField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            statusField.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),

            progressIndicator.leadingAnchor.constraint(equalTo: statusField.leadingAnchor),
            progressIndicator.trailingAnchor.constraint(equalTo: statusField.trailingAnchor),
            progressIndicator.topAnchor.constraint(equalTo: statusField.bottomAnchor, constant: 14),

            cancelButton.trailingAnchor.constraint(equalTo: statusField.trailingAnchor),
            cancelButton.topAnchor.constraint(equalTo: progressIndicator.bottomAnchor, constant: 14),
            cancelButton.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -16)
        ])
        return window
    }
}
