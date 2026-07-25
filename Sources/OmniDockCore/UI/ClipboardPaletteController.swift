import AppKit
import Carbon.HIToolbox

enum ClipboardPaletteLayout {
    static let preferredHistorySize = NSSize(width: 450, height: 540)
    static let preferredDetailSize = NSSize(width: 400, height: 540)
    static let screenPadding: CGFloat = 12
    static let panelGap: CGFloat = 8

    static func historySize(in visibleFrame: NSRect) -> NSSize {
        fittedSize(
            preferredHistorySize,
            maximumWidth: visibleFrame.width - (screenPadding * 2),
            maximumHeight: visibleFrame.height - (screenPadding * 2)
        )
    }

    static func detailSize(
        beside sourceFrame: NSRect,
        in visibleFrame: NSRect
    ) -> NSSize {
        let availableRight = visibleFrame.maxX - sourceFrame.maxX - panelGap
        let availableLeft = sourceFrame.minX - visibleFrame.minX - panelGap
        return fittedSize(
            preferredDetailSize,
            maximumWidth: max(availableLeft, availableRight),
            maximumHeight: visibleFrame.height - (screenPadding * 2)
        )
    }

    private static func fittedSize(
        _ preferredSize: NSSize,
        maximumWidth: CGFloat,
        maximumHeight: CGFloat
    ) -> NSSize {
        NSSize(
            width: min(preferredSize.width, max(1, maximumWidth)),
            height: min(preferredSize.height, max(1, maximumHeight))
        )
    }
}

enum ClipboardPalettePlacement {
    static func origin(
        cursor: NSPoint,
        panelSize: NSSize,
        visibleFrame: NSRect
    ) -> NSPoint {
        let proposedOrigin = NSPoint(
            x: cursor.x,
            y: cursor.y - panelSize.height
        )
        return NSPoint(
            x: constrained(
                proposedOrigin.x,
                minimum: visibleFrame.minX,
                maximum: visibleFrame.maxX - panelSize.width
            ),
            y: constrained(
                proposedOrigin.y,
                minimum: visibleFrame.minY,
                maximum: visibleFrame.maxY - panelSize.height
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
final class ClipboardPaletteController: NSObject, NSSearchFieldDelegate, NSWindowDelegate {
    var onChoose: ((UUID, Bool, NSRunningApplication?) -> Void)?
    var onDelete: ((UUID) -> Void)?
    var onPreviewRequest: ((UUID) -> ClipboardHistoryPreviewContent?)?

    private var panel: ClipboardPaletteWindow?
    private var detailPanel: ClipboardInspectorPanel?
    private var searchField: NSSearchField?
    private var listStack: NSStackView?
    private var emptyLabel: NSTextField?
    private var messageLabel: NSTextField?
    private var records: [ClipboardHistoryRecord] = []
    private var visibleRecords: [ClipboardHistoryRecord] = []
    private var rowViews: [UUID: ClipboardPaletteRowView] = [:]
    private var selectedIndex = 0
    private var sourceApplication: NSRunningApplication?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var messageWorkItem: DispatchWorkItem?
    private var previewWorkItem: DispatchWorkItem?
    private var previewRequestGeneration = 0
    private var pendingPreviewRecordID: UUID?
    private var previewedRecordID: UUID?

    private static let hoverPreviewDelay: TimeInterval = 0.4

    var isVisible: Bool {
        panel?.isVisible == true
    }

    var currentPanelSize: NSSize? {
        panel?.frame.size
    }

    func toggle(
        records: [ClipboardHistoryRecord],
        warning: String?,
        sourceApplication: NSRunningApplication?
    ) {
        if isVisible {
            hide()
        } else {
            show(records: records, warning: warning, sourceApplication: sourceApplication)
        }
    }

    func show(
        records: [ClipboardHistoryRecord],
        warning: String?,
        sourceApplication: NSRunningApplication?
    ) {
        let panel = panel ?? makePanel()
        self.panel = panel
        self.sourceApplication = sourceApplication
        dismissPreview()
        searchField?.stringValue = ""
        update(records: records, warning: warning)
        position(panel)
        installMouseMonitors()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
    }

    func update(records: [ClipboardHistoryRecord], warning: String?) {
        self.records = records
        if let previewedRecordID,
           !records.contains(where: { $0.id == previewedRecordID }) {
            dismissPreview()
        }
        messageLabel?.stringValue = warning ?? ""
        messageLabel?.isHidden = warning == nil
        applySearch()
    }

    func hide() {
        messageWorkItem?.cancel()
        messageWorkItem = nil
        dismissPreview()
        removeMouseMonitors()
        panel?.orderOut(nil)
        sourceApplication = nil
    }

    func showTransientMessage(_ message: String, hideAfter delay: TimeInterval? = nil) {
        messageWorkItem?.cancel()
        messageLabel?.stringValue = message
        messageLabel?.isHidden = false
        guard let delay else {
            return
        }
        let workItem = DispatchWorkItem { [weak self] in
            self?.hide()
        }
        messageWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    func controlTextDidChange(_ obj: Notification) {
        guard obj.object as? NSSearchField === searchField else {
            return
        }
        dismissPreview()
        applySearch()
    }

    func windowDidResignKey(_ notification: Notification) {
        guard notification.object as? NSPanel === panel else {
            return
        }
        hide()
    }

    private func makePanel() -> ClipboardPaletteWindow {
        let panel = ClipboardPaletteWindow(
            contentRect: NSRect(
                origin: .zero,
                size: ClipboardPaletteLayout.preferredHistorySize
            ),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentMaxSize = ClipboardPaletteLayout.preferredHistorySize
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.delegate = self
        panel.onKeyDown = { [weak self] event in
            self?.handleKeyDown(event) ?? false
        }
        OmniDockTheme.applyCurrentAppearance(to: panel)

        let root = NSVisualEffectView()
        root.material = .popover
        root.blendingMode = .behindWindow
        root.state = .active
        root.wantsLayer = true
        root.layer?.cornerRadius = 8
        root.layer?.masksToBounds = true
        panel.contentView = root

        let searchField = NSSearchField()
        searchField.placeholderString = AppStrings.text(.clipboardSearchPlaceholder)
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(searchField)
        self.searchField = searchField

        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scrollView)

        let documentView = TopAnchoredDocumentView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        let listStack = NSStackView()
        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 2
        listStack.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(listStack)
        scrollView.documentView = documentView
        self.listStack = listStack

        let emptyLabel = NSTextField(labelWithString: AppStrings.text(.clipboardEmpty))
        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(emptyLabel)
        self.emptyLabel = emptyLabel

        let messageLabel = NSTextField(wrappingLabelWithString: "")
        messageLabel.font = .systemFont(ofSize: 11)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.maximumNumberOfLines = 2
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        messageLabel.isHidden = true
        root.addSubview(messageLabel)
        self.messageLabel = messageLabel

        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            searchField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            searchField.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            searchField.heightAnchor.constraint(equalToConstant: 30),

            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),
            scrollView.bottomAnchor.constraint(equalTo: messageLabel.topAnchor, constant: -8),

            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            documentView.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.heightAnchor),
            listStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            listStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            listStack.topAnchor.constraint(equalTo: documentView.topAnchor),
            listStack.bottomAnchor.constraint(lessThanOrEqualTo: documentView.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),

            messageLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            messageLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            messageLabel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            messageLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 14)
        ])
        return panel
    }

    private func applySearch() {
        let query = searchField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        visibleRecords = ClipboardArchiveSearch.filter(records, query: query)
        selectedIndex = min(max(selectedIndex, 0), max(visibleRecords.count - 1, 0))
        rebuildRows()
    }

    private func rebuildRows() {
        guard let listStack else {
            return
        }
        listStack.removeAllArrangedSubviews()
        rowViews.removeAll()
        emptyLabel?.isHidden = !visibleRecords.isEmpty

        for (index, record) in visibleRecords.enumerated() {
            let row = ClipboardPaletteRowView(record: record)
            row.isSelected = index == selectedIndex
            row.onChoose = { [weak self] modifiers in
                guard let self else {
                    return
                }
                self.selectedIndex = self.visibleRecords.firstIndex(where: { $0.id == record.id }) ?? 0
                self.onChoose?(record.id, modifiers.contains(.option), self.sourceApplication)
            }
            row.onDelete = { [weak self] in
                self?.onDelete?(record.id)
            }
            row.onHoverChanged = { [weak self] hovering in
                self?.handleHover(recordID: record.id, hovering: hovering)
            }
            listStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
            rowViews[record.id] = row
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        switch Int(event.keyCode) {
        case kVK_UpArrow:
            moveSelection(by: -1)
            return true
        case kVK_DownArrow:
            moveSelection(by: 1)
            return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            chooseSelected(autoPaste: event.modifierFlags.contains(.option))
            return true
        case kVK_Escape:
            hide()
            return true
        case kVK_Delete where event.modifierFlags.contains(.option),
             kVK_ForwardDelete where event.modifierFlags.contains(.option):
            deleteSelected()
            return true
        default:
            return false
        }
    }

    private func moveSelection(by delta: Int) {
        guard !visibleRecords.isEmpty else {
            return
        }
        selectedIndex = (selectedIndex + delta + visibleRecords.count) % visibleRecords.count
        for (index, record) in visibleRecords.enumerated() {
            rowViews[record.id]?.isSelected = index == selectedIndex
        }
        rowViews[visibleRecords[selectedIndex].id]?.scrollToVisible(
            rowViews[visibleRecords[selectedIndex].id]?.bounds ?? .zero
        )
        if detailPanel?.isVisible == true {
            presentPreview(for: visibleRecords[selectedIndex].id)
        }
    }

    private func chooseSelected(autoPaste: Bool) {
        guard visibleRecords.indices.contains(selectedIndex) else {
            return
        }
        onChoose?(visibleRecords[selectedIndex].id, autoPaste, sourceApplication)
    }

    private func deleteSelected() {
        guard visibleRecords.indices.contains(selectedIndex) else {
            return
        }
        onDelete?(visibleRecords[selectedIndex].id)
    }

    private func position(_ panel: NSPanel) {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let visibleFrame = screen?.visibleFrame else {
            panel.center()
            return
        }
        let targetSize = ClipboardPaletteLayout.historySize(in: visibleFrame)
        panel.contentMaxSize = targetSize
        panel.setContentSize(targetSize)
        panel.setFrameOrigin(ClipboardPalettePlacement.origin(
            cursor: mouseLocation,
            panelSize: targetSize,
            visibleFrame: visibleFrame
        ))
    }

    private func handleHover(recordID: UUID, hovering: Bool) {
        if hovering {
            guard let index = visibleRecords.firstIndex(where: { $0.id == recordID }) else {
                return
            }
            selectedIndex = index
            for (rowIndex, record) in visibleRecords.enumerated() {
                rowViews[record.id]?.isSelected = rowIndex == selectedIndex
            }

            if detailPanel?.isVisible == true {
                presentPreview(for: recordID)
            } else {
                schedulePreview(for: recordID)
            }
        } else if pendingPreviewRecordID == recordID {
            cancelPendingPreview()
        }
    }

    private func schedulePreview(for recordID: UUID) {
        cancelPendingPreview()
        pendingPreviewRecordID = recordID
        previewRequestGeneration += 1
        let generation = previewRequestGeneration
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.previewRequestGeneration == generation,
                  self.pendingPreviewRecordID == recordID
            else {
                return
            }
            self.pendingPreviewRecordID = nil
            self.previewWorkItem = nil
            self.presentPreview(for: recordID)
        }
        previewWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.hoverPreviewDelay,
            execute: workItem
        )
    }

    private func presentPreview(for recordID: UUID) {
        cancelPendingPreview()
        guard isVisible,
              visibleRecords.contains(where: { $0.id == recordID }),
              let content = onPreviewRequest?(recordID),
              let panel
        else {
            dismissPreview()
            return
        }
        let detailPanel = detailPanel ?? ClipboardInspectorPanel()
        self.detailPanel = detailPanel
        previewedRecordID = recordID
        detailPanel.present(content, beside: panel)
    }

    private func cancelPendingPreview() {
        previewRequestGeneration += 1
        previewWorkItem?.cancel()
        previewWorkItem = nil
        pendingPreviewRecordID = nil
    }

    private func dismissPreview() {
        cancelPendingPreview()
        detailPanel?.dismiss()
        previewedRecordID = nil
    }

    private func installMouseMonitors() {
        removeMouseMonitors()
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in
                self?.hide()
            }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self, event.window !== self.panel else {
                return event
            }
            self.hide()
            return event
        }
    }

    private func removeMouseMonitors() {
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
        }
    }
}

enum ClipboardArchiveSearch {
    static func filter(
        _ records: [ClipboardHistoryRecord],
        query: String
    ) -> [ClipboardHistoryRecord] {
        let normalizedQuery = normalized(query)
        guard !normalizedQuery.isEmpty else {
            return records
        }
        return records.filter { record in
            normalized(record.summary).contains(normalizedQuery)
                || normalized(record.searchableText).contains(normalizedQuery)
                || normalized(record.sourceApplicationName).contains(normalizedQuery)
        }
    }

    private static func normalized(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: .current
        )
    }
}

private final class ClipboardPaletteWindow: NSPanel {
    var onKeyDown: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool {
        true
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, onKeyDown?(event) == true {
            return
        }
        super.sendEvent(event)
    }
}

@MainActor
final class ClipboardPaletteRowView: NSView {
    var onChoose: ((NSEvent.ModifierFlags) -> Void)?
    var onDelete: (() -> Void)?
    var onHoverChanged: ((Bool) -> Void)?

    var isSelected = false {
        didSet {
            updateBackground()
        }
    }

    private let record: ClipboardHistoryRecord
    private let backgroundLayer = CALayer()
    private var hoverTrackingArea: NSTrackingArea?

    init(record: ClipboardHistoryRecord) {
        self.record = record
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.insertSublayer(backgroundLayer, at: 0)
        backgroundLayer.cornerRadius = 6

        let iconView = NSImageView()
        iconView.image = ClipboardSourceArtwork.icon(
            bundleIdentifier: record.sourceBundleIdentifier
        )
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        let summaryLabel = NSTextField(labelWithString: record.summary)
        summaryLabel.font = .systemFont(ofSize: 13, weight: .medium)
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.maximumNumberOfLines = 2
        summaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let metadataLabel = NSTextField(labelWithString: Self.metadata(for: record))
        metadataLabel.font = .systemFont(ofSize: 11)
        metadataLabel.textColor = .secondaryLabelColor
        metadataLabel.lineBreakMode = .byTruncatingTail
        metadataLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let labels = NSStackView(views: [summaryLabel, metadataLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 3
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        labels.translatesAutoresizingMaskIntoConstraints = false
        addSubview(labels)

        var leadingView: NSView = iconView
        if let thumbnailData = record.thumbnailData,
           let image = NSImage(data: thumbnailData) {
            let thumbnail = NSImageView(image: image)
            thumbnail.imageScaling = .scaleProportionallyUpOrDown
            thumbnail.wantsLayer = true
            thumbnail.layer?.cornerRadius = 4
            thumbnail.layer?.masksToBounds = true
            thumbnail.translatesAutoresizingMaskIntoConstraints = false
            addSubview(thumbnail)
            NSLayoutConstraint.activate([
                thumbnail.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
                thumbnail.centerYAnchor.constraint(equalTo: centerYAnchor),
                thumbnail.widthAnchor.constraint(equalToConstant: 54),
                thumbnail.heightAnchor.constraint(equalToConstant: 46)
            ])
            leadingView = thumbnail
        }

        let deleteButton = NSButton(
            image: NSImage(
                systemSymbolName: "trash",
                accessibilityDescription: AppStrings.text(.clipboardDelete)
            ) ?? NSImage(),
            target: self,
            action: #selector(deleteRecord(_:))
        )
        deleteButton.isBordered = false
        deleteButton.toolTip = AppStrings.text(.clipboardDelete)
        deleteButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(deleteButton)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 66),
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 28),
            iconView.heightAnchor.constraint(equalToConstant: 28),

            labels.leadingAnchor.constraint(equalTo: leadingView.trailingAnchor, constant: 10),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: deleteButton.leadingAnchor, constant: -10),

            deleteButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            deleteButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            deleteButton.widthAnchor.constraint(equalToConstant: 28),
            deleteButton.heightAnchor.constraint(equalToConstant: 28)
        ])
        updateBackground()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        backgroundLayer.frame = bounds
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        onChoose?(event.modifierFlags)
    }

    @objc private func deleteRecord(_ sender: NSButton) {
        onDelete?()
    }

    private func updateBackground() {
        backgroundLayer.backgroundColor = isSelected
            ? OmniDockTheme.palette(for: effectiveAppearance).selection.withAlphaComponent(0.22).cgColor
            : NSColor.clear.cgColor
    }

    private static func metadata(for record: ClipboardHistoryRecord) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        let relativeDate = formatter.localizedString(for: record.lastCopiedAt, relativeTo: Date())
        let count = record.copyCount > 1 ? " · ×\(record.copyCount)" : ""
        return "\(record.sourceApplicationName) · \(relativeDate)\(count)"
    }
}

@MainActor
final class ClipboardArchiveSettingsRowView: NSView {
    var onCopy: (() -> Void)?
    var onDelete: (() -> Void)?

    init(record: ClipboardHistoryRecord) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let iconView = NSImageView()
        iconView.image = ClipboardSourceArtwork.icon(
            bundleIdentifier: record.sourceBundleIdentifier
        )
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        let summary = NSTextField(labelWithString: record.summary)
        summary.font = .systemFont(ofSize: 13, weight: .medium)
        summary.lineBreakMode = .byTruncatingTail
        let source = NSTextField(labelWithString: record.sourceApplicationName)
        source.font = .systemFont(ofSize: 11)
        source.textColor = .secondaryLabelColor
        source.lineBreakMode = .byTruncatingTail
        let labels = NSStackView(views: [summary, source])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        labels.translatesAutoresizingMaskIntoConstraints = false
        addSubview(labels)

        let copyButton = NSButton(
            image: NSImage(
                systemSymbolName: "doc.on.doc",
                accessibilityDescription: AppStrings.text(.clipboardCopy)
            ) ?? NSImage(),
            target: self,
            action: #selector(copyRecord(_:))
        )
        copyButton.isBordered = false
        copyButton.toolTip = AppStrings.text(.clipboardCopy)
        copyButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(copyButton)

        let deleteButton = NSButton(
            image: NSImage(
                systemSymbolName: "trash",
                accessibilityDescription: AppStrings.text(.clipboardDelete)
            ) ?? NSImage(),
            target: self,
            action: #selector(deleteRecord(_:))
        )
        deleteButton.isBordered = false
        deleteButton.toolTip = AppStrings.text(.clipboardDelete)
        deleteButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(deleteButton)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 48),
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 28),
            iconView.heightAnchor.constraint(equalToConstant: 28),

            labels.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: copyButton.leadingAnchor, constant: -10),

            copyButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            copyButton.widthAnchor.constraint(equalToConstant: 28),
            copyButton.heightAnchor.constraint(equalToConstant: 28),
            deleteButton.leadingAnchor.constraint(equalTo: copyButton.trailingAnchor, constant: 4),
            deleteButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            deleteButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            deleteButton.widthAnchor.constraint(equalToConstant: 28),
            deleteButton.heightAnchor.constraint(equalToConstant: 28)
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    @objc private func copyRecord(_ sender: NSButton) {
        onCopy?()
    }

    @objc private func deleteRecord(_ sender: NSButton) {
        onDelete?()
    }

}

@MainActor
enum ClipboardSourceArtwork {
    static func icon(bundleIdentifier: String?) -> NSImage? {
        guard let bundleIdentifier,
              let URL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        else {
            return NSImage(
                systemSymbolName: "doc.on.clipboard",
                accessibilityDescription: nil
            )
        }
        return NSWorkspace.shared.icon(forFile: URL.path)
    }
}
