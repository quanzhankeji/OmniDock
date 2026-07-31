import AppKit
import XCTest
@testable import OmniDockCore

final class OmniDockThemeTests: XCTestCase {
    override func tearDown() {
        OmniDockTheme.configure(appearance: .system)
        super.tearDown()
    }

    func testSystemAppearanceResolvesEffectiveAppearance() {
        XCTAssertEqual(
            AppAppearance.system.resolved(for: NSAppearance(named: .aqua)),
            .light
        )
        XCTAssertEqual(
            AppAppearance.system.resolved(for: NSAppearance(named: .darkAqua)),
            .dark
        )
    }

    func testExplicitAppearanceOverridesEffectiveAppearance() {
        XCTAssertEqual(
            OmniDockTheme.palette(
                for: NSAppearance(named: .darkAqua),
                appearance: .light
            ).appearance,
            .light
        )
        XCTAssertEqual(
            OmniDockTheme.palette(
                for: NSAppearance(named: .aqua),
                appearance: .dark
            ).appearance,
            .dark
        )
    }

    func testThemeConfigurationPublishesSelectedAppearance() {
        OmniDockTheme.configure(appearance: .dark)
        XCTAssertEqual(OmniDockTheme.appearance, .dark)
        XCTAssertNotNil(AppAppearance.dark.forcedNSAppearance)
        XCTAssertNil(AppAppearance.system.forcedNSAppearance)
    }

    func testAllAppearanceModesResolveAgainstLightAndDarkSystems() {
        let light = NSAppearance(named: .aqua)
        let dark = NSAppearance(named: .darkAqua)

        XCTAssertEqual(
            OmniDockTheme.palette(for: light, appearance: .system).appearance,
            .light
        )
        XCTAssertEqual(
            OmniDockTheme.palette(for: dark, appearance: .system).appearance,
            .dark
        )
        XCTAssertEqual(
            OmniDockTheme.palette(for: dark, appearance: .light).appearance,
            .light
        )
        XCTAssertEqual(
            OmniDockTheme.palette(for: light, appearance: .dark).appearance,
            .dark
        )
    }

    @MainActor
    func testApplicationPaletteUsesEffectiveApplicationAppearance() {
        _ = NSApplication.shared
        OmniDockTheme.configure(appearance: .system)

        XCTAssertEqual(
            OmniDockTheme.applicationPalette().appearance,
            AppAppearance.system.resolved(for: NSApp.effectiveAppearance)
        )
    }

    func testSemanticPaletteKeepsTextAndSurfacesDistinct() {
        for appearance in [AppAppearance.light, .dark] {
            let palette = OmniDockTheme.palette(appearance: appearance)
            XCTAssertNotEqual(palette.primaryText.cgColor, palette.surface.cgColor)
            XCTAssertNotEqual(palette.separator.cgColor, palette.accent.cgColor)
            XCTAssertNotEqual(palette.destructive.cgColor, palette.quietAction.cgColor)
        }
    }

    func testRaisedSurfaceUsesSubtleNativeContentBackground() throws {
        let light = try XCTUnwrap(
            OmniDockTheme.palette(appearance: .light)
                .raisedSurface
                .usingColorSpace(.deviceRGB)
        )
        let dark = try XCTUnwrap(
            OmniDockTheme.palette(appearance: .dark)
                .raisedSurface
                .usingColorSpace(.deviceRGB)
        )

        XCTAssertGreaterThan(light.redComponent, 0.9)
        XCTAssertGreaterThan(light.greenComponent, 0.9)
        XCTAssertGreaterThan(light.blueComponent, 0.9)
        XCTAssertLessThan(dark.alphaComponent, 0.12)
    }

    @MainActor
    func testCustomViewsResolveColorsFromTheirEffectiveAppearance() {
        _ = NSApplication.shared
        let background = OmniDockWindowBackgroundView()
        background.appearance = NSAppearance(named: .darkAqua)
        background.refreshTheme()

        let darkPalette = OmniDockTheme.palette(
            for: NSAppearance(named: .darkAqua),
            appearance: .system
        )
        XCTAssertEqual(
            background.layer?.backgroundColor,
            darkPalette.canvas.cgColor
        )

        let message = PreviewMessageField(labelWithString: "Status")
        message.appearance = NSAppearance(named: .darkAqua)
        message.usesOverlay = true
        message.refreshTheme()
        XCTAssertEqual(message.textColor?.cgColor, darkPalette.primaryText.cgColor)
        XCTAssertEqual(message.layer?.backgroundColor, darkPalette.overlay.cgColor)
    }
}
