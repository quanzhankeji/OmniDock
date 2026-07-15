import AppKit

typealias PreviewWindowFocusRequest = (pid_t, String?, CGWindowID?) -> Void
typealias PreviewWindowCloseRequest = (
    pid_t,
    String?,
    CGWindowID?,
    @escaping (Bool) -> Void
) -> Void

@MainActor
public final class PreviewPanelController {
    var onWindowClosed: ((PreviewWindowInfo) -> Void)?
    var onPreviewLifecycleEndRequested: (() -> Void)?

    private let requestWindowFocus: PreviewWindowFocusRequest
    private let requestWindowClose: PreviewWindowCloseRequest
    private var panel: NSPanel?
    private var thumbnailViews: [CGWindowID: PreviewThumbnailView] = [:]
    private var thumbnailViewsByIdentity: [PreviewWindowIdentity: PreviewThumbnailView] = [:]
    private var thumbnailSizeConstraints: [PreviewWindowIdentity: (width: NSLayoutConstraint, height: NSLayoutConstraint)] = [:]
    private weak var scrollView: PreviewHorizontalScrollView?
    private weak var scrollDocumentView: NSView?
    private weak var stackView: NSStackView?
    private var messageField: NSTextField?
    private var transientMessageWorkItem: DispatchWorkItem?
    private var currentTarget: DockAppTarget?
    private var currentWindows: [PreviewWindowInfo] = []
    private var pendingWindowCloseIdentities: Set<PreviewWindowIdentity> = []
    private var targetGeneration: UInt64 = 0

    public convenience init(windowControlService: WindowControlService) {
        self.init(
            requestWindowFocus: { processIdentifier, title, windowID in
                windowControlService.focusWindow(
                    processIdentifier: processIdentifier,
                    title: title,
                    windowID: windowID
                )
            },
            requestWindowClose: { processIdentifier, title, windowID, completion in
                windowControlService.closeWindow(
                    processIdentifier: processIdentifier,
                    title: title,
                    windowID: windowID,
                    completion: completion
                )
            }
        )
    }

    init(
        requestWindowFocus: @escaping PreviewWindowFocusRequest,
        requestWindowClose: @escaping PreviewWindowCloseRequest
    ) {
        self.requestWindowFocus = requestWindowFocus
        self.requestWindowClose = requestWindowClose
    }

    public func show(target: DockAppTarget, windows: [PreviewWindowInfo], message: String?) {
        if currentTarget?.isSameDockTile(as: target) != true {
            targetGeneration &+= 1
        }
        currentTarget = target
        let visibleWindows = windows
        currentWindows = visibleWindows
        let frame = panelFrame(target: target, windows: visibleWindows)

        let panel = panel ?? makePanel()
        self.panel = panel
        panel.setFrame(frame, display: true)
        rebuildContent(target: target, windows: visibleWindows, message: message)
        panel.orderFrontRegardless()
    }

    func update(target: DockAppTarget, windows: [PreviewWindowInfo], message: String?) {
        guard currentTarget?.isSameDockTile(as: target) == true,
              !currentWindows.isEmpty,
              !windows.isEmpty,
              let panel,
              let stackView
        else {
            show(target: target, windows: windows, message: message)
            return
        }

        currentTarget = target
        let identities = windows.map(PreviewWindowIdentity.init)
        let retainedIdentities = Set(identities)

        let removedIdentities = thumbnailViewsByIdentity.keys.filter { !retainedIdentities.contains($0) }
        for identity in removedIdentities {
            guard let tile = thumbnailViewsByIdentity.removeValue(forKey: identity) else {
                continue
            }
            stackView.removeArrangedSubview(tile)
            tile.removeFromSuperview()
            thumbnailSizeConstraints[identity] = nil
        }

        for arrangedSubview in stackView.arrangedSubviews {
            stackView.removeArrangedSubview(arrangedSubview)
        }

        for (identity, info) in zip(identities, windows) {
            let tile: PreviewThumbnailView
            if let existingTile = thumbnailViewsByIdentity[identity] {
                tile = existingTile
                if tile.update(info: info),
                   let constraints = thumbnailSizeConstraints[identity] {
                    constraints.width.constant = tile.preferredTileSize.width
                    constraints.height.constant = tile.preferredTileSize.height
                }
            } else {
                tile = makeThumbnail(info: info)
            }
            stackView.addArrangedSubview(tile)
        }

        currentWindows = windows
        rebuildWindowIDIndex()
        panel.setFrame(panelFrame(target: target, windows: windows), display: true)
        layoutScrollableContent()
    }

    public func updatePreview(windowID: CGWindowID, image: NSImage) {
        guard let tile = thumbnailViews[windowID] else {
            return
        }

        let didResize = tile.update(image: image)
        guard didResize, let constraints = thumbnailSizeConstraints[PreviewWindowIdentity(tile.info)] else {
            return
        }

        constraints.width.constant = tile.preferredTileSize.width
        constraints.height.constant = tile.preferredTileSize.height
        resizePanelForRemainingThumbnails(animated: false)
    }

    public func showTransientMessage(_ message: String) {
        guard let contentView = panel?.contentView else {
            return
        }

        if currentWindows.isEmpty {
            messageField?.stringValue = message
            return
        }

        transientMessageWorkItem?.cancel()
        let field = messageField ?? makeTransientMessageField(in: contentView)
        field.stringValue = message
        layoutTransientMessageField(field, in: contentView)
        field.isHidden = false
        messageField = field

        let workItem = DispatchWorkItem { [weak self, weak field] in
            guard let self, let field, self.messageField === field else {
                return
            }
            field.removeFromSuperview()
            self.messageField = nil
            self.transientMessageWorkItem = nil
        }
        transientMessageWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: workItem)
    }

    public func hide() {
        targetGeneration &+= 1
        thumbnailViews = [:]
        thumbnailViewsByIdentity = [:]
        thumbnailSizeConstraints = [:]
        scrollView = nil
        scrollDocumentView = nil
        stackView = nil
        transientMessageWorkItem?.cancel()
        transientMessageWorkItem = nil
        messageField = nil
        currentTarget = nil
        currentWindows = []
        panel?.orderOut(nil)
        panel?.contentView = nil
    }

    public var frame: CGRect? {
        guard let panel, panel.isVisible else {
            return nil
        }
        return panel.frame
    }

    var hasInstalledContentView: Bool {
        panel?.contentView != nil
    }

    public func contains(point: CGPoint) -> Bool {
        guard let panel, panel.isVisible else {
            return false
        }
        return panel.frame.insetBy(dx: -8, dy: -8).contains(point)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        panel.hidesOnDeactivate = false
        return panel
    }

    private func rebuildContent(target: DockAppTarget, windows: [PreviewWindowInfo], message: String?) {
        thumbnailViews = [:]
        thumbnailViewsByIdentity = [:]
        thumbnailSizeConstraints = [:]
        scrollView = nil
        scrollDocumentView = nil
        stackView = nil
        transientMessageWorkItem?.cancel()
        transientMessageWorkItem = nil
        messageField = nil

        let root = PreviewPanelRootView(frame: panel?.contentView?.bounds ?? .zero)
        root.autoresizingMask = [.width, .height]

        if windows.isEmpty {
            let label = NSTextField(labelWithString: message ?? AppStrings.text(.previewNoWindows))
            label.alignment = .center
            label.font = .systemFont(ofSize: 13, weight: .medium)
            label.textColor = .labelColor
            label.maximumNumberOfLines = 3
            label.frame = root.bounds.insetBy(dx: 16, dy: 16)
            label.autoresizingMask = [.width, .height]
            root.addSubview(label)
            messageField = label
        } else {
            let scrollView = PreviewHorizontalScrollView()
            scrollView.frame = root.bounds
            scrollView.autoresizingMask = [.width, .height]
            scrollView.borderType = .noBorder
            scrollView.drawsBackground = false
            scrollView.hasHorizontalScroller = false
            scrollView.hasVerticalScroller = false
            scrollView.autohidesScrollers = true
            scrollView.horizontalScrollElasticity = .allowed
            scrollView.verticalScrollElasticity = .none
            scrollView.allowsMagnification = false

            let documentView = PreviewScrollDocumentView()
            documentView.wantsLayer = true
            documentView.layer?.backgroundColor = NSColor.clear.cgColor
            documentView.onHorizontalDrag = { [weak self] deltaX in
                self?.scrollPreviewContent(deltaX: deltaX)
            }
            scrollView.documentView = documentView

            let stack = NSStackView()
            stack.orientation = .horizontal
            stack.spacing = PreviewLayoutCalculator.gap
            stack.alignment = .centerY
            stack.distribution = .fill
            stack.autoresizingMask = [.height]

            for info in windows {
                let tile = makeThumbnail(info: info)
                stack.addArrangedSubview(tile)
            }
            documentView.addSubview(stack)
            root.addSubview(scrollView)
            self.scrollView = scrollView
            self.scrollDocumentView = documentView
            self.stackView = stack
            layoutScrollableContent()
        }

        panel?.contentView = root
    }

    private func makeTransientMessageField(in contentView: NSView) -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.alignment = .center
        field.font = .systemFont(ofSize: 12, weight: .medium)
        field.textColor = .white
        field.lineBreakMode = .byTruncatingTail
        field.wantsLayer = true
        field.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
        field.layer?.cornerRadius = 6
        contentView.addSubview(field, positioned: .above, relativeTo: nil)
        return field
    }

    private func layoutTransientMessageField(_ field: NSTextField, in contentView: NSView) {
        let maximumWidth = max(0, contentView.bounds.width - 24)
        let width = min(maximumWidth, max(160, field.fittingSize.width + 20))
        field.frame = CGRect(
            x: contentView.bounds.midX - width / 2,
            y: 12,
            width: width,
            height: 24
        )
        field.autoresizingMask = [.minXMargin, .maxXMargin, .maxYMargin]
    }

    func focusWindowAndHidePreview(_ info: PreviewWindowInfo) {
        onPreviewLifecycleEndRequested?()
        hide()
        requestWindowFocus(info.processIdentifier, info.title, info.windowID)
    }

    func closeWindowFromPreview(_ info: PreviewWindowInfo) {
        let identity = PreviewWindowIdentity(info)
        guard let target = currentTarget,
              pendingWindowCloseIdentities.insert(identity).inserted
        else {
            return
        }
        let requestTargetIdentifier = target.dockTileIdentifier
        let requestGeneration = targetGeneration

        requestWindowClose(
            info.processIdentifier,
            info.title,
            info.windowID
        ) { [weak self] didDisappear in
            Task { @MainActor [weak self] in
                self?.completeWindowClose(
                    info,
                    identity: identity,
                    didDisappear: didDisappear,
                    requestTargetIdentifier: requestTargetIdentifier,
                    requestGeneration: requestGeneration
                )
            }
        }
    }

    var displayedWindowCount: Int {
        currentWindows.count
    }

    var displayedMessage: String? {
        guard messageField?.isHidden != true else {
            return nil
        }
        return messageField?.stringValue
    }

    func isWindowClosePending(_ info: PreviewWindowInfo) -> Bool {
        pendingWindowCloseIdentities.contains(PreviewWindowIdentity(info))
    }

    private func completeWindowClose(
        _ info: PreviewWindowInfo,
        identity: PreviewWindowIdentity,
        didDisappear: Bool,
        requestTargetIdentifier: String,
        requestGeneration: UInt64
    ) {
        guard pendingWindowCloseIdentities.remove(identity) != nil else {
            return
        }
        let belongsToCurrentPresentation = requestGeneration == targetGeneration
            && currentTarget?.dockTileIdentifier == requestTargetIdentifier
            && currentWindows.contains { PreviewWindowIdentity($0) == identity }
        guard didDisappear else {
            if belongsToCurrentPresentation {
                showTransientMessage(AppStrings.text(.previewCloseFailed))
            }
            return
        }

        onWindowClosed?(info)
        if belongsToCurrentPresentation {
            removeThumbnail(for: info)
        }
    }

    private func removeThumbnail(for info: PreviewWindowInfo) {
        let identity = PreviewWindowIdentity(info)
        guard let tile = thumbnailViewsByIdentity.removeValue(forKey: identity) else {
            return
        }

        if let windowID = info.windowID {
            thumbnailViews[windowID] = nil
        }
        thumbnailSizeConstraints[identity] = nil
        currentWindows.removeAll { PreviewWindowIdentity($0) == identity }
        if let stack = tile.superview as? NSStackView {
            stack.removeArrangedSubview(tile)
        }
        tile.removeFromSuperview()

        if thumbnailViewsByIdentity.isEmpty {
            hide()
        } else {
            resizePanelForRemainingThumbnails(animated: true)
        }
    }

    private func resizePanelForRemainingThumbnails(animated: Bool) {
        guard let panel, let currentTarget else {
            return
        }

        let frame = panelFrame(target: currentTarget, windows: currentWindows)
        panel.setFrame(frame, display: true, animate: animated)
        layoutScrollableContent()
        panel.contentView?.needsLayout = true
    }

    private func layoutScrollableContent() {
        guard let panel,
              let scrollView,
              let scrollDocumentView,
              let stackView
        else {
            return
        }

        let tileSizes = currentWindows.map { window in
            thumbnailViewsByIdentity[PreviewWindowIdentity(window)]?.preferredTileSize
                ?? PreviewLayoutCalculator.tileSize(for: window.frame)
        }
        let contentWidth = PreviewLayoutCalculator.contentWidth(for: tileSizes)
        let panelBounds = CGRect(origin: .zero, size: panel.frame.size)
        let documentSize = CGSize(
            width: max(contentWidth, panelBounds.width),
            height: panelBounds.height
        )
        scrollView.frame = panelBounds
        scrollDocumentView.frame = CGRect(origin: .zero, size: documentSize)
        stackView.frame = CGRect(
            x: PreviewLayoutCalculator.margin,
            y: PreviewLayoutCalculator.margin,
            width: max(0, documentSize.width - PreviewLayoutCalculator.margin * 2),
            height: max(0, documentSize.height - PreviewLayoutCalculator.margin * 2)
        )
        clampScrollPosition()
    }

    private func scrollPreviewContent(deltaX: CGFloat) {
        guard let scrollView else {
            return
        }

        let currentOrigin = scrollView.contentView.bounds.origin
        scrollView.contentView.scroll(to: CGPoint(
            x: currentOrigin.x - deltaX,
            y: currentOrigin.y
        ))
        clampScrollPosition()
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func clampScrollPosition() {
        guard let scrollView,
              let documentView = scrollView.documentView
        else {
            return
        }

        let maxX = max(0, documentView.frame.width - scrollView.contentView.bounds.width)
        let currentOrigin = scrollView.contentView.bounds.origin
        let clampedOrigin = CGPoint(
            x: min(max(0, currentOrigin.x), maxX),
            y: currentOrigin.y
        )
        guard clampedOrigin != currentOrigin else {
            return
        }

        scrollView.contentView.scroll(to: clampedOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func panelFrame(target: DockAppTarget, windows: [PreviewWindowInfo]) -> CGRect {
        let anchor = target.previewAnchorPoint
        let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor) }) ?? NSScreen.main
        let screenFrame = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
        let orientation = DockGeometry().inferredOrientation(
            dockItemFrame: target.dockItemFrame,
            anchor: anchor,
            screenFrame: screen?.frame ?? screenFrame
        )
        return PreviewLayoutCalculator.panelFrame(
            tileSizes: windows.map { window in
                thumbnailViewsByIdentity[PreviewWindowIdentity(window)]?.preferredTileSize
                    ?? PreviewLayoutCalculator.tileSize(for: window.frame)
            },
            anchor: anchor,
            screenFrame: screenFrame,
            orientation: orientation
        )
    }

    private func makeThumbnail(info: PreviewWindowInfo) -> PreviewThumbnailView {
        let identity = PreviewWindowIdentity(info)
        let tile = PreviewThumbnailView(info: info)
        tile.translatesAutoresizingMaskIntoConstraints = false
        tile.onClick = { [weak self] info in
            self?.focusWindowAndHidePreview(info)
        }
        tile.onHorizontalDrag = { [weak self] deltaX in
            self?.scrollPreviewContent(deltaX: deltaX)
        }
        tile.onFileDragEntered = { [weak self] info in
            self?.focusWindowAndHidePreview(info)
        }
        tile.onClose = { [weak self] info in
            self?.closeWindowFromPreview(info)
        }
        thumbnailViewsByIdentity[identity] = tile
        if let windowID = info.windowID {
            thumbnailViews[windowID] = tile
        }

        let tileSize = tile.preferredTileSize
        let widthConstraint = tile.widthAnchor.constraint(equalToConstant: tileSize.width)
        let heightConstraint = tile.heightAnchor.constraint(equalToConstant: tileSize.height)
        thumbnailSizeConstraints[identity] = (widthConstraint, heightConstraint)
        NSLayoutConstraint.activate([widthConstraint, heightConstraint])
        return tile
    }

    private func rebuildWindowIDIndex() {
        thumbnailViews = Dictionary(uniqueKeysWithValues: currentWindows.compactMap { info in
            guard let windowID = info.windowID,
                  let tile = thumbnailViewsByIdentity[PreviewWindowIdentity(info)]
            else {
                return nil
            }
            return (windowID, tile)
        })
    }
}

final class PreviewPanelRootView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool {
        false
    }
}

final class PreviewHorizontalScrollView: NSScrollView {
    override var isOpaque: Bool {
        false
    }
}

final class PreviewScrollDocumentView: NSView {
    var onHorizontalDrag: ((CGFloat) -> Void)?

    private static let dragThreshold: CGFloat = 5
    private var mouseDownLocationInWindow: CGPoint?
    private var lastDragLocationInWindow: CGPoint?
    private var isDragging = false

    override func mouseDown(with event: NSEvent) {
        mouseDownLocationInWindow = event.locationInWindow
        lastDragLocationInWindow = event.locationInWindow
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let mouseDownLocationInWindow,
              let lastDragLocationInWindow
        else {
            return
        }

        let totalDeltaX = event.locationInWindow.x - mouseDownLocationInWindow.x
        let totalDeltaY = event.locationInWindow.y - mouseDownLocationInWindow.y
        if !isDragging {
            guard hypot(totalDeltaX, totalDeltaY) >= Self.dragThreshold else {
                return
            }
            isDragging = true
        }

        let deltaX = event.locationInWindow.x - lastDragLocationInWindow.x
        self.lastDragLocationInWindow = event.locationInWindow
        onHorizontalDrag?(deltaX)
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownLocationInWindow = nil
        lastDragLocationInWindow = nil
        isDragging = false
    }

    override var isOpaque: Bool {
        false
    }
}
