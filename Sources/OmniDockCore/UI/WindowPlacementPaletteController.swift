import AppKit

enum WindowPlacementPaletteGeometry {
    static let anchorOverlap: CGFloat = 1
    static let arrowHorizontalInset = WindowPlacementBubbleShape.minimumArrowCenterInset
    static let preferredArrowCenterX: CGFloat = 30

    static func origin(
        panelSize: CGSize,
        anchor: CGRect,
        visibleFrame: CGRect
    ) -> CGPoint {
        let proposedX = anchor.midX - preferredArrowCenterX
        let proposedY = anchor.minY + anchorOverlap - panelSize.height
        let maximumX = max(visibleFrame.minX, visibleFrame.maxX - panelSize.width)
        let maximumY = max(visibleFrame.minY, visibleFrame.maxY - panelSize.height)
        var x = min(max(proposedX, visibleFrame.minX), maximumX)
        let arrowX = anchor.midX - x
        if arrowX < arrowHorizontalInset {
            x = anchor.midX - arrowHorizontalInset
        } else if arrowX > panelSize.width - arrowHorizontalInset {
            x = anchor.midX - (panelSize.width - arrowHorizontalInset)
        }
        return CGPoint(
            x: x,
            y: min(max(proposedY, visibleFrame.minY), maximumY)
        )
    }

    static func arrowCenterX(
        anchor: CGRect,
        panelOrigin: CGPoint,
        panelWidth: CGFloat
    ) -> CGFloat {
        min(
            max(anchor.midX - panelOrigin.x, arrowHorizontalInset),
            panelWidth - arrowHorizontalInset
        )
    }
}

enum WindowPlacementBubbleShape {
    static let arrowHeight: CGFloat = 10
    static let arrowShoulderWidth: CGFloat = 5
    static let cornerRadius: CGFloat = 8
    static let minimumArrowCenterInset = cornerRadius + arrowShoulderWidth

    static func path(
        in bounds: CGRect,
        arrowCenterX: CGFloat
    ) -> CGPath {
        let body = CGRect(
            x: bounds.minX + 0.5,
            y: bounds.minY + 0.5,
            width: max(bounds.width - 1, 0),
            height: max(bounds.height - arrowHeight - 1, 0)
        )
        guard body.width > cornerRadius * 2,
              body.height > cornerRadius * 2
        else {
            return CGPath(rect: body, transform: nil)
        }

        let radius = min(cornerRadius, min(body.width, body.height) / 2)
        let minimumCenter = body.minX + radius + arrowShoulderWidth
        let maximumCenter = body.maxX - radius - arrowShoulderWidth
        let center = min(max(arrowCenterX, minimumCenter), maximumCenter)
        let top = body.maxY
        let tip = bounds.maxY - 0.5
        let path = CGMutablePath()

        path.move(to: CGPoint(x: body.minX + radius, y: body.minY))
        path.addLine(to: CGPoint(x: body.maxX - radius, y: body.minY))
        path.addQuadCurve(
            to: CGPoint(x: body.maxX, y: body.minY + radius),
            control: CGPoint(x: body.maxX, y: body.minY)
        )
        path.addLine(to: CGPoint(x: body.maxX, y: top - radius))
        path.addQuadCurve(
            to: CGPoint(x: body.maxX - radius, y: top),
            control: CGPoint(x: body.maxX, y: top)
        )
        path.addLine(to: CGPoint(x: center + arrowShoulderWidth, y: top))
        path.addCurve(
            to: CGPoint(x: center + 5, y: top + 2),
            control1: CGPoint(x: center + 11, y: top),
            control2: CGPoint(x: center + 8, y: top + 1)
        )
        path.addCurve(
            to: CGPoint(x: center, y: tip),
            control1: CGPoint(x: center + 3, y: top + 4),
            control2: CGPoint(x: center + 2, y: tip)
        )
        path.addCurve(
            to: CGPoint(x: center - 5, y: top + 2),
            control1: CGPoint(x: center - 2, y: tip),
            control2: CGPoint(x: center - 3, y: top + 4)
        )
        path.addCurve(
            to: CGPoint(x: center - arrowShoulderWidth, y: top),
            control1: CGPoint(x: center - 8, y: top + 1),
            control2: CGPoint(x: center - 11, y: top)
        )
        path.addLine(to: CGPoint(x: body.minX + radius, y: top))
        path.addQuadCurve(
            to: CGPoint(x: body.minX, y: top - radius),
            control: CGPoint(x: body.minX, y: top)
        )
        path.addLine(to: CGPoint(x: body.minX, y: body.minY + radius))
        path.addQuadCurve(
            to: CGPoint(x: body.minX + radius, y: body.minY),
            control: CGPoint(x: body.minX, y: body.minY)
        )
        path.closeSubpath()
        return path
    }
}

struct WindowPlacementDragZoneDescriptor: Equatable {
    let commandID: UUID
    let region: WindowPlacementRegion
}

enum WindowPlacementDragZonePolicy {
    static func descriptors(
        for commands: [WindowPlacementCommand]
    ) -> [WindowPlacementDragZoneDescriptor] {
        commands.compactMap { command in
            guard command.isEnabled,
                  command.behavior.supportsDragActivation,
                  let region = command.activationRegion,
                  !region.isEmpty
            else {
                return nil
            }
            return WindowPlacementDragZoneDescriptor(
                commandID: command.id,
                region: region
            )
        }
    }
}

@MainActor
final class WindowPlacementPaletteController: NSObject {
    typealias DeferredAction = @MainActor () -> Void
    typealias DeferredScheduler = @MainActor (@escaping DeferredAction) -> Void

    var onChoose: ((UUID, WindowPlacementTarget) -> Void)?
    var onOpenSettings: (() -> Void)?

    private let scheduleDeferred: DeferredScheduler
    private var panel: NSPanel?
    private var anchorShieldPanel: NSPanel?
    private var dragRegionPanels: [CGDirectDisplayID: NSPanel] = [:]
    private var target: WindowPlacementTarget?
    private var outsideMonitors: [Any] = []
    private var terminationObserver: Any?
    private var observedProcessIdentifier: pid_t?
    private var anchorEventTapFrame: CGRect?
    private var pendingHoverClose: DispatchWorkItem?

    init(
        scheduleDeferred: @escaping DeferredScheduler = { action in
            DispatchQueue.main.async {
                action()
            }
        }
    ) {
        self.scheduleDeferred = scheduleDeferred
        super.init()
    }

    func show(
        commands: [WindowPlacementCommand],
        target: WindowPlacementTarget,
        anchorEventTapFrame: CGRect
    ) {
        if panel != nil,
           self.target?.runtimeIdentifier == target.runtimeIdentifier {
            self.anchorEventTapFrame = anchorEventTapFrame
            if let panel,
               let content = panel.contentView as? WindowPlacementBubbleView {
                position(
                    panel: panel,
                    content: content,
                    anchorEventTapFrame: anchorEventTapFrame
                )
            }
            cancelPendingHoverClose()
            return
        }
        hidePaletteOnly()
        self.target = target
        self.anchorEventTapFrame = anchorEventTapFrame
        observeTermination(of: target.processIdentifier)

        let panel = makePanel()
        let content = makeContent(commands: commands)
        panel.contentView = content
        let fittingSize = content.fittingSize
        let panelSize = CGSize(
            width: min(max(fittingSize.width, 220), 320),
            height: min(max(fittingSize.height, 120), 480)
        )
        panel.setContentSize(panelSize)
        position(
            panel: panel,
            content: content,
            anchorEventTapFrame: anchorEventTapFrame
        )
        self.panel = panel
        panel.orderFrontRegardless()

        if let monitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown],
            handler: { [weak self] _ in
                Task { @MainActor in
                    self?.hide()
                }
            }
        ) {
            outsideMonitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown],
            handler: { [weak self] event in
                guard let self else {
                    return event
                }
                if event.type == .keyDown, event.keyCode == 53 {
                    self.hide()
                    return nil
                }
                if event.type == .leftMouseDown || event.type == .rightMouseDown,
                   self.panel?.frame.contains(NSEvent.mouseLocation) == false,
                   self.anchorShieldPanel?.frame.contains(NSEvent.mouseLocation) == false {
                    self.hide()
                }
                return event
            }
        ) {
            outsideMonitors.append(monitor)
        }
    }

    func pointerMoved(toEventTapPoint point: CGPoint) {
        guard let panel else {
            return
        }
        let appKitPoint = DisplayCoordinateConverter.appKitPoint(
            fromEventTapPoint: point
        )
        let isOverAnchor = anchorEventTapFrame?
            .insetBy(dx: -5, dy: -5)
            .contains(point) == true
        let isOverPalette = panel.frame
            .insetBy(dx: -3, dy: -3)
            .contains(appKitPoint)
        if isOverAnchor || isOverPalette {
            cancelPendingHoverClose()
            return
        }
        guard pendingHoverClose == nil else {
            return
        }
        let workItem = DispatchWorkItem { [weak self] in
            self?.hide()
        }
        pendingHoverClose = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: workItem)
    }

    func showDragRegions(
        commands: [WindowPlacementCommand],
        screens: [WindowPlacementScreen],
        for target: WindowPlacementTarget
    ) {
        let descriptors = WindowPlacementDragZonePolicy.descriptors(
            for: commands
        )
        guard !descriptors.isEmpty else {
            hideDragRegions()
            return
        }
        hidePaletteOnly()
        self.target = target
        observeTermination(of: target.processIdentifier)
        let visibleDisplayIDs = Set(screens.map(\.displayID))
        let staleDisplayIDs = dragRegionPanels.keys.filter {
            !visibleDisplayIDs.contains($0)
        }
        for displayID in staleDisplayIDs {
            dragRegionPanels.removeValue(forKey: displayID)?.orderOut(nil)
        }
        for screen in screens {
            let panel = dragRegionPanels[screen.displayID]
                ?? makeDragRegionPanel()
            dragRegionPanels[screen.displayID] = panel
            panel.setFrame(
                appKitFrame(for: screen),
                display: true
            )
            let overlay = panel.contentView
                as? WindowPlacementDragRegionOverlayView
            overlay?.descriptors = descriptors
            overlay?.activeCommandID = nil
            panel.orderFrontRegardless()
        }
    }

    func updateDragRegionHighlight(
        commandID: UUID?,
        displayID: CGDirectDisplayID?
    ) {
        for (panelDisplayID, panel) in dragRegionPanels {
            let overlay = panel.contentView
                as? WindowPlacementDragRegionOverlayView
            overlay?.activeCommandID = panelDisplayID == displayID
                ? commandID
                : nil
        }
    }

    func hideDragRegions() {
        dragRegionPanels.values.forEach { $0.orderOut(nil) }
        dragRegionPanels.removeAll()
        if panel == nil {
            target = nil
            stopObservingTermination()
        }
    }

    func hide() {
        hidePaletteOnly()
        hideDragRegions()
        target = nil
        stopObservingTermination()
    }

    private func hidePaletteOnly() {
        cancelPendingHoverClose()
        panel?.orderOut(nil)
        panel = nil
        anchorShieldPanel?.orderOut(nil)
        anchorShieldPanel = nil
        anchorEventTapFrame = nil
        outsideMonitors.forEach(NSEvent.removeMonitor)
        outsideMonitors.removeAll()
    }

    private func cancelPendingHoverClose() {
        pendingHoverClose?.cancel()
        pendingHoverClose = nil
    }

    private func observeTermination(of processIdentifier: pid_t) {
        guard observedProcessIdentifier != processIdentifier else {
            return
        }
        stopObservingTermination()
        observedProcessIdentifier = processIdentifier
        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication,
                  application.processIdentifier == processIdentifier
            else {
                return
            }
            Task { @MainActor [weak self] in
                self?.hide()
            }
        }
    }

    private func stopObservingTermination() {
        if let terminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(terminationObserver)
        }
        terminationObserver = nil
        observedProcessIdentifier = nil
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.transient, .fullScreenAuxiliary]
        return panel
    }

    private func makeDragRegionPanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        panel.collectionBehavior = [.transient, .fullScreenAuxiliary]
        panel.contentView = WindowPlacementDragRegionOverlayView()
        return panel
    }

    private func makeAnchorShieldPanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.transient, .fullScreenAuxiliary]

        let shield = WindowPlacementGreenButtonShieldView()
        shield.onClick = { [weak self] modifiers in
            guard WindowPlacementGreenButtonPolicy.shouldForwardNativeAction(
                modifiers: modifiers
            ), let self, let target = self.target else {
                return
            }
            self.hide()
            _ = WindowPlacementAccessibility.pressGreenButton(for: target)
        }
        panel.contentView = shield
        return panel
    }

    private func makeContent(
        commands: [WindowPlacementCommand]
    ) -> WindowPlacementBubbleView {
        let visual = WindowPlacementBubbleView()

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 1
        let contentInsets = NSEdgeInsets(
            top: WindowPlacementBubbleShape.arrowHeight + 6,
            left: 8,
            bottom: 8,
            right: 8
        )
        stack.edgeInsets = contentInsets
        stack.translatesAutoresizingMaskIntoConstraints = false
        visual.addSubview(stack)

        for (index, command) in commands.enumerated() {
            let button = WindowPlacementCommandButton(
                command: command,
                title: WindowPlacementNames.title(for: command),
                target: self,
                action: #selector(selectCommand(_:))
            )
            addFullWidthRow(
                button,
                to: stack,
                horizontalInsets: contentInsets.left + contentInsets.right
            )
            if shouldSeparate(after: command),
               index < commands.index(before: commands.endIndex) {
                addFullWidthRow(
                    makeSeparator(),
                    to: stack,
                    horizontalInsets: contentInsets.left + contentInsets.right
                )
            }
        }

        addFullWidthRow(
            makeSeparator(),
            to: stack,
            horizontalInsets: contentInsets.left + contentInsets.right
        )
        let settingsButton = WindowPlacementHoverButton(
            title: AppStrings.text(.windowPlacementOpenSettings),
            image: NSImage(
                systemSymbolName: "gearshape",
                accessibilityDescription: nil
            ),
            target: self,
            action: #selector(openSettings(_:))
        )
        addFullWidthRow(
            settingsButton,
            to: stack,
            horizontalInsets: contentInsets.left + contentInsets.right
        )

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: visual.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: visual.trailingAnchor),
            stack.topAnchor.constraint(equalTo: visual.topAnchor),
            stack.bottomAnchor.constraint(equalTo: visual.bottomAnchor),
            stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 220)
        ])
        return visual
    }

    private func position(
        panel: NSPanel,
        content: WindowPlacementBubbleView,
        anchorEventTapFrame: CGRect
    ) {
        let anchor = appKitRect(fromEventTapFrame: anchorEventTapFrame)
        let panelSize = panel.frame.size
        let origin = paletteOrigin(
            panelSize: panelSize,
            anchor: anchor
        )
        panel.setFrameOrigin(origin)
        content.arrowCenterX = WindowPlacementPaletteGeometry.arrowCenterX(
            anchor: anchor,
            panelOrigin: origin,
            panelWidth: panelSize.width
        )
        positionAnchorShield(at: anchor)
    }

    private func positionAnchorShield(at anchor: CGRect) {
        let shield = anchorShieldPanel ?? makeAnchorShieldPanel()
        anchorShieldPanel = shield
        shield.setFrame(
            anchor.insetBy(dx: -2, dy: -2),
            display: true
        )
        shield.orderFrontRegardless()
    }

    private func addFullWidthRow(
        _ view: NSView,
        to stack: NSStackView,
        horizontalInsets: CGFloat
    ) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(
            equalTo: stack.widthAnchor,
            constant: -horizontalInsets
        ).isActive = true
    }

    private func makeSeparator() -> NSBox {
        let separator = NSBox()
        separator.boxType = .separator
        separator.setContentHuggingPriority(.required, for: .vertical)
        return separator
    }

    private func shouldSeparate(after command: WindowPlacementCommand) -> Bool {
        guard let builtIn = command.builtIn else {
            return false
        }
        return [
            .bottomHalf,
            .bottomRight,
            .rightThird,
            .rightTwoThirds,
            .previousDisplay,
            .restore
        ].contains(builtIn)
    }

    private func paletteOrigin(
        panelSize: CGSize,
        anchor: CGRect
    ) -> CGPoint {
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) }
            ?? NSScreen.main
        let visible = screen?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        return WindowPlacementPaletteGeometry.origin(
            panelSize: panelSize,
            anchor: anchor,
            visibleFrame: visible
        )
    }

    private func appKitRect(fromEventTapFrame frame: CGRect) -> CGRect {
        let topLeft = DisplayCoordinateConverter.appKitPoint(
            fromEventTapPoint: CGPoint(
                x: frame.minX,
                y: frame.minY
            )
        )
        let bottomRight = DisplayCoordinateConverter.appKitPoint(
            fromEventTapPoint: CGPoint(
                x: frame.maxX,
                y: frame.maxY
            )
        )
        return CGRect(
            x: min(topLeft.x, bottomRight.x),
            y: min(topLeft.y, bottomRight.y),
            width: abs(bottomRight.x - topLeft.x),
            height: abs(bottomRight.y - topLeft.y)
        )
    }

    private func appKitFrame(
        for screen: WindowPlacementScreen
    ) -> CGRect {
        NSScreen.screens.first { candidate in
            guard let number = candidate.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber else {
                return false
            }
            return number.uint32Value == screen.displayID
        }?.frame ?? appKitRect(fromEventTapFrame: screen.frame)
    }

    @objc private func selectCommand(_ sender: WindowPlacementCommandButton) {
        guard let target else {
            return
        }
        let commandID = sender.commandID
        hide()
        onChoose?(commandID, target)
    }

    @objc private func openSettings(_ sender: NSButton) {
        requestSettingsPresentation()
    }

    func requestSettingsPresentation() {
        let action = onOpenSettings
        hide()
        guard let action else {
            return
        }
        scheduleDeferred(action)
    }
}

private final class WindowPlacementDragRegionOverlayView: NSView {
    var descriptors: [WindowPlacementDragZoneDescriptor] = [] {
        didSet {
            needsDisplay = true
        }
    }
    var activeCommandID: UUID? {
        didSet {
            guard oldValue != activeCommandID else {
                return
            }
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        for descriptor in descriptors {
            let frame = localFrame(for: descriptor.region)
                .insetBy(dx: 2, dy: 2)
            guard frame.width > 1, frame.height > 1 else {
                continue
            }
            let isActive = descriptor.commandID == activeCommandID
            let radius = min(8, min(frame.width, frame.height) / 2)
            let path = NSBezierPath(
                roundedRect: frame,
                xRadius: radius,
                yRadius: radius
            )
            (isActive
                ? NSColor.controlAccentColor.withAlphaComponent(0.34)
                : NSColor.controlBackgroundColor.withAlphaComponent(0.70)
            ).setFill()
            (isActive
                ? NSColor.controlAccentColor
                : NSColor.systemGray.withAlphaComponent(0.68)
            ).setStroke()
            path.lineWidth = isActive ? 3 : 1.5
            path.fill()
            path.stroke()
        }
    }

    private func localFrame(
        for region: WindowPlacementRegion
    ) -> CGRect {
        CGRect(
            x: bounds.minX + bounds.width * region.x,
            y: bounds.maxY - bounds.height * (region.y + region.height),
            width: bounds.width * region.width,
            height: bounds.height * region.height
        )
    }
}

private class WindowPlacementHoverButton: NSButton {
    private var tracking: NSTrackingArea?
    private var isPointerInside = false
    private var displayTitle: String
    private let commandImageView = NSImageView()
    private let commandTitleLabel = NSTextField(labelWithString: "")

    init(
        title: String,
        image: NSImage?,
        target: AnyObject?,
        action: Selector?
    ) {
        displayTitle = title
        super.init(frame: .zero)
        self.target = target
        self.action = action
        self.title = ""
        self.image = nil
        isBordered = false
        focusRingType = .none
        font = .systemFont(ofSize: 14)
        wantsLayer = true
        layer?.cornerRadius = 5

        commandImageView.image = image
        commandImageView.imageScaling = .scaleProportionallyDown
        commandImageView.translatesAutoresizingMaskIntoConstraints = false
        commandTitleLabel.font = font
        commandTitleLabel.lineBreakMode = .byTruncatingTail
        commandTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(commandImageView)
        addSubview(commandTitleLabel)

        NSLayoutConstraint.activate([
            commandImageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            commandImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            commandImageView.widthAnchor.constraint(equalToConstant: 26),
            commandImageView.heightAnchor.constraint(equalToConstant: 18),
            commandTitleLabel.leadingAnchor.constraint(
                equalTo: commandImageView.trailingAnchor,
                constant: 8
            ),
            commandTitleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            commandTitleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor,
                constant: -8
            )
        ])
        setContentHuggingPriority(.required, for: .vertical)
        heightAnchor.constraint(equalToConstant: 32).isActive = true
        setAccessibilityLabel(title)
        updateAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        if let tracking {
            removeTrackingArea(tracking)
        }
        let tracking = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(tracking)
        self.tracking = tracking
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        isPointerInside = true
        updateAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        isPointerInside = false
        updateAppearance()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    private func updateAppearance() {
        let isHighlighted = isPointerInside && isEnabled
        layer?.backgroundColor = isHighlighted
            ? NSColor.controlAccentColor.cgColor
            : NSColor.clear.cgColor
        commandImageView.contentTintColor = isHighlighted
            ? .white
            : (isEnabled ? .labelColor : .tertiaryLabelColor)
        commandTitleLabel.stringValue = displayTitle
        commandTitleLabel.textColor = isHighlighted
            ? .white
            : (isEnabled ? .labelColor : .tertiaryLabelColor)
    }
}

private final class WindowPlacementGreenButtonShieldView: NSView {
    var onClick: ((NSEvent.ModifierFlags) -> Void)?
    private var pressedInside = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        pressedInside = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        let isInside = bounds.contains(convert(event.locationInWindow, from: nil))
        defer {
            pressedInside = false
        }
        guard pressedInside, isInside else {
            return
        }
        onClick?(event.modifierFlags)
    }
}

private final class WindowPlacementCommandButton: WindowPlacementHoverButton {
    let commandID: UUID

    init(
        command: WindowPlacementCommand,
        title: String,
        target: AnyObject?,
        action: Selector?
    ) {
        commandID = command.id
        super.init(
            title: title,
            image: WindowPlacementGlyph.image(for: command),
            target: target,
            action: action
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class WindowPlacementBubbleView: NSView {
    var arrowCenterX: CGFloat = 28 {
        didSet {
            needsLayout = true
        }
    }

    private let backgroundLayer = CAShapeLayer()
    private let outlineLayer = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(backgroundLayer)
        outlineLayer.fillColor = NSColor.clear.cgColor
        outlineLayer.lineWidth = 1
        layer?.addSublayer(outlineLayer)
        updateColors()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let path = WindowPlacementBubbleShape.path(
            in: bounds,
            arrowCenterX: arrowCenterX
        )
        backgroundLayer.frame = bounds
        backgroundLayer.path = path
        outlineLayer.frame = bounds
        outlineLayer.path = path
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        backgroundLayer.fillColor = NSColor.windowBackgroundColor.cgColor
        outlineLayer.strokeColor = NSColor.separatorColor.cgColor
    }
}

enum WindowPlacementGlyph {
    static func image(for command: WindowPlacementCommand) -> NSImage {
        let size = CGSize(width: 26, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: CGRect(origin: .zero, size: size), xRadius: 3, yRadius: 3).fill()
        NSColor.labelColor.setFill()
        if let region = command.targetRegion {
            let rect = CGRect(
                x: size.width * region.x,
                y: size.height * (1 - region.y - region.height),
                width: size.width * region.width,
                height: size.height * region.height
            )
            NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 2, yRadius: 2).fill()
        } else {
            NSBezierPath(
                roundedRect: CGRect(x: 7, y: 4, width: 12, height: 10),
                xRadius: 2,
                yRadius: 2
            ).fill()
        }
        image.unlockFocus()
        image.isTemplate = true
        return image
    }
}

enum WindowPlacementNames {
    static func title(for command: WindowPlacementCommand) -> String {
        if let customName = command.customName?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !customName.isEmpty {
            return customName
        }
        guard let builtIn = command.builtIn else {
            return AppStrings.text(.windowPlacementCustomDefaultName)
        }
        return AppStrings.text(key(for: builtIn))
    }

    private static func key(for builtIn: BuiltInWindowPlacement) -> AppStringKey {
        switch builtIn {
        case .leftHalf: return .windowPlacementLeftHalf
        case .rightHalf: return .windowPlacementRightHalf
        case .topHalf: return .windowPlacementTopHalf
        case .bottomHalf: return .windowPlacementBottomHalf
        case .topLeft: return .windowPlacementTopLeft
        case .topRight: return .windowPlacementTopRight
        case .bottomLeft: return .windowPlacementBottomLeft
        case .bottomRight: return .windowPlacementBottomRight
        case .leftThird: return .windowPlacementLeftThird
        case .centerThird: return .windowPlacementCenterThird
        case .rightThird: return .windowPlacementRightThird
        case .leftTwoThirds: return .windowPlacementLeftTwoThirds
        case .centerTwoThirds: return .windowPlacementCenterTwoThirds
        case .rightTwoThirds: return .windowPlacementRightTwoThirds
        case .nextDisplay: return .windowPlacementNextDisplay
        case .previousDisplay: return .windowPlacementPreviousDisplay
        case .maximize: return .windowPlacementMaximize
        case .center: return .windowPlacementCenter
        case .restore: return .windowPlacementRestore
        }
    }
}
