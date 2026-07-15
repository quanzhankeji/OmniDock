import CoreGraphics
import XCTest
@testable import OmniDockCore

final class DockProxyTargetResolverTests: XCTestCase {
    func testUniqueMatchingWindowOwnerBecomesApplicationTarget() {
        let target = dockTarget(processIdentifier: 10, dockElementTitle: "Project Window")
        let router = DockProxyTargetRouter()

        let routed = router.resolvedTarget(
            for: target,
            windows: [
                window(
                    processIdentifier: 10,
                    title: "Project Window",
                    frame: CGRect(x: 0, y: 0, width: 500, height: 24)
                ),
                window(processIdentifier: 20, title: "Project Window")
            ],
            runningApplication: runningApplications([20])
        )

        XCTAssertEqual(routed.processIdentifier, 20)
        XCTAssertEqual(routed.bundleIdentifier, "com.example.20")
        XCTAssertEqual(routed.localizedName, "Application 20")
        XCTAssertEqual(routed.hitPoint, target.hitPoint)
        XCTAssertEqual(routed.dockItemFrame, target.dockItemFrame)
        XCTAssertEqual(routed.dockTileIdentifier, target.dockTileIdentifier)
        XCTAssertEqual(router.rememberedOwnerProcessIdentifier(for: target), 20)
    }

    func testPreviewAndClickShareRememberedApplicationTarget() {
        let target = dockTarget(processIdentifier: 10, dockElementTitle: "Project Window")
        let ownerStore = DockProxyOwnerStore()
        let previewRouter = DockProxyTargetRouter(ownerStore: ownerStore)
        let clickRouter = DockProxyTargetRouter(ownerStore: ownerStore)

        let previewTarget = previewRouter.resolvedTarget(
            for: target,
            windows: [window(processIdentifier: 20, title: "Project Window")],
            runningApplication: runningApplications([20])
        )
        let clickTarget = clickRouter.resolvedTarget(
            for: target,
            windows: [],
            runningApplication: runningApplications([20])
        )

        XCTAssertEqual(clickTarget, previewTarget)
        XCTAssertEqual(clickTarget.processIdentifier, 20)
        XCTAssertEqual(clickTarget.dockTileIdentifier, target.dockTileIdentifier)
        XCTAssertEqual(clickTarget.previewAnchorPoint, target.previewAnchorPoint)
    }

    func testSharedOwnerMemoryRemainsConsistentAcrossConcurrentRouters() {
        let target = dockTarget(processIdentifier: 10, dockElementTitle: "Project Window")
        let ownerStore = DockProxyOwnerStore()
        let previewRouter = DockProxyTargetRouter(ownerStore: ownerStore)
        let clickRouter = DockProxyTargetRouter(ownerStore: ownerStore)
        let applications = runningApplications([20])
        _ = previewRouter.resolvedTarget(
            for: target,
            windows: [window(processIdentifier: 20, title: "Project Window")],
            runningApplication: applications
        )
        let resultLock = NSLock()
        var unexpectedProcessIdentifiers: [pid_t] = []

        DispatchQueue.concurrentPerform(iterations: 200) { iteration in
            let router = iteration.isMultiple(of: 2) ? previewRouter : clickRouter
            let resolved = router.resolvedTarget(
                for: target,
                windows: [],
                runningApplication: applications
            )
            guard resolved.processIdentifier != 20 else {
                return
            }
            resultLock.lock()
            unexpectedProcessIdentifiers.append(resolved.processIdentifier)
            resultLock.unlock()
        }

        XCTAssertTrue(unexpectedProcessIdentifiers.isEmpty)
        XCTAssertEqual(clickRouter.rememberedOwnerProcessIdentifier(for: target), 20)
    }

    func testTargetReacquiringValidWindowClearsRememberedOwnerAndFailsOpen() {
        let target = dockTarget(processIdentifier: 10, dockElementTitle: "Project Window")
        let router = DockProxyTargetRouter()
        _ = router.resolvedTarget(
            for: target,
            windows: [window(processIdentifier: 20, title: "Project Window")],
            runningApplication: runningApplications([20])
        )

        let routed = router.resolvedTarget(
            for: target,
            windows: [
                window(processIdentifier: 10, title: "Owned Window"),
                window(processIdentifier: 20, title: "Project Window")
            ],
            runningApplication: runningApplications([10, 20])
        )

        XCTAssertEqual(routed, target)
        XCTAssertNil(router.rememberedOwnerProcessIdentifier(for: target))
    }

    func testTargetReacquiringHiddenOrMinimizedWindowClearsRememberedOwner() {
        let target = dockTarget(processIdentifier: 10, dockElementTitle: "Project Window")
        let router = DockProxyTargetRouter()
        _ = router.resolvedTarget(
            for: target,
            windows: [window(processIdentifier: 20, title: "Project Window")],
            runningApplication: runningApplications([20])
        )

        let routed = router.resolvedTarget(
            for: target,
            originalNormalWindowCount: 1,
            windows: [window(processIdentifier: 20, title: "Project Window")],
            runningApplication: runningApplications([10, 20])
        )

        XCTAssertEqual(routed, target)
        XCTAssertNil(router.rememberedOwnerProcessIdentifier(for: target))
    }

    func testExitedRememberedOwnerClearsAndFailsOpen() {
        let target = dockTarget(processIdentifier: 10, dockElementTitle: "Project Window")
        let router = DockProxyTargetRouter()
        _ = router.resolvedTarget(
            for: target,
            windows: [window(processIdentifier: 20, title: "Project Window")],
            runningApplication: runningApplications([20])
        )

        let routed = router.resolvedTarget(
            for: target,
            windows: [],
            runningApplication: runningApplications([10])
        )

        XCTAssertEqual(routed, target)
        XCTAssertNil(router.rememberedOwnerProcessIdentifier(for: target))
    }

    func testAmbiguousMatchingOwnersClearRememberedOwnerAndFailOpen() {
        let target = dockTarget(processIdentifier: 10, dockElementTitle: "Project Window")
        let router = DockProxyTargetRouter()
        _ = router.resolvedTarget(
            for: target,
            windows: [window(processIdentifier: 20, title: "Project Window")],
            runningApplication: runningApplications([20])
        )

        let routed = router.resolvedTarget(
            for: target,
            windows: [
                window(processIdentifier: 20, title: "Project Window"),
                window(processIdentifier: 30, title: "Project Window")
            ],
            runningApplication: runningApplications([20, 30])
        )

        XCTAssertEqual(routed, target)
        XCTAssertNil(router.rememberedOwnerProcessIdentifier(for: target))
    }

    func testDifferentMatchingOwnerDoesNotSilentlyReplaceRememberedOwner() {
        let target = dockTarget(processIdentifier: 10, dockElementTitle: "Project Window")
        let router = DockProxyTargetRouter()
        _ = router.resolvedTarget(
            for: target,
            windows: [window(processIdentifier: 20, title: "Project Window")],
            runningApplication: runningApplications([20])
        )

        let routed = router.resolvedTarget(
            for: target,
            windows: [window(processIdentifier: 30, title: "Project Window")],
            runningApplication: runningApplications([20, 30])
        )

        XCTAssertEqual(routed, target)
        XCTAssertNil(router.rememberedOwnerProcessIdentifier(for: target))
    }

    func testInvalidOrdinaryWindowsDoNotCreateProxyRoute() {
        let target = dockTarget(processIdentifier: 10, dockElementTitle: "Project Window")
        let router = DockProxyTargetRouter()

        let routed = router.resolvedTarget(
            for: target,
            windows: [
                window(processIdentifier: 20, title: "Project Window", layer: 1),
                window(
                    processIdentifier: 30,
                    title: "Project Window",
                    frame: CGRect(x: 0, y: 0, width: 500, height: 24)
                ),
                window(
                    processIdentifier: 40,
                    title: "Project Window",
                    frame: CGRect(x: 0, y: 0, width: 40, height: 40)
                )
            ],
            runningApplication: runningApplications([20, 30, 40])
        )

        XCTAssertEqual(routed, target)
        XCTAssertNil(router.rememberedOwnerProcessIdentifier(for: target))
    }

    func testProxyRequiresExactNormalizedTitleMatch() {
        let target = dockTarget(processIdentifier: 10, dockElementTitle: "Project Window")
        let router = DockProxyTargetRouter()

        let routed = router.resolvedTarget(
            for: target,
            windows: [window(processIdentifier: 20, title: "Project Window - Host App")],
            runningApplication: runningApplications([20])
        )

        XCTAssertEqual(routed, target)
    }

    func testEmptyDockTitleFailsOpen() {
        let target = dockTarget(processIdentifier: 10, dockElementTitle: "")
        let router = DockProxyTargetRouter()

        let routed = router.resolvedTarget(
            for: target,
            windows: [window(processIdentifier: 20, title: "Project Window")],
            runningApplication: runningApplications([20])
        )

        XCTAssertEqual(routed, target)
    }

    private func dockTarget(
        processIdentifier: pid_t,
        dockElementTitle: String
    ) -> DockAppTarget {
        DockAppTarget(
            processIdentifier: processIdentifier,
            bundleIdentifier: "com.example.\(processIdentifier)",
            localizedName: "Dock Item",
            dockElementTitle: dockElementTitle,
            hitPoint: CGPoint(x: 20, y: 30),
            dockItemFrame: CGRect(x: 100, y: 200, width: 64, height: 72),
            dockTileIdentifierOverride: "dock-item:\(processIdentifier):\(dockElementTitle)"
        )
    }

    private func runningApplications(
        _ processIdentifiers: Set<pid_t>
    ) -> (pid_t) -> DockProxyApplicationInfo? {
        { processIdentifier in
            guard processIdentifiers.contains(processIdentifier) else {
                return nil
            }
            return DockProxyApplicationInfo(
                processIdentifier: processIdentifier,
                bundleIdentifier: "com.example.\(processIdentifier)",
                localizedName: "Application \(processIdentifier)"
            )
        }
    }

    private func window(
        processIdentifier: pid_t,
        title: String?,
        layer: Int = 0,
        isOnScreen: Bool = true,
        frame: CGRect = CGRect(x: 0, y: 0, width: 640, height: 480)
    ) -> DockProxyWindowInfo {
        DockProxyWindowInfo(
            processIdentifier: processIdentifier,
            title: title,
            layer: layer,
            isOnScreen: isOnScreen,
            frame: frame
        )
    }
}
