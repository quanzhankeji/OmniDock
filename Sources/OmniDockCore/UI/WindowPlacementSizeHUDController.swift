import AppKit
import CoreGraphics

enum WindowPlacementSizeFormatter {
    static func text(for size: CGSize) -> String {
        "\(Int(size.width.rounded()))×\(Int(size.height.rounded()))"
    }
}

@MainActor
final class WindowPlacementSizeHUDController {
    private var panel: NSPanel?
    private var themeObserver: NSObjectProtocol?

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
    }

    deinit {
        if let themeObserver {
            NotificationCenter.default.removeObserver(themeObserver)
        }
    }

    func show(size: CGSize, near eventTapPoint: CGPoint) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        guard let hud = panel.contentView as? WindowPlacementSizeHUDView else {
            return
        }

        hud.text = WindowPlacementSizeFormatter.text(for: size)
        let contentSize = hud.intrinsicContentSize
        if panel.contentView?.frame.size != contentSize {
            panel.setContentSize(contentSize)
        }
        panel.setFrameOrigin(
            origin(forContentSize: contentSize, near: eventTapPoint)
        )
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
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
        panel.contentView = WindowPlacementSizeHUDView()
        OmniDockTheme.applyCurrentAppearance(to: panel)
        return panel
    }

    private func origin(
        forContentSize contentSize: NSSize,
        near eventTapPoint: CGPoint
    ) -> NSPoint {
        let appKitPoint = DisplayCoordinateConverter.appKitPoint(
            fromEventTapPoint: eventTapPoint
        )
        let offset: CGFloat = 16
        var origin = NSPoint(
            x: appKitPoint.x + offset,
            y: appKitPoint.y - contentSize.height - offset
        )
        if let screen = NSScreen.screens.first(where: {
            $0.frame.contains(appKitPoint)
        }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            origin.x = min(
                max(origin.x, visible.minX + 4),
                visible.maxX - contentSize.width - 4
            )
            origin.y = min(
                max(origin.y, visible.minY + 4),
                visible.maxY - contentSize.height - 4
            )
        }
        return origin
    }

    private func refreshTheme() {
        guard let panel else {
            return
        }
        OmniDockTheme.applyCurrentAppearance(to: panel)
        panel.contentView?.needsDisplay = true
    }
}

private final class WindowPlacementSizeHUDView: NSView {
    var text: String = "" {
        didSet {
            guard oldValue != text else {
                return
            }
            needsDisplay = true
        }
    }

    private let font = NSFont.monospacedDigitSystemFont(
        ofSize: 13,
        weight: .semibold
    )
    private let horizontalPadding: CGFloat = 12
    private let verticalPadding: CGFloat = 6

    override var intrinsicContentSize: NSSize {
        let textSize = (text as NSString).size(
            withAttributes: [.font: font]
        )
        return NSSize(
            width: ceil(textSize.width) + horizontalPadding * 2,
            height: ceil(textSize.height) + verticalPadding * 2
        )
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

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: palette.primaryText
        ]
        let textSize = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(
            at: NSPoint(
                x: (bounds.width - textSize.width) / 2,
                y: (bounds.height - textSize.height) / 2
            ),
            withAttributes: attributes
        )
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
