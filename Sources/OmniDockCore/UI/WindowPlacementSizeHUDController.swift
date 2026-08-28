import AppKit
import CoreGraphics
import QuartzCore

enum WindowPlacementSizeFormatter {
    static func text(for size: CGSize) -> String {
        "\(Int(size.width.rounded()))×\(Int(size.height.rounded()))"
    }
}

/// Pure placement math for the size bubble, kept separate from AppKit state so
/// the clamping rules stay testable.
enum WindowPlacementSizeHUDLayout {
    static let pointerOffset: CGFloat = 16
    static let screenInset: CGFloat = 4

    static func origin(
        contentSize: CGSize,
        appKitPoint: CGPoint,
        visibleFrame: CGRect,
        backingScale: CGFloat = 1
    ) -> CGPoint {
        var origin = CGPoint(
            x: appKitPoint.x + pointerOffset,
            y: appKitPoint.y - contentSize.height - pointerOffset
        )
        guard !visibleFrame.isEmpty else {
            return snapped(origin, backingScale: backingScale)
        }
        origin.x = min(
            max(origin.x, visibleFrame.minX + screenInset),
            visibleFrame.maxX - contentSize.width - screenInset
        )
        origin.y = min(
            max(origin.y, visibleFrame.minY + screenInset),
            visibleFrame.maxY - contentSize.height - screenInset
        )
        return snapped(origin, backingScale: backingScale)
    }

    /// Pixel-aligned origins keep the panel from shimmering between subpixel
    /// positions while it follows the pointer. Snapping to the display's own
    /// pixel grid rather than to whole points means a Retina display advances
    /// the bubble one backing pixel at a time instead of two, which is what
    /// makes slow pointer movement read as continuous rather than stepped.
    private static func snapped(
        _ point: CGPoint,
        backingScale: CGFloat
    ) -> CGPoint {
        guard backingScale > 1 else {
            return CGPoint(x: point.x.rounded(), y: point.y.rounded())
        }
        return CGPoint(
            x: (point.x * backingScale).rounded() / backingScale,
            y: (point.y * backingScale).rounded() / backingScale
        )
    }
}

/// Display geometry the bubble needs in order to follow the pointer. Resolving
/// it queries the window server, so an entry is reused while the pointer stays
/// on the same display instead of being recomputed on every mouse event.
struct WindowPlacementSizeHUDScreenGeometry {
    let quartzBounds: CGRect
    let appKitFrame: CGRect
    let visibleFrame: CGRect
    let backingScale: CGFloat

    init(
        quartzBounds: CGRect,
        appKitFrame: CGRect,
        visibleFrame: CGRect,
        backingScale: CGFloat = 1
    ) {
        self.quartzBounds = quartzBounds
        self.appKitFrame = appKitFrame
        self.visibleFrame = visibleFrame
        self.backingScale = backingScale
    }

    /// Only a display-backed entry can be matched against a later pointer
    /// position. An entry without real display bounds never reports a hit, so
    /// keeping it would make every following move miss the cache and re-query
    /// the window server.
    var isReusable: Bool {
        !quartzBounds.isNull && !quartzBounds.isEmpty
    }

    func contains(eventTapPoint point: CGPoint) -> Bool {
        quartzBounds.contains(point)
    }

    func appKitPoint(fromEventTapPoint point: CGPoint) -> CGPoint {
        DisplayCoordinateConverter.appKitPoint(
            fromQuartzPoint: point,
            quartzDisplayBounds: quartzBounds,
            appKitScreenFrame: appKitFrame
        )
    }
}

@MainActor
final class WindowPlacementSizeHUDController {
    private var panel: NSPanel?
    private var hudView: WindowPlacementSizeHUDView?
    private var themeObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    private var cachedGeometry: WindowPlacementSizeHUDScreenGeometry?
    private var appliedFrame: NSRect = .zero
    // Mirrors the panel's visibility so the hot path never reads back AppKit
    // window state to decide whether a move is worth applying.
    private var isBubbleVisible = false

    init() {
        themeObserver = NotificationCenter.default.addObserver(
            forName: OmniDockTheme.changedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshTheme()
            }
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.cachedGeometry = nil
            }
        }
    }

    deinit {
        if let themeObserver {
            NotificationCenter.default.removeObserver(themeObserver)
        }
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
    }

    /// Builds the panel ahead of the first drag so the first frame of a resize
    /// never pays for window creation and initial text layout.
    func prepare() {
        _ = ensurePanel()
    }

    /// Updates the measurement text and the position together. Everything the
    /// viewer can see changes inside one transaction, so the window server can
    /// never present a half-updated bubble: a wider value and the matching
    /// panel bounds land in the same frame.
    func show(size: CGSize, near eventTapPoint: CGPoint) {
        let panel = ensurePanel()
        guard let hud = hudView else {
            return
        }
        let wasHidden = !isBubbleVisible
        let previousSize = hud.contentSize

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hud.apply(text: WindowPlacementSizeFormatter.text(for: size))
        let didResize = hud.contentSize != previousSize
        applyFrame(contentSize: hud.contentSize, near: eventTapPoint, in: panel)

        if wasHidden {
            // Render before the panel becomes visible so a reveal never shows
            // an empty or stale frame.
            hud.display()
            if !panel.isVisible {
                panel.orderFrontRegardless()
            }
            panel.alphaValue = 1
            isBubbleVisible = true
        } else if didResize {
            // The panel just changed size. Repainting in the same transaction
            // keeps the window server from stretching the previous bitmap over
            // the new bounds for a frame.
            hud.displayIfNeeded()
        }
        CATransaction.commit()
    }

    /// Position-only update for the frames between two measurement samples.
    /// Cheap enough to run on every pointer event, which is what keeps the
    /// bubble glued to the cursor.
    func move(near eventTapPoint: CGPoint) {
        guard isBubbleVisible, let panel, let hud = hudView else {
            return
        }
        applyFrame(contentSize: hud.contentSize, near: eventTapPoint, in: panel)
    }

    /// Hides the bubble without giving up the window. Used while the pointer is
    /// moving too fast to read the value: ordering the panel out and back in
    /// makes the window server fade it, which reads as a flicker.
    func suspend() {
        guard isBubbleVisible else {
            return
        }
        isBubbleVisible = false
        panel?.alphaValue = 0
    }

    func hide() {
        isBubbleVisible = false
        guard let panel else {
            return
        }
        panel.alphaValue = 0
        panel.orderOut(nil)
    }

    private func applyFrame(
        contentSize: NSSize,
        near eventTapPoint: CGPoint,
        in panel: NSPanel
    ) {
        let geometry = geometry(forEventTapPoint: eventTapPoint)
        let appKitPoint = geometry?.appKitPoint(fromEventTapPoint: eventTapPoint)
            ?? NSEvent.mouseLocation
        let frame = NSRect(
            origin: WindowPlacementSizeHUDLayout.origin(
                contentSize: contentSize,
                appKitPoint: appKitPoint,
                visibleFrame: geometry?.visibleFrame ?? .zero,
                backingScale: geometry?.backingScale ?? 1
            ),
            size: contentSize
        )
        guard frame != appliedFrame else {
            return
        }
        let movesWithoutResizing = frame.size == appliedFrame.size
        appliedFrame = frame
        guard !movesWithoutResizing else {
            // The overwhelming majority of updates only move the bubble. Going
            // through `setFrameOrigin` instead of `setFrame` skips the window
            // resize path: no backing-store revalidation and no content-view
            // resize, so a follow-the-pointer frame costs one window move and
            // no drawing at all.
            panel.setFrameOrigin(frame.origin)
            return
        }
        panel.setFrame(frame, display: false)
    }

    private func geometry(
        forEventTapPoint point: CGPoint
    ) -> WindowPlacementSizeHUDScreenGeometry? {
        if let cachedGeometry, cachedGeometry.contains(eventTapPoint: point) {
            return cachedGeometry
        }
        let geometry = Self.makeGeometry(forEventTapPoint: point)
        if let geometry, geometry.isReusable {
            cachedGeometry = geometry
        }
        return geometry
    }

    private static func makeGeometry(
        forEventTapPoint point: CGPoint
    ) -> WindowPlacementSizeHUDScreenGeometry? {
        if let displayID = DisplayCoordinateConverter.displayID(
            containingQuartzPoint: point
        ),
        let screen = DisplayCoordinateConverter.screen(for: displayID) {
            return geometry(for: screen, displayID: displayID)
        }
        // A pointer position between displays still resolves to a real display
        // so the entry stays reusable; only a machine that reports no matching
        // screen at all falls through to the unbounded main-screen entry.
        let mainDisplayID = CGMainDisplayID()
        if let screen = DisplayCoordinateConverter.screen(for: mainDisplayID) {
            return geometry(for: screen, displayID: mainDisplayID)
        }
        guard let screen = NSScreen.main else {
            return nil
        }
        return WindowPlacementSizeHUDScreenGeometry(
            quartzBounds: .null,
            appKitFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            backingScale: screen.backingScaleFactor
        )
    }

    private static func geometry(
        for screen: NSScreen,
        displayID: CGDirectDisplayID
    ) -> WindowPlacementSizeHUDScreenGeometry {
        WindowPlacementSizeHUDScreenGeometry(
            quartzBounds: CGDisplayBounds(displayID),
            appKitFrame: screen.frame,
            visibleFrame: screen.visibleFrame,
            backingScale: screen.backingScaleFactor
        )
    }

    @discardableResult
    private func ensurePanel() -> NSPanel {
        if let panel {
            return panel
        }
        let hud = WindowPlacementSizeHUDView(frame: .zero)
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
        panel.hidesOnDeactivate = false
        // AppKit fades utility panels in and out by default; the size bubble is
        // shown and hidden many times during a single drag, so the implicit
        // animation would be visible as flicker.
        panel.animationBehavior = .none
        panel.collectionBehavior = [.transient, .fullScreenAuxiliary]
        panel.contentView = hud
        panel.alphaValue = 0
        OmniDockTheme.applyCurrentAppearance(to: panel)
        self.panel = panel
        hudView = hud
        appliedFrame = .zero
        isBubbleVisible = false
        return panel
    }

    private func refreshTheme() {
        guard let panel else {
            return
        }
        OmniDockTheme.applyCurrentAppearance(to: panel)
        hudView?.invalidateAppearance()
    }
}

private final class WindowPlacementSizeHUDView: NSView {
    private static let font = NSFont.monospacedDigitSystemFont(
        ofSize: 13,
        weight: .semibold
    )
    private static let horizontalPadding: CGFloat = 12
    private static let verticalPadding: CGFloat = 6

    private var text: String = ""
    private var attributedText = NSAttributedString()
    private var textSize: NSSize = .zero
    private(set) var contentSize: NSSize = .zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // The bubble is repositioned far more often than its text changes.
        // Caching the rendered layer keeps every follow-the-pointer move free
        // of redraws.
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    func apply(text newText: String) {
        guard newText != text else {
            return
        }
        text = newText
        rebuild()
    }

    func invalidateAppearance() {
        rebuild()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        rebuild()
    }

    /// Only a real size change invalidates the cached drawing. AppKit routes
    /// window geometry updates through this setter, so repainting on every
    /// call would redraw the text on each pointer event even when the bubble
    /// merely moved.
    override func setFrameSize(_ newSize: NSSize) {
        let didChange = newSize != frame.size
        super.setFrameSize(newSize)
        if didChange {
            needsDisplay = true
        }
    }

    private func rebuild() {
        let palette = OmniDockTheme.palette(for: effectiveAppearance)
        attributedText = NSAttributedString(
            string: text,
            attributes: [
                .font: Self.font,
                .foregroundColor: palette.primaryText
            ]
        )
        textSize = attributedText.size()
        contentSize = NSSize(
            width: ceil(textSize.width) + Self.horizontalPadding * 2,
            height: ceil(textSize.height) + Self.verticalPadding * 2
        )
        needsDisplay = true
    }

    override var intrinsicContentSize: NSSize {
        contentSize
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let palette = OmniDockTheme.palette(for: effectiveAppearance)
        let background = NSBezierPath(
            roundedRect: bounds,
            xRadius: 6,
            yRadius: 6
        )
        palette.raisedSurface.withAlphaComponent(0.96).setFill()
        background.fill()
        palette.neutral.withAlphaComponent(0.5).setStroke()
        background.lineWidth = 1
        background.stroke()

        attributedText.draw(
            at: NSPoint(
                x: ((bounds.width - textSize.width) / 2).rounded(),
                y: ((bounds.height - textSize.height) / 2).rounded()
            )
        )
    }
}
