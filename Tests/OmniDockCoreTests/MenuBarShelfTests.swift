import XCTest
@testable import OmniDockCore

final class MenuBarShelfTests: XCTestCase {
    @MainActor
    func testBoundaryMenuContainsOnlySettingsCommand() {
        let service = MenuBarShelfService(settings: makeSettingsStore())
        let menu = service.makeBoundaryMenu()

        XCTAssertEqual(menu.items.map(\.title), [AppStrings.text(.menuSettings)])
        XCTAssertEqual(menu.items.first?.action, #selector(MenuBarShelfService.openSettings(_:)))
        XCTAssertTrue(menu.items.first?.target === service)
    }

    @MainActor
    func testBoundarySettingsCommandUsesInjectedNavigation() {
        var openCount = 0
        let service = MenuBarShelfService(
            settings: makeSettingsStore(),
            onOpenSettings: { openCount += 1 }
        )

        service.openSettings(NSMenuItem())

        XCTAssertEqual(openCount, 1)
    }

    func testSettingsTabUsesRequestedEnglishAndChineseTitles() {
        XCTAssertEqual(
            LocalizedResourceCatalog.text(.tabHiddenBar, language: .en),
            "Hidden Bar"
        )
        XCTAssertEqual(
            LocalizedResourceCatalog.text(.tabHiddenBar, language: .zhHans),
            "任务栏图标"
        )
    }

    func testToggleAlternatesBetweenVisibleAndTuckedStates() {
        XCTAssertEqual(MenuBarShelfState.visible.toggled, .tucked)
        XCTAssertEqual(MenuBarShelfState.tucked.toggled, .visible)
    }

    func testVisibleStateKeepsDividerAtMarkerWidth() {
        XCTAssertEqual(
            MenuBarShelfLayoutPolicy.boundaryLength(for: .visible, widestScreen: 6_016),
            MenuBarShelfLayoutPolicy.visibleDividerLength
        )
    }

    func testTuckedStateUsesEnoughWidthForLargeAndFutureDisplays() {
        XCTAssertEqual(
            MenuBarShelfLayoutPolicy.boundaryLength(for: .tucked, widestScreen: 3_456),
            10_000
        )
        XCTAssertEqual(
            MenuBarShelfLayoutPolicy.boundaryLength(for: .tucked, widestScreen: 6_016),
            12_032
        )
        XCTAssertEqual(
            MenuBarShelfLayoutPolicy.boundaryLength(for: .tucked, widestScreen: 20_000),
            32_768
        )
    }

    func testAutoHideDelayUsesSupportedNearestValue() {
        XCTAssertEqual(MenuBarShelfAutoHidePolicy.normalizedDelay(0), 5)
        XCTAssertEqual(MenuBarShelfAutoHidePolicy.normalizedDelay(9), 10)
        XCTAssertEqual(MenuBarShelfAutoHidePolicy.normalizedDelay(22), 15)
        XCTAssertEqual(MenuBarShelfAutoHidePolicy.normalizedDelay(54), 60)
    }

    private func makeSettingsStore() -> SettingsStore {
        let suiteName = "MenuBarShelfTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return SettingsStore(defaults: defaults, livePreviewLimitProvider: { 6 })
    }
}
