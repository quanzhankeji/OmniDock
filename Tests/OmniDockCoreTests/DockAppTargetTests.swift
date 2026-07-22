import XCTest
@testable import OmniDockCore

final class DockAppTargetTests: XCTestCase {
    func testPreviewAnchorUsesDockItemCenterWhenFrameIsAvailable() {
        let target = DockAppTarget(
            processIdentifier: 123,
            bundleIdentifier: "com.example.App",
            localizedName: "Example",
            dockElementTitle: "Example",
            hitPoint: CGPoint(x: 10, y: 10),
            dockItemFrame: CGRect(x: 100, y: 200, width: 64, height: 72)
        )

        XCTAssertEqual(target.previewAnchorPoint, CGPoint(x: 132, y: 236))
    }

    func testPreviewAnchorFallsBackToHitPointWithoutDockItemFrame() {
        let target = DockAppTarget(
            processIdentifier: 123,
            bundleIdentifier: "com.example.App",
            localizedName: "Example",
            dockElementTitle: "Example",
            hitPoint: CGPoint(x: 10, y: 10)
        )

        XCTAssertEqual(target.previewAnchorPoint, CGPoint(x: 10, y: 10))
    }

    func testCommandTabTargetRetainsExplicitPreviewAnchorKind() {
        let target = DockAppTarget(
            processIdentifier: 123,
            bundleIdentifier: "com.example.App",
            localizedName: "Example",
            dockElementTitle: "Example",
            hitPoint: CGPoint(x: 420, y: 320),
            dockItemFrame: CGRect(x: 388, y: 288, width: 64, height: 64),
            previewAnchorKind: .commandTab
        )

        XCTAssertEqual(target.previewAnchorKind, .commandTab)
        XCTAssertEqual(target.previewAnchorPoint, CGPoint(x: 420, y: 320))
    }

    func testDockTileIdentifierOverrideKeepsOriginalIconsDistinct() {
        let firstTarget = DockAppTarget(
            processIdentifier: 123,
            bundleIdentifier: "com.example.App",
            localizedName: "Example",
            dockElementTitle: "Example",
            hitPoint: .zero,
            dockTileIdentifierOverride: "dock-item:first"
        )
        let secondTarget = DockAppTarget(
            processIdentifier: 123,
            bundleIdentifier: "com.example.App",
            localizedName: "Example",
            dockElementTitle: "Example",
            hitPoint: .zero,
            dockTileIdentifierOverride: "dock-item:second"
        )

        XCTAssertFalse(firstTarget.isSameDockTile(as: secondTarget))
        XCTAssertEqual(firstTarget.dockTileIdentifier, "dock-item:first")
        XCTAssertEqual(secondTarget.dockTileIdentifier, "dock-item:second")
    }

    func testProxyTargetPreservesOriginalDockTileIdentityAndAnchor() {
        let target = DockAppTarget(
            processIdentifier: 123,
            bundleIdentifier: "com.example.dockitem",
            localizedName: "Dock Item",
            dockElementTitle: "Project Window",
            hitPoint: CGPoint(x: 20, y: 20),
            dockItemFrame: CGRect(x: 100, y: 200, width: 64, height: 72),
            dockTileIdentifierOverride: "dock-item:project"
        )

        let proxy = target.proxying(
            to: 456,
            bundleIdentifier: "com.example.owner",
            localizedName: "Owner App"
        )

        XCTAssertEqual(proxy.processIdentifier, 456)
        XCTAssertEqual(proxy.bundleIdentifier, "com.example.owner")
        XCTAssertEqual(proxy.localizedName, "Owner App")
        XCTAssertEqual(proxy.dockElementTitle, "Project Window")
        XCTAssertEqual(proxy.hitPoint, target.hitPoint)
        XCTAssertEqual(proxy.dockItemFrame, target.dockItemFrame)
        XCTAssertEqual(proxy.previewAnchorPoint, target.previewAnchorPoint)
        XCTAssertEqual(proxy.previewAnchorKind, target.previewAnchorKind)
        XCTAssertEqual(proxy.dockTileIdentifierOverride, "dock-item:project")
        XCTAssertEqual(proxy.dockTileIdentifier, target.dockTileIdentifier)
        XCTAssertTrue(proxy.isSameDockTile(as: target))
    }

    func testProxyPreservesGeneratedIdentityWithoutCreatingOverride() {
        let target = DockAppTarget(
            processIdentifier: 123,
            bundleIdentifier: "com.example.dockitem",
            localizedName: "Dock Item",
            dockElementTitle: "Project Window",
            hitPoint: .zero
        )

        let proxy = target.proxying(
            to: 456,
            bundleIdentifier: "com.example.owner",
            localizedName: "Owner App"
        )

        XCTAssertNil(proxy.dockTileIdentifierOverride)
        XCTAssertEqual(proxy.dockTileIdentifier, "123:application")
        XCTAssertTrue(proxy.isSameDockTile(as: target))
    }
}
