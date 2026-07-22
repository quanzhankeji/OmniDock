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
    public static func applyCurrentAppearance(to window: NSWindow) {
        window.appearance = appearance.forcedNSAppearance
    }

    private static func palette(for appearance: AppAppearance.Resolved) -> OmniDockThemePalette {
        switch appearance {
        case .light:
            OmniDockThemePalette(
                appearance: .light,
                canvas: color(0.97, 0.975, 0.98),
                surface: color(1, 1, 1),
                raisedSurface: color(0.94, 0.95, 0.97),
                interactiveSurface: color(0.89, 0.90, 0.92),
                primaryText: color(0.11, 0.11, 0.12),
                secondaryText: color(0.39, 0.40, 0.42),
                tertiaryText: color(0.55, 0.56, 0.58),
                disabledText: color(0.60, 0.61, 0.63),
                separator: color(0.79, 0.80, 0.82),
                accent: color(0, 0.48, 1),
                selection: color(0, 0.48, 1),
                success: color(0.18, 0.72, 0.35),
                neutral: color(0.56, 0.57, 0.60),
                destructive: color(1, 0.36, 0.32),
                destructivePressed: color(0.82, 0.14, 0.12),
                destructiveBorder: color(0.70, 0.08, 0.07, 0.85),
                destructiveGlyph: color(0.42, 0.04, 0.03, 0.9),
                quietAction: color(0.72, 0.72, 0.74),
                quietActionPressed: color(0.56, 0.56, 0.58),
                quietActionBorder: color(0.48, 0.48, 0.50, 0.78),
                quietActionGlyph: color(0.18, 0.18, 0.20, 0.9),
                overlay: color(0, 0, 0, 0.78)
            )
        case .dark:
            OmniDockThemePalette(
                appearance: .dark,
                canvas: color(0.11, 0.11, 0.12),
                surface: color(0.15, 0.15, 0.16),
                raisedSurface: color(0.19, 0.19, 0.20),
                interactiveSurface: color(0.25, 0.25, 0.27),
                primaryText: color(0.96, 0.96, 0.97),
                secondaryText: color(0.72, 0.72, 0.75),
                tertiaryText: color(0.55, 0.55, 0.58),
                disabledText: color(0.42, 0.42, 0.45),
                separator: color(0.31, 0.31, 0.33),
                accent: color(0.04, 0.52, 1),
                selection: color(0.04, 0.52, 1),
                success: color(0.19, 0.82, 0.39),
                neutral: color(0.56, 0.56, 0.59),
                destructive: color(1, 0.41, 0.38),
                destructivePressed: color(0.77, 0.17, 0.15),
                destructiveBorder: color(0.93, 0.27, 0.24, 0.9),
                destructiveGlyph: color(0.25, 0.03, 0.03, 0.95),
                quietAction: color(0.47, 0.47, 0.50),
                quietActionPressed: color(0.34, 0.34, 0.37),
                quietActionBorder: color(0.64, 0.64, 0.67, 0.75),
                quietActionGlyph: color(0.96, 0.96, 0.97, 0.92),
                overlay: color(0, 0, 0, 0.82)
            )
        }
    }

    private static func color(
        _ red: CGFloat,
        _ green: CGFloat,
        _ blue: CGFloat,
        _ alpha: CGFloat = 1
    ) -> NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}
