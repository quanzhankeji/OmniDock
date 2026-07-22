import AppKit

typealias PreviewWindowFocusRequest = (pid_t, String?, CGWindowID?) -> Void
typealias PreviewWindowCloseRequest = (
    pid_t,
    String?,
    CGWindowID?,
    @escaping (Bool) -> Void
) -> Void
typealias PreviewApplicationQuitRequest = (pid_t, @escaping (Bool) -> Void) -> Bool

enum WindowCyclePresentationPolicy {
    static func needsGridRebuild(
        current: [PreviewWindowInfo],
        replacement: [PreviewWindowInfo]
    ) -> Bool {
        guard current.count == replacement.count else {
            return true
        }
        return zip(current, replacement).contains { currentWindow, replacementWindow in
            let currentIdentity = PreviewWindowIdentity(currentWindow)
            let replacementIdentity = PreviewWindowIdentity(replacementWindow)
            return currentIdentity != replacementIdentity
                || currentWindow.frame != replacementWindow.frame
        }
    }
}

@MainActor
public final class PreviewPanelController {
    var onWindowClosed: ((PreviewWindowInfo) -> Void)?
    var onPreviewLifecycleEndRequested: (() -> Void)?
    var onApplicationQuitRequested: ((pid_t) -> Void)?
    var onCommandTabButtonTargetsChanged: (() -> Void)?

    private struct PresentationHandler {
        let onLifecycleEndRequested: () -> Void
        let onWindowClosed: (PreviewWindowInfo) -> Void
        let onApplicationQuitRequested: (pid_t) -> Void
    }

    private let requestWindowFocus: PreviewWindowFocusRequest
    private let requestWindowClose: PreviewWindowCloseRequest
    private let requestApplicationQuit: PreviewApplicationQuitRequest
    private var panel: NSPanel?
    private var thumbnailViews: [CGWindowID: PreviewThumbnailView] = [:]
    private var thumbnailViewsByIdentity: [PreviewWindowIdentity: PreviewThumbnailView] = [:]
    private var thumbnailSizeConstraints: [PreviewWindowIdentity: (width: NSLayoutConstraint, height: NSLayoutConstraint)] = [:]
    private weak var scrollView: PreviewHorizontalScrollView?
    private weak var scrollDocumentView: NSView?
    private weak var stackView: NSStackView?
    private weak var gridView: NSGridView?
    private var gridNeedsInitialTopAlignment = false
    private var messageField: NSTextField?
    private var transientMessageWorkItem: DispatchWorkItem?
    private var currentTarget: DockAppTarget?
    private var currentWindows: [PreviewWindowInfo] = []
    private var selectedWindowIdentity: PreviewWindowIdentity?
    private var pendingWindowCloseIdentities: Set<PreviewWindowIdentity> = []
    private var pendingApplicationQuitProcessIdentifiers: Set<pid_t> = []
    private var targetGeneration: UInt64 = 0
    private var themeObserver: NSObjectProtocol?

    private var presentationHandlers: [PreviewAnchorKind: PresentationHandler] = [:]

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
            },
            requestApplicationQuit: { processIdentifier, completion in
                windowControlService.quitApplication(
                    processIdentifier: processIdentifier,
                    completion: completion
                )
            }
        )
    }

    init(
        requestWindowFocus: @escaping PreviewWindowFocusRequest,
        requestWindowClose: @escaping PreviewWindowCloseRequest,
        requestApplicationQuit: @escaping PreviewApplicationQuitRequest = { _, _ in false }
    ) {
        self.requestWindowFocus = requestWindowFocus
        self.requestWindowClose = requestWindowClose
        self.requestApplicationQuit = requestApplicationQuit
        themeObserver = NotificationCenter.default.addObserver(
            forName: OmniDockTheme.changedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshTheme()
            }
        }
    }

    deinit {
        if let themeObserver {
            NotificationCenter.default.removeObserver(themeObserver)
        }
    }

    func setPresentationHandler(
        for anchorKind: PreviewAnchorKind,
        onLifecycleEndRequested: @escaping () -> Void,
        onWindowClosed: @escaping (PreviewWindowInfo) -> Void,
        onApplicationQuitRequested: @escaping (pid_t) -> Void = { _ in }
    ) {
        presentationHandlers[anchorKind] = PresentationHandler(
            onLifecycleEndRequested: onLifecycleEndRequested,
            onWindowClosed: onWindowClosed,
            onApplicationQuitRequested: onApplicationQuitRequested
        )
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
        OmniDockTheme.applyCurrentAppearance(to: panel)
        panel.setFrame(frame, display: true)
        rebuildContent(target: target, windows: visibleWindows, message: message)
        panel.orderFrontRegardless()
        notifyCommandTabButtonTargetsChanged()
    }

    func update(target: DockAppTarget, windows: [PreviewWindowInfo], message: String?) {
        guard currentTarget?.isSameDockTile(as: target) == true,
              !currentWindows.isEmpty,
              !windows.isEmpty,
              let panel
        else {
            show(target: target, windows: windows, message: message)
            return
        }

        if target.previewAnchorKind == .windowCycle {
            updateWindowCycle(
                target: target,
                windows: windows,
                message: message,
                panel: panel
            )
            return
        }

        guard let stackView else {
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
        applySelection()
        panel.setFrame(panelFrame(target: target, windows: windows), display: true)
        layoutScrollableContent()
        notifyCommandTabButtonTargetsChanged()
    }

    private func updateWindowCycle(
        target: DockAppTarget,
        windows: [PreviewWindowInfo],
        message: String?,
        panel: NSPanel
    ) {
        guard let gridView,
              WindowCyclePresentationPolicy.needsGridRebuild(
                current: currentWindows,
                replacement: windows
              ) == false
        else {
            show(target: target, windows: windows, message: message)
            return
        }

        currentTarget = target
        currentWindows = windows
        for window in windows {
            let identity = PreviewWindowIdentity(window)
            guard let tile = thumbnailViewsByIdentity[identity] else {
                show(target: target, windows: windows, message: message)
                return
            }
            _ = tile.update(info: window)
        }

        // The grid's dimensions are stable when identities and source frames are
        // unchanged. Avoid rebuilding every card during background reconciliation.
        gridView.needsLayout = true
        rebuildWindowIDIndex()
        applySelection()
        panel.setFrame(panelFrame(target: target, windows: windows), display: true)
        layoutScrollableContent()
        notifyCommandTabButtonTargetsChanged()
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

    func setSelectedWindow(_ info: PreviewWindowInfo?) {
        let selectedIdentity = info.map(PreviewWindowIdentity.init)
        guard selectedWindowIdentity != selectedIdentity else {
            return
        }
        selectedWindowIdentity = selectedIdentity
        applySelection()
        scrollSelectedWindowIntoViewIfNeeded()
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
        gridView = nil
        gridNeedsInitialTopAlignment = false
        transientMessageWorkItem?.cancel()
        transientMessageWorkItem = nil
        messageField = nil
        currentTarget = nil
        currentWindows = []
        selectedWindowIdentity = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        notifyCommandTabButtonTargetsChanged()
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

    func commandTabButtonHitTargets() -> [PreviewThumbnailActionHitTarget] {
        guard currentTarget?.previewAnchorKind == .commandTab,
              let panel,
              panel.isVisible
        else {
            return []
        }

        panel.contentView?.layoutSubtreeIfNeeded()
        return thumbnailViewsByIdentity.values.flatMap { tile in
            tile.actionButtonHitTargets(in: panel)
        }
    }

    func performCommandTabAction(_ action: PreviewThumbnailAction) {
        guard currentTarget?.previewAnchorKind == .commandTab else {
            return
        }

        switch action {
        case let .closeWindow(identity):
            guard let window = currentWindows.first(where: {
                PreviewWindowIdentity($0) == identity
            }) else {
                return
            }
            closeWindowFromPreview(window)
        case let .quitApplication(processIdentifier):
            guard let window = currentWindows.first(where: {
                $0.processIdentifier == processIdentifier
            }) else {
                return
            }
            quitApplicationFromPreview(window)
        }
    }

    func setCommandTabHoveredAction(_ action: PreviewThumbnailAction?) {
        guard currentTarget?.previewAnchorKind == .commandTab else {
            return
        }
        thumbnailViewsByIdentity.values.forEach { tile in
            tile.setCommandTabHoveredAction(action)
        }
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
        OmniDockTheme.applyCurrentAppearance(to: panel)
        return panel
    }

    private func rebuildContent(target: DockAppTarget, windows: [PreviewWindowInfo], message: String?) {
        thumbnailViews = [:]
        thumbnailViewsByIdentity = [:]
        thumbnailSizeConstraints = [:]
        scrollView = nil
        scrollDocumentView = nil
        stackView = nil
        gridView = nil
        gridNeedsInitialTopAlignment = false
        transientMessageWorkItem?.cancel()
        transientMessageWorkItem = nil
        messageField = nil

        let root = PreviewPanelRootView(frame: panel?.contentView?.bounds ?? .zero)
        root.autoresizingMask = [.width, .height]

        if windows.isEmpty {
            let label = NSTextField(labelWithString: message ?? AppStrings.text(.previewNoWindows))
            label.alignment = .center
            label.font = .systemFont(ofSize: 13, weight: .medium)
            label.textColor = OmniDockTheme.palette(for: root.effectiveAppearance).primaryText
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
            scrollView.horizontalScrollElasticity = target.previewAnchorKind == .windowCycle
                ? .none
                : .allowed
            scrollView.verticalScrollElasticity = target.previewAnchorKind == .windowCycle
                ? .allowed
                : .none
            scrollView.allowsMagnification = false

            let documentView = PreviewScrollDocumentView()
            documentView.wantsLayer = true
            documentView.layer?.backgroundColor = NSColor.clear.cgColor
            documentView.onHorizontalDrag = { [weak self] deltaX in
                self?.scrollPreviewContent(deltaX: deltaX)
            }
            scrollView.documentView = documentView
            root.addSubview(scrollView)
            self.scrollView = scrollView
            self.scrollDocumentView = documentView

            if target.previewAnchorKind == .windowCycle {
                let layout = windowCycleGridMetrics(
                    target: target,
                    windows: windows
                )
                let rows = makeGridRows(
                    windows: windows,
                    columnCount: layout.columnCount
                )
                let grid = NSGridView(views: rows)
                grid.rowSpacing = PreviewLayoutCalculator.gap
                grid.columnSpacing = PreviewLayoutCalculator.gap
                grid.xPlacement = .center
                grid.yPlacement = .center
                for (index, width) in layout.columnWidths.enumerated() {
                    grid.column(at: index).width = width
                }
                for rowIndex in 0..<layout.rowCount {
                    grid.row(at: rowIndex).height = layout.rowHeight
                }
                documentView.addSubview(grid)
                self.gridView = grid
                gridNeedsInitialTopAlignment = true
            } else {
                let stack = NSStackView()
                stack.orientation = .horizontal
                stack.spacing = PreviewLayoutCalculator.gap
                stack.alignment = .centerY
                stack.distribution = .fill
                stack.autoresizingMask = [.height]

                for info in windows {
                    stack.addArrangedSubview(makeThumbnail(info: info))
                }
                documentView.addSubview(stack)
                self.stackView = stack
            }
            layoutScrollableContent()
        }

        panel?.contentView = root
    }

    private func makeTransientMessageField(in contentView: NSView) -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.alignment = .center
        field.font = .systemFont(ofSize: 12, weight: .medium)
        let palette = OmniDockTheme.palette(for: contentView.effectiveAppearance)
        field.textColor = palette.primaryText
        field.lineBreakMode = .byTruncatingTail
        field.wantsLayer = true
        field.layer?.backgroundColor = palette.overlay.cgColor
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
        let presentationHandler = currentTarget.flatMap {
            presentationHandlers[$0.previewAnchorKind]
        }
        if let presentationHandler {
            presentationHandler.onLifecycleEndRequested()
        } else {
            onPreviewLifecycleEndRequested?()
        }
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
        let presentationHandler = presentationHandlers[target.previewAnchorKind]

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
                    requestGeneration: requestGeneration,
                    presentationHandler: presentationHandler
                )
            }
        }
    }

    func quitApplicationFromPreview(_ info: PreviewWindowInfo) {
        guard pendingApplicationQuitProcessIdentifiers.insert(info.processIdentifier).inserted else {
            return
        }

        let requestTargetIdentifier = currentTarget?.dockTileIdentifier
        let requestGeneration = targetGeneration
        let presentationHandler = currentTarget.flatMap {
            presentationHandlers[$0.previewAnchorKind]
        }
        guard requestApplicationQuit(info.processIdentifier, { [weak self] didTerminate in
            Task { @MainActor [weak self] in
                self?.completeApplicationQuit(
                    processIdentifier: info.processIdentifier,
                    didTerminate: didTerminate,
                    requestTargetIdentifier: requestTargetIdentifier,
                    requestGeneration: requestGeneration,
                    presentationHandler: presentationHandler
                )
            }
        }) else {
            pendingApplicationQuitProcessIdentifiers.remove(info.processIdentifier)
            showTransientMessage(AppStrings.text(.previewQuitFailed))
            return
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
        requestGeneration: UInt64,
        presentationHandler: PresentationHandler?
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

        if let presentationHandler {
            presentationHandler.onWindowClosed(info)
        } else {
            onWindowClosed?(info)
        }
        if belongsToCurrentPresentation {
            removeThumbnail(for: info)
        }
    }

    private func completeApplicationQuit(
        processIdentifier: pid_t,
        didTerminate: Bool,
        requestTargetIdentifier: String?,
        requestGeneration: UInt64,
        presentationHandler: PresentationHandler?
    ) {
        guard pendingApplicationQuitProcessIdentifiers.remove(processIdentifier) != nil else {
            return
        }

        let belongsToCurrentPresentation = requestGeneration == targetGeneration
            && currentTarget?.dockTileIdentifier == requestTargetIdentifier
        guard didTerminate else {
            if belongsToCurrentPresentation {
                showTransientMessage(AppStrings.text(.previewQuitFailed))
            }
            return
        }

        if let presentationHandler {
            presentationHandler.onApplicationQuitRequested(processIdentifier)
            presentationHandler.onLifecycleEndRequested()
        } else {
            onApplicationQuitRequested?(processIdentifier)
            onPreviewLifecycleEndRequested?()
        }
        if belongsToCurrentPresentation {
            hide()
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
        if currentTarget?.previewAnchorKind == .windowCycle,
           let currentTarget {
            if thumbnailViewsByIdentity.isEmpty {
                hide()
            } else {
                show(target: currentTarget, windows: currentWindows, message: nil)
            }
            return
        }
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
        notifyCommandTabButtonTargetsChanged()
    }

    private func notifyCommandTabButtonTargetsChanged() {
        onCommandTabButtonTargetsChanged?()
    }

    private func layoutScrollableContent() {
        guard let panel,
              let scrollView,
              let scrollDocumentView
        else {
            return
        }

        let tileSizes = currentWindows.map { window in
            thumbnailViewsByIdentity[PreviewWindowIdentity(window)]?.preferredTileSize
                ?? PreviewLayoutCalculator.tileSize(for: window.frame)
        }
        let panelBounds = CGRect(origin: .zero, size: panel.frame.size)
        scrollView.frame = panelBounds

        if let gridView,
           let currentTarget,
           currentTarget.previewAnchorKind == .windowCycle {
            let layout = windowCycleGridMetrics(
                target: currentTarget,
                windows: currentWindows,
                tileSizes: tileSizes
            )
            let documentSize = CGSize(
                width: max(layout.contentSize.width, panelBounds.width),
                height: max(layout.contentSize.height, panelBounds.height)
            )
            scrollDocumentView.frame = CGRect(origin: .zero, size: documentSize)
            gridView.frame = CGRect(
                x: (documentSize.width - layout.gridSize.width) / 2,
                y: documentSize.height - PreviewLayoutCalculator.margin - layout.gridSize.height,
                width: layout.gridSize.width,
                height: layout.gridSize.height
            ).integral
            for (index, width) in layout.columnWidths.enumerated() {
                gridView.column(at: index).width = width
            }
            for rowIndex in 0..<layout.rowCount {
                gridView.row(at: rowIndex).height = layout.rowHeight
            }
            if gridNeedsInitialTopAlignment {
                let maximumY = max(0, documentSize.height - panelBounds.height)
                scrollView.contentView.scroll(to: CGPoint(x: 0, y: maximumY))
                scrollView.reflectScrolledClipView(scrollView.contentView)
                gridNeedsInitialTopAlignment = false
            } else {
                clampScrollPosition()
            }
            return
        }

        guard let stackView else {
            return
        }
        let contentWidth = PreviewLayoutCalculator.contentWidth(for: tileSizes)
        let documentSize = CGSize(
            width: max(contentWidth, panelBounds.width),
            height: panelBounds.height
        )
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

    private func scrollSelectedWindowIntoViewIfNeeded() {
        guard currentTarget?.previewAnchorKind == .windowCycle,
              let selectedWindowIdentity,
              let tile = thumbnailViewsByIdentity[selectedWindowIdentity],
              let scrollView,
              let documentView = scrollView.documentView
        else {
            return
        }

        let tileFrame = tile.convert(tile.bounds, to: documentView)
        let visibleBounds = scrollView.contentView.bounds
        var targetOrigin = visibleBounds.origin
        var changed = false
        if tileFrame.minX < visibleBounds.minX {
            targetOrigin.x = tileFrame.minX
            changed = true
        } else if tileFrame.maxX > visibleBounds.maxX {
            targetOrigin.x = tileFrame.maxX - visibleBounds.width
            changed = true
        }
        if tileFrame.minY < visibleBounds.minY {
            targetOrigin.y = tileFrame.minY
            changed = true
        } else if tileFrame.maxY > visibleBounds.maxY {
            targetOrigin.y = tileFrame.maxY - visibleBounds.height
            changed = true
        }
        guard changed else {
            return
        }

        let maximumX = max(0, documentView.frame.width - visibleBounds.width)
        let maximumY = max(0, documentView.frame.height - visibleBounds.height)
        targetOrigin.x = min(max(0, targetOrigin.x), maximumX)
        targetOrigin.y = min(max(0, targetOrigin.y), maximumY)
        scrollView.contentView.scroll(to: targetOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func clampScrollPosition() {
        guard let scrollView,
              let documentView = scrollView.documentView
        else {
            return
        }

        let maxX = max(0, documentView.frame.width - scrollView.contentView.bounds.width)
        let maxY = max(0, documentView.frame.height - scrollView.contentView.bounds.height)
        let currentOrigin = scrollView.contentView.bounds.origin
        let clampedOrigin = CGPoint(
            x: min(max(0, currentOrigin.x), maxX),
            y: min(max(0, currentOrigin.y), maxY)
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
        let orientation: DockOrientation
        switch target.previewAnchorKind {
        case .dock:
            orientation = DockGeometry().inferredOrientation(
                dockItemFrame: target.dockItemFrame,
                anchor: anchor,
                screenFrame: screen?.frame ?? screenFrame
            )
        case .commandTab:
            orientation = .bottom
        case .windowCycle:
            return PreviewLayoutCalculator.centeredPanelFrame(
                gridMetrics: windowCycleGridMetrics(
                    target: target,
                    windows: windows,
                    screenFrame: screenFrame
                ),
                screenFrame: screenFrame
            )
        }
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

    private func windowCycleGridMetrics(
        target: DockAppTarget,
        windows: [PreviewWindowInfo],
        tileSizes: [CGSize]? = nil,
        screenFrame: CGRect? = nil
    ) -> PreviewGridMetrics {
        let resolvedScreenFrame = screenFrame ?? previewScreenFrame(for: target)
        let resolvedTileSizes = tileSizes ?? windows.map { window in
            thumbnailViewsByIdentity[PreviewWindowIdentity(window)]?.preferredTileSize
                ?? PreviewLayoutCalculator.tileSize(for: window.frame)
        }
        return PreviewLayoutCalculator.windowCycleGridMetrics(
            tileSizes: resolvedTileSizes,
            screenFrame: resolvedScreenFrame
        )
    }

    private func previewScreenFrame(for target: DockAppTarget) -> CGRect {
        let anchor = target.previewAnchorPoint
        return (NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main)?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
    }

    private func makeGridRows(
        windows: [PreviewWindowInfo],
        columnCount: Int
    ) -> [[NSView]] {
        guard columnCount > 0 else {
            return []
        }
        let rowCount = Int(ceil(CGFloat(windows.count) / CGFloat(columnCount)))
        return (0..<rowCount).map { rowIndex in
            (0..<columnCount).map { columnIndex in
                let index = rowIndex * columnCount + columnIndex
                guard windows.indices.contains(index) else {
                    let spacer = NSView()
                    spacer.isHidden = true
                    return spacer
                }
                return makeThumbnail(info: windows[index])
            }
        }
    }

    private func makeThumbnail(info: PreviewWindowInfo) -> PreviewThumbnailView {
        let identity = PreviewWindowIdentity(info)
        let tile = PreviewThumbnailView(
            info: info,
            showsApplicationIdentity: currentTarget?.previewAnchorKind == .windowCycle
        )
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
        tile.onQuit = { [weak self] info in
            self?.quitApplicationFromPreview(info)
        }
        thumbnailViewsByIdentity[identity] = tile
        tile.setSelected(identity == selectedWindowIdentity)
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

    private func applySelection() {
        thumbnailViewsByIdentity.forEach { identity, tile in
            tile.setSelected(identity == selectedWindowIdentity)
        }
    }

    private func refreshTheme() {
        guard let panel else {
            return
        }
        OmniDockTheme.applyCurrentAppearance(to: panel)
        panel.contentView?.needsDisplay = true
        panel.contentView?.subviews.forEach { $0.needsDisplay = true }
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
