import AppKit

public struct OmniDockThemePalette {
    public let appearance: AppAppearance.Resolved
    public let canvas: NSColor
    public let surface: NSColor
    public let raisedSurface: NSColor
    public let interactiveSurface: NSColor
    public let primaryText: NSColor
    public let secondaryText: NSColor
    public let tertiaryText: NSColor
    public let disabledText: NSColor
    public let separator: NSColor
    public let accent: NSColor
    public let selection: NSColor
    public let success: NSColor
    public let neutral: NSColor
    public let destructive: NSColor
    public let destructivePressed: NSColor
    public let destructiveBorder: NSColor
    public let destructiveGlyph: NSColor
    public let quietAction: NSColor
    public let quietActionPressed: NSColor
    public let quietActionBorder: NSColor
    public let quietActionGlyph: NSColor
    public let overlay: NSColor
}

public enum OmniDockTheme {
    public static let changedNotification = Notification.Name("OmniDockThemeChanged")

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var appearance: AppAppearance = .system
    }

    private static let state = State()

    public static var appearance: AppAppearance {
        state.lock.lock()
        defer { state.lock.unlock() }
        return state.appearance
    }

    public static func configure(appearance: AppAppearance) {
        state.lock.lock()
        let didChange = state.appearance != appearance
        state.appearance = appearance
        state.lock.unlock()

        guard didChange else {
            return
        }
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }

    public static func palette(
        for effectiveAppearance: NSAppearance? = nil,
        appearance: AppAppearance? = nil
    ) -> OmniDockThemePalette {
        palette(for: (appearance ?? self.appearance).resolved(for: effectiveAppearance))
    }

    @MainActor
    public static func applicationPalette(
        appearance: AppAppearance? = nil
    ) -> OmniDockThemePalette {
        palette(
            for: NSApp.effectiveAppearance,
            appearance: appearance
        )
    }

    @MainActor
    public static func applyCurrentAppearance(to window: NSWindow) {
        window.appearance = appearance.forcedNSAppearance
    }

    // Palettes are immutable and NSColor is thread-safe, so build each variant
    // once instead of allocating 23 colors on every palette() call (which
    // happens on hover/appearance updates for every themed view).
    private static let lightPalette = makePalette(for: .light)
    private static let darkPalette = makePalette(for: .dark)

    private static func palette(for appearance: AppAppearance.Resolved) -> OmniDockThemePalette {
        switch appearance {
        case .light:
            return lightPalette
        case .dark:
            return darkPalette
        }
    }

    private static func makePalette(for appearance: AppAppearance.Resolved) -> OmniDockThemePalette {
        let canvas = resolved(.windowBackgroundColor, for: appearance)
        let surface = resolved(.controlBackgroundColor, for: appearance)
        // The second alternating content color is the native subtle row/card
        // background. underPageBackgroundColor is intentionally much darker
        // in Aqua and is not suitable for foreground settings surfaces.
        let raisedSurface = resolved(
            NSColor.alternatingContentBackgroundColors[1],
            for: appearance
        )
        let interactiveSurface = resolved(
            .unemphasizedSelectedContentBackgroundColor,
            for: appearance
        )
        let primaryText = resolved(.labelColor, for: appearance)
        let secondaryText = resolved(.secondaryLabelColor, for: appearance)
        let tertiaryText = resolved(.tertiaryLabelColor, for: appearance)
        let disabledText = resolved(.disabledControlTextColor, for: appearance)
        let separator = resolved(.separatorColor, for: appearance)
        let accent = resolved(.controlAccentColor, for: appearance)
        let selection = resolved(.selectedContentBackgroundColor, for: appearance)
        let success = resolved(.systemGreen, for: appearance)
        let neutral = resolved(.systemGray, for: appearance)
        let destructive = resolved(.systemRed, for: appearance)
        let quietAction = resolved(.systemGray, for: appearance)

        return OmniDockThemePalette(
            appearance: appearance,
            canvas: canvas,
            surface: surface,
            raisedSurface: raisedSurface,
            interactiveSurface: interactiveSurface,
            primaryText: primaryText,
            secondaryText: secondaryText,
            tertiaryText: tertiaryText,
            disabledText: disabledText,
            separator: separator,
            accent: accent,
            selection: selection,
            success: success,
            neutral: neutral,
            destructive: destructive,
            destructivePressed: blended(destructive, with: primaryText, fraction: 0.18),
            destructiveBorder: blended(destructive, with: primaryText, fraction: 0.28)
                .withAlphaComponent(0.85),
            destructiveGlyph: primaryText.withAlphaComponent(0.92),
            quietAction: quietAction,
            quietActionPressed: blended(quietAction, with: primaryText, fraction: 0.18),
            quietActionBorder: blended(quietAction, with: primaryText, fraction: 0.24)
                .withAlphaComponent(0.78),
            quietActionGlyph: primaryText.withAlphaComponent(0.92),
            overlay: surface.withAlphaComponent(0.94)
        )
    }

    private static func resolved(
        _ color: NSColor,
        for appearance: AppAppearance.Resolved
    ) -> NSColor {
        guard let drawingAppearance = NSAppearance(
            named: appearance == .dark ? .darkAqua : .aqua
        ) else {
            return color
        }

        var resolvedColor = color
        drawingAppearance.performAsCurrentDrawingAppearance {
            if let concreteColor = NSColor(cgColor: color.cgColor) {
                resolvedColor = concreteColor
            }
        }
        return resolvedColor
    }

    private static func blended(
        _ color: NSColor,
        with otherColor: NSColor,
        fraction: CGFloat
    ) -> NSColor {
        color.blended(withFraction: fraction, of: otherColor) ?? color
    }
}

final class OmniDockWindowBackgroundView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        refreshTheme()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        refreshTheme()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshTheme()
    }

    func refreshTheme() {
        layer?.backgroundColor = OmniDockTheme.palette(
            for: effectiveAppearance
        ).canvas.cgColor
    }
}
