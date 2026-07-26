import AppKit

enum ClipboardInspectorPlacement {
    static func origin(
        beside sourceFrame: NSRect,
        detailSize: NSSize,
        visibleFrame: NSRect,
        gap: CGFloat = 8
    ) -> NSPoint {
        let rightOrigin = sourceFrame.maxX + gap
        let leftOrigin = sourceFrame.minX - gap - detailSize.width
        let availableRight = visibleFrame.maxX - sourceFrame.maxX - gap
        let availableLeft = sourceFrame.minX - visibleFrame.minX - gap

        let x: CGFloat
        if availableRight >= detailSize.width {
            x = rightOrigin
        } else if availableLeft >= detailSize.width {
            x = leftOrigin
        } else if availableRight >= availableLeft {
            x = visibleFrame.maxX - detailSize.width
        } else {
            x = visibleFrame.minX
        }

        return NSPoint(
            x: constrained(
                x,
                minimum: visibleFrame.minX,
                maximum: visibleFrame.maxX - detailSize.width
            ),
            y: constrained(
                sourceFrame.maxY - detailSize.height,
                minimum: visibleFrame.minY,
                maximum: visibleFrame.maxY - detailSize.height
            )
        )
    }

    private static func constrained(
        _ value: CGFloat,
        minimum: CGFloat,
        maximum: CGFloat
    ) -> CGFloat {
        guard maximum >= minimum else {
            return minimum
        }
        return min(max(value, minimum), maximum)
    }
}

@MainActor
final class ClipboardInspectorPanel: NSPanel {
    private let detailView = ClipboardInspectorView()

    init() {
        super.init(
            contentRect: NSRect(
                origin: .zero,
                size: ClipboardPaletteLayout.preferredDetailSize
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .statusBar
        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        contentMaxSize = ClipboardPaletteLayout.preferredDetailSize
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        contentView = detailView
        OmniDockTheme.applyCurrentAppearance(to: self)
    }

    func present(
        _ content: ClipboardHistoryPreviewContent,
        beside sourceWindow: NSWindow
    ) {
        if parent !== sourceWindow {
            parent?.removeChildWindow(self)
            sourceWindow.addChildWindow(self, ordered: .above)
        }

        let visibleFrame = sourceWindow.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSScreen.screens.first?.visibleFrame
        if let visibleFrame {
            let targetSize = ClipboardPaletteLayout.detailSize(
                beside: sourceWindow.frame,
                in: visibleFrame
            )
            contentMaxSize = targetSize
            setContentSize(targetSize)
            detailView.update(content)
            detailView.layoutSubtreeIfNeeded()
            setContentSize(targetSize)
            setFrameOrigin(ClipboardInspectorPlacement.origin(
                beside: sourceWindow.frame,
                detailSize: targetSize,
                visibleFrame: visibleFrame,
                gap: ClipboardPaletteLayout.panelGap
            ))
        } else {
            detailView.update(content)
        }
        orderFront(nil)
    }

    func dismiss() {
        parent?.removeChildWindow(self)
        orderOut(nil)
    }
}

@MainActor
private final class ClipboardInspectorView: NSVisualEffectView {
    private let iconView = NSImageView()
    private let applicationLabel = NSTextField(labelWithString: "")
    private let summaryLabel = NSTextField(labelWithString: "")
    private let contentContainer = NSView()
    private let firstCopiedLabel = NSTextField(labelWithString: "")
    private let lastCopiedLabel = NSTextField(labelWithString: "")
    private let copyCountLabel = NSTextField(labelWithString: "")
    private var displayedContentView: NSView?

    init() {
        super.init(frame: .zero)
        material = .popover
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        applicationLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        applicationLabel.lineBreakMode = .byTruncatingTail
        applicationLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        summaryLabel.font = .systemFont(ofSize: 11)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let headerLabels = NSStackView(views: [applicationLabel, summaryLabel])
        headerLabels.orientation = .vertical
        headerLabels.alignment = .leading
        headerLabels.spacing = 2
        headerLabels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        headerLabels.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerLabels)

        let topDivider = NSBox()
        topDivider.boxType = .separator
        topDivider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(topDivider)

        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentContainer)

        let bottomDivider = NSBox()
        bottomDivider.boxType = .separator
        bottomDivider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bottomDivider)

        for label in [firstCopiedLabel, lastCopiedLabel, copyCountLabel] {
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingTail
        }
        let metadata = NSStackView(
            views: [firstCopiedLabel, lastCopiedLabel, copyCountLabel]
        )
        metadata.orientation = .vertical
        metadata.alignment = .leading
        metadata.spacing = 3
        metadata.translatesAutoresizingMaskIntoConstraints = false
        addSubview(metadata)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            iconView.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            iconView.widthAnchor.constraint(equalToConstant: 32),
            iconView.heightAnchor.constraint(equalToConstant: 32),

            headerLabels.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            headerLabels.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            headerLabels.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),

            topDivider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            topDivider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            topDivider.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 14),

            contentContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            contentContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            contentContainer.topAnchor.constraint(equalTo: topDivider.bottomAnchor, constant: 14),
            contentContainer.bottomAnchor.constraint(equalTo: bottomDivider.topAnchor, constant: -14),

            bottomDivider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            bottomDivider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            bottomDivider.bottomAnchor.constraint(equalTo: metadata.topAnchor, constant: -12),

            metadata.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            metadata.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            metadata.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14)
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    func update(_ content: ClipboardHistoryPreviewContent) {
        let record = content.record
        iconView.image = ClipboardSourceArtwork.icon(
            bundleIdentifier: record.sourceBundleIdentifier
        )
        applicationLabel.stringValue = ClipboardHistoryDisplayText.sourceName(
            record.sourceApplicationName
        )
        summaryLabel.stringValue = ClipboardHistoryDisplayText.summary(record.summary)

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short
        firstCopiedLabel.stringValue = AppStrings.format(
            .clipboardPreviewFirstCopied,
            dateFormatter.string(from: record.capturedAt)
        )
        lastCopiedLabel.stringValue = AppStrings.format(
            .clipboardPreviewLastCopied,
            dateFormatter.string(from: record.lastCopiedAt)
        )
        copyCountLabel.stringValue = AppStrings.format(
            .clipboardPreviewCopyCount,
            record.copyCount
        )

        displayedContentView?.removeFromSuperview()
        let contentView: NSView
        if let imageData = content.imageData,
           let image = NSImage(data: imageData) {
            let imageView = NSImageView(image: image)
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.wantsLayer = true
            imageView.layer?.cornerRadius = 5
            imageView.layer?.masksToBounds = true
            imageView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            imageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
            imageView.setContentHuggingPriority(.defaultLow, for: .horizontal)
            imageView.setContentHuggingPriority(.defaultLow, for: .vertical)
            contentView = imageView
        } else {
            let text = content.filePaths.isEmpty
                ? (content.text ?? record.searchableText)
                : AppStrings.text(.clipboardPreviewFiles)
                    + "\n\n"
                    + content.filePaths.joined(separator: "\n")
            contentView = Self.makeScrollableTextRegion(text)
        }

        contentView.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor)
        ])
        displayedContentView = contentView
    }

    private static func makeScrollableTextRegion(_ text: String) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let documentView = TopAnchoredDocumentView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 13)
        label.textColor = .labelColor
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(label)
        scrollView.documentView = documentView

        NSLayoutConstraint.activate([
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            documentView.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.heightAnchor),
            label.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -2),
            label.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -2)
        ])
        return scrollView
    }
}
