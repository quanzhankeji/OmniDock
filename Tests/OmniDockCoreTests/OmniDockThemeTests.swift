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
}
