import AppKit

enum PreviewFileDragDetector {
    static let finderFilenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
    static let legacyURLType = NSPasteboard.PasteboardType("NSURLPboardType")
    static let supportedTypes: [NSPasteboard.PasteboardType] = [
        .fileURL,
        finderFilenamesType,
        legacyURLType
    ]

    static func containsFileDrag(types: [NSPasteboard.PasteboardType]) -> Bool {
        types.contains { supportedTypes.contains($0) }
    }
}

enum PreviewThumbnailAction: Equatable {
    case closeWindow(PreviewWindowIdentity)
    case quitApplication(pid_t)
}

struct PreviewThumbnailActionHitTarget: Equatable {
    let action: PreviewThumbnailAction
    let screenFrame: CGRect
}

final class PreviewThumbnailView: NSView {
    private(set) var info: PreviewWindowInfo
    var onClick: ((PreviewWindowInfo) -> Void)?
    var onClose: ((PreviewWindowInfo) -> Void)?
    var onQuit: ((PreviewWindowInfo) -> Void)?
    var onHorizontalDrag: ((CGFloat) -> Void)?
    var onFileDragEntered: ((PreviewWindowInfo) -> Void)?

    private static let dragThreshold: CGFloat = 5
    private let imageView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let placeholderField = NSTextField(labelWithString: "")
    private let closeButton = PreviewCloseButtonView(frame: .zero)
    private let quitButton = PreviewQuitButtonView(frame: .zero)
    private var contentAspectRatio: CGFloat
    private var didTriggerFileDrag = false
    private var mouseDownLocationInWindow: CGPoint?
    private var lastDragLocationInWindow: CGPoint?
    private var isDraggingPreviewList = false

    var preferredTileSize: CGSize {
        PreviewLayoutCalculator.tileSize(forContentAspectRatio: contentAspectRatio)
    }

    init(info: PreviewWindowInfo) {
        self.info = info
        self.contentAspectRatio = PreviewLayoutCalculator.contentAspectRatio(for: info.frame)
        super.init(frame: CGRect(origin: .zero, size: PreviewLayoutCalculator.tileSize(for: info.frame)))
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @discardableResult
    func update(image: NSImage) -> Bool {
        imageView.image = image
        placeholderField.isHidden = true
        let previousSize = preferredTileSize
        updateContentAspectRatio(from: image)
        needsLayout = true
        return abs(previousSize.width - preferredTileSize.width) > 1
    }

    @discardableResult
    func update(info: PreviewWindowInfo) -> Bool {
        let previousSize = preferredTileSize
        self.info = info
        titleField.stringValue = info.title

        if let image = info.staticPreviewImage {
            imageView.image = image
            updateContentAspectRatio(from: image)
        } else if imageView.image == nil {
            contentAspectRatio = PreviewLayoutCalculator.contentAspectRatio(for: info.frame)
        }

        placeholderField.stringValue = info.placeholderText
            ?? (info.isMinimized ? AppStrings.text(.previewMinimizedClickRestore) : "")
        placeholderField.isHidden = placeholderField.stringValue.isEmpty || imageView.image != nil
        needsLayout = true
        return abs(previousSize.width - preferredTileSize.width) > 1
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownLocationInWindow = event.locationInWindow
        lastDragLocationInWindow = event.locationInWindow
        isDraggingPreviewList = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let mouseDownLocationInWindow,
              let lastDragLocationInWindow
        else {
            return
        }

        let totalDeltaX = event.locationInWindow.x - mouseDownLocationInWindow.x
        let totalDeltaY = event.locationInWindow.y - mouseDownLocationInWindow.y
        if !isDraggingPreviewList {
            guard hypot(totalDeltaX, totalDeltaY) >= Self.dragThreshold else {
                return
            }
            isDraggingPreviewList = true
        }

        let deltaX = event.locationInWindow.x - lastDragLocationInWindow.x
        self.lastDragLocationInWindow = event.locationInWindow
        onHorizontalDrag?(deltaX)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            mouseDownLocationInWindow = nil
            lastDragLocationInWindow = nil
            isDraggingPreviewList = false
        }

        guard !isDraggingPreviewList else {
            return
        }

        let point = convert(event.locationInWindow, from: nil)
        if bounds.contains(point) {
            onClick?(info)
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !didTriggerFileDrag,
              PreviewFileDragDetector.containsFileDrag(types: sender.draggingPasteboard.types ?? [])
        else {
            return []
        }

        didTriggerFileDrag = true
        onFileDragEntered?(info)
        return []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        didTriggerFileDrag = false
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        didTriggerFileDrag = false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        false
    }

    override func layout() {
        super.layout()
        titleField.frame = CGRect(x: 8, y: 8, width: bounds.width - 16, height: 18)
        imageView.frame = imageFrame(in: bounds)
        placeholderField.frame = imageView.frame.insetBy(dx: 10, dy: 10)
        quitButton.frame = CGRect(x: 12, y: bounds.height - 24, width: 13, height: 13)
        closeButton.frame = CGRect(x: 31, y: bounds.height - 24, width: 13, height: 13)
    }

    func actionButtonHitTargets(in window: NSWindow) -> [PreviewThumbnailActionHitTarget] {
        layoutSubtreeIfNeeded()
        return [
            actionHitTarget(
                for: quitButton,
                action: .quitApplication(info.processIdentifier),
                in: window
            ),
            actionHitTarget(
                for: closeButton,
                action: .closeWindow(PreviewWindowIdentity(info)),
                in: window
            )
        ]
    }

    func setCommandTabHoveredAction(_ action: PreviewThumbnailAction?) {
        let identity = PreviewWindowIdentity(info)
        quitButton.setExternalHover(
            action == .quitApplication(info.processIdentifier)
        )
        closeButton.setExternalHover(action == .closeWindow(identity))
    }

    private func setup() {
        registerForDraggedTypes(PreviewFileDragDetector.supportedTypes)

        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.82).cgColor
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
        layer?.borderWidth = 1
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.16
        layer?.shadowRadius = 8
        layer?.shadowOffset = CGSize(width: 0, height: -2)

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 6
        imageView.layer?.masksToBounds = true
        imageView.imageAlignment = .alignCenter
        imageView.layer?.backgroundColor = NSColor.clear.cgColor

        imageView.image = info.staticPreviewImage
        if let staticPreviewImage = info.staticPreviewImage {
            updateContentAspectRatio(from: staticPreviewImage)
        }

        placeholderField.stringValue = info.placeholderText ?? (info.isMinimized ? AppStrings.text(.previewMinimizedClickRestore) : "")
        placeholderField.alignment = .center
        placeholderField.maximumNumberOfLines = 2
        placeholderField.font = .systemFont(ofSize: 12, weight: .medium)
        placeholderField.textColor = .secondaryLabelColor
        placeholderField.isHidden = placeholderField.stringValue.isEmpty || info.staticPreviewImage != nil

        titleField.stringValue = info.title
        titleField.lineBreakMode = .byTruncatingTail
        titleField.font = .systemFont(ofSize: 12, weight: .medium)
        titleField.textColor = .labelColor
        closeButton.onClose = { [weak self] in
            guard let self else {
                return
            }
            self.onClose?(self.info)
        }
        quitButton.onQuit = { [weak self] in
            guard let self else {
                return
            }
            self.onQuit?(self.info)
        }

        addSubview(imageView)
        addSubview(placeholderField)
        addSubview(titleField)
        addSubview(closeButton)
        addSubview(quitButton)
    }

    private func updateContentAspectRatio(from image: NSImage) {
        guard image.size.width > 0, image.size.height > 0 else {
            return
        }
        contentAspectRatio = image.size.width / image.size.height
    }

    private func actionHitTarget(
        for button: PreviewThumbnailActionButtonView,
        action: PreviewThumbnailAction,
        in window: NSWindow
    ) -> PreviewThumbnailActionHitTarget {
        let frameInWindow = button.convert(button.bounds, to: nil)
        return PreviewThumbnailActionHitTarget(
            action: action,
            screenFrame: window.convertToScreen(frameInWindow)
        )
    }

    private func imageFrame(in bounds: CGRect) -> CGRect {
        let maxFrame = CGRect(x: 8, y: 32, width: bounds.width - 16, height: bounds.height - 40)
        let fittedWidth = min(maxFrame.width, maxFrame.height * contentAspectRatio)
        let x = maxFrame.midX - fittedWidth / 2
        return CGRect(x: x, y: maxFrame.minY, width: fittedWidth, height: maxFrame.height)
            .integral
    }
}

private enum PreviewThumbnailActionButtonKind {
    case closeWindow
    case quitApplication

    var toolTip: String {
        switch self {
        case .closeWindow:
            AppStrings.text(.previewCloseWindow)
        case .quitApplication:
            AppStrings.text(.previewQuitApplication)
        }
    }
}

class PreviewThumbnailActionButtonView: NSControl {
    var onAction: (() -> Void)?

    private let glyphLayer = CAShapeLayer()
    private let kind: PreviewThumbnailActionButtonKind
    private var trackingArea: NSTrackingArea?
    private var isPointerInside = false
    private var isPressed = false
    private var externalHover: Bool?

    var isGlyphVisible: Bool {
        glyphLayer.opacity > 0
    }

    fileprivate init(frame frameRect: NSRect, kind: PreviewThumbnailActionButtonKind) {
        self.kind = kind
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.width / 2
        glyphLayer.frame = bounds
        glyphLayer.path = glyphPath(in: bounds.insetBy(dx: 3.4, dy: 3.4))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        trackingArea = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        isPointerInside = true
        updateAppearance(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        isPointerInside = false
        isPressed = false
        updateAppearance(animated: true)
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        updateAppearance(animated: true)
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let shouldPerformAction = bounds.contains(point)
        isPressed = false
        updateAppearance(animated: true)
        if shouldPerformAction {
            performAction()
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .arrow)
    }

    private func setup() {
        wantsLayer = true
        toolTip = kind.toolTip
        setAccessibilityRole(.button)
        setAccessibilityLabel(kind.toolTip)

        glyphLayer.fillColor = nil
        glyphLayer.strokeColor = glyphColor.cgColor
        glyphLayer.lineWidth = 1.35
        glyphLayer.lineCap = .round
        glyphLayer.opacity = 0
        layer?.addSublayer(glyphLayer)

        updateAppearance(animated: false)
    }

    func performAction() {
        onAction?()
    }

    func setExternalHover(_ isHovered: Bool?) {
        guard externalHover != isHovered else {
            return
        }
        externalHover = isHovered
        updateAppearance(animated: true)
    }

    private func updateAppearance(animated: Bool) {
        layer?.backgroundColor = backgroundColor.cgColor
        layer?.borderColor = borderColor.cgColor
        layer?.borderWidth = 0.7
        setGlyphOpacity((externalHover ?? isPointerInside) ? 1 : 0, animated: animated)
    }

    private func setGlyphOpacity(_ opacity: Float, animated: Bool) {
        if animated {
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = glyphLayer.presentation()?.opacity ?? glyphLayer.opacity
            animation.toValue = opacity
            animation.duration = 0.12
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            glyphLayer.add(animation, forKey: "opacity")
        }
        glyphLayer.opacity = opacity
    }

    private var backgroundColor: NSColor {
        switch kind {
        case .closeWindow:
            if isPressed {
                return NSColor(calibratedRed: 0.82, green: 0.14, blue: 0.12, alpha: 1)
            }
            return NSColor(calibratedRed: 1.0, green: 0.35, blue: 0.31, alpha: 1)
        case .quitApplication:
            return isPressed
                ? NSColor(calibratedWhite: 0.56, alpha: 1)
                : NSColor(calibratedWhite: 0.72, alpha: 1)
        }
    }

    private var borderColor: NSColor {
        switch kind {
        case .closeWindow:
            NSColor(calibratedRed: 0.70, green: 0.08, blue: 0.07, alpha: 0.85)
        case .quitApplication:
            NSColor(calibratedWhite: 0.48, alpha: 0.78)
        }
    }

    private var glyphColor: NSColor {
        switch kind {
        case .closeWindow:
            NSColor(calibratedRed: 0.42, green: 0.04, blue: 0.03, alpha: 0.9)
        case .quitApplication:
            NSColor(calibratedWhite: 0.18, alpha: 0.9)
        }
    }

    private func glyphPath(in rect: CGRect) -> CGPath {
        switch kind {
        case .closeWindow:
            closeGlyphPath(in: rect)
        case .quitApplication:
            quitGlyphPath(in: rect)
        }
    }

    private func closeGlyphPath(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        return path
    }

    private func quitGlyphPath(in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        path.addArc(
            center: center,
            radius: radius,
            startAngle: .pi * 0.80,
            endAngle: .pi * 0.20,
            clockwise: false
        )
        path.move(to: CGPoint(x: center.x, y: rect.minY))
        path.addLine(to: CGPoint(x: center.x, y: center.y + 0.7))
        return path
    }
}

final class PreviewCloseButtonView: PreviewThumbnailActionButtonView {
    var onClose: (() -> Void)? {
        get { onAction }
        set { onAction = newValue }
    }

    init(frame frameRect: NSRect) {
        super.init(frame: frameRect, kind: .closeWindow)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class PreviewQuitButtonView: PreviewThumbnailActionButtonView {
    var onQuit: (() -> Void)? {
        get { onAction }
        set { onAction = newValue }
    }

    init(frame frameRect: NSRect) {
        super.init(frame: frameRect, kind: .quitApplication)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
