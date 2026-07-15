import ApplicationServices
import XCTest
@testable import OmniDockCore

final class WindowFilteringTests: XCTestCase {
    func testShareableWindowFilteringRequiresNormalVisibleWindow() {
        XCTAssertTrue(WindowFiltering.shouldIncludeShareableWindow(
            layer: 0,
            isOnScreen: true,
            frame: CGRect(x: 0, y: 0, width: 500, height: 400)
        ))

        XCTAssertFalse(WindowFiltering.shouldIncludeShareableWindow(
            layer: 1,
            isOnScreen: true,
            frame: CGRect(x: 0, y: 0, width: 500, height: 400)
        ))

        XCTAssertFalse(WindowFiltering.shouldIncludeShareableWindow(
            layer: 0,
            isOnScreen: true,
            frame: CGRect(x: 0, y: 0, width: 40, height: 40)
        ))
    }

    func testShareableWindowFilteringAllowsOccludedAXBackedWindow() {
        XCTAssertFalse(WindowFiltering.shouldIncludeShareableWindow(
            layer: 0,
            isOnScreen: false,
            frame: CGRect(x: 0, y: 0, width: 500, height: 400)
        ))

        XCTAssertTrue(WindowFiltering.shouldIncludeShareableWindow(
            layer: 0,
            isOnScreen: false,
            frame: CGRect(x: 0, y: 0, width: 500, height: 400),
            allowsOccludedCapture: true
        ))

        XCTAssertFalse(WindowFiltering.shouldIncludeShareableWindow(
            layer: 1,
            isOnScreen: false,
            frame: CGRect(x: 0, y: 0, width: 500, height: 400),
            allowsOccludedCapture: true
        ))
    }

    func testOffscreenHistoricalSurfaceIsRejectedWithoutCurrentAXBacking() {
        let historicalWindowFrame = CGRect(x: 200, y: 100, width: 1_200, height: 700)

        XCTAssertFalse(WindowFiltering.shouldIncludeShareableWindow(
            layer: 0,
            isOnScreen: false,
            frame: historicalWindowFrame,
            allowsOccludedCapture: false
        ))
        XCTAssertTrue(WindowFiltering.shouldIncludeShareableWindow(
            layer: 0,
            isOnScreen: false,
            frame: historicalWindowFrame,
            allowsOccludedCapture: true
        ))
    }

    func testNormalWindowFilteringSkipsDialogsAndFloatingWindows() {
        XCTAssertTrue(WindowFiltering.isNormalAXWindow(
            role: kAXWindowRole as String,
            subrole: nil
        ))

        XCTAssertFalse(WindowFiltering.isNormalAXWindow(
            role: kAXWindowRole as String,
            subrole: kAXSystemDialogSubrole as String
        ))

        XCTAssertFalse(WindowFiltering.isNormalAXWindow(
            role: kAXWindowRole as String,
            subrole: kAXFloatingWindowSubrole as String
        ))
    }

    func testAXPreviewFilteringIncludesMinimizedNormalWindowsByTitle() {
        XCTAssertTrue(WindowFiltering.shouldIncludeAXPreviewWindow(
            role: kAXWindowRole as String,
            subrole: nil,
            title: "Document"
        ))

        XCTAssertFalse(WindowFiltering.shouldIncludeAXPreviewWindow(
            role: kAXWindowRole as String,
            subrole: kAXSystemDialogSubrole as String,
            title: "Alert"
        ))

        XCTAssertFalse(WindowFiltering.shouldIncludeAXPreviewWindow(
            role: kAXWindowRole as String,
            subrole: nil,
            title: "   "
        ))
    }

    func testDockClickHidesTopmostVisibleApplication() {
        XCTAssertEqual(
            WindowFiltering.dockIconClickAction(
                isTopmost: true,
                isHidden: false,
                unminimizedNormalWindowCount: 1,
                onscreenNormalWindowCount: 1
            ),
            .hideApplication
        )
    }

    func testDockClickBringsForwardTopmostApplicationWithoutOnscreenWindows() {
        XCTAssertEqual(
            WindowFiltering.dockIconClickAction(
                isTopmost: true,
                isHidden: false,
                unminimizedNormalWindowCount: 1,
                onscreenNormalWindowCount: 0
            ),
            .bringApplicationToFront
        )
    }

    func testDockClickMinimizesTopmostVisibleApplicationWhenConfigured() {
        XCTAssertEqual(
            WindowFiltering.dockIconClickAction(
                isTopmost: true,
                isHidden: false,
                unminimizedNormalWindowCount: 1,
                onscreenNormalWindowCount: 1,
                prefersMinimizeInsteadOfHide: true
            ),
            .minimizeApplicationWindows
        )
    }

    func testMinimizeFallbackHidesWhenWindowsRemainOnscreen() {
        XCTAssertTrue(WindowFiltering.shouldFallbackToHideAfterMinimize(
            beforeOnscreenNormalWindowCount: 1,
            afterOnscreenNormalWindowCount: 1
        ))

        XCTAssertTrue(WindowFiltering.shouldFallbackToHideAfterMinimize(
            beforeOnscreenNormalWindowCount: 2,
            afterOnscreenNormalWindowCount: 1
        ))
    }

    func testMinimizeFallbackDoesNotHideWhenMinimizeSucceeded() {
        XCTAssertFalse(WindowFiltering.shouldFallbackToHideAfterMinimize(
            beforeOnscreenNormalWindowCount: 1,
            afterOnscreenNormalWindowCount: 0
        ))

        XCTAssertFalse(WindowFiltering.shouldFallbackToHideAfterMinimize(
            beforeOnscreenNormalWindowCount: 0,
            afterOnscreenNormalWindowCount: 0
        ))
    }

    func testDockClickBringsForwardBackgroundApplication() {
        XCTAssertEqual(
            WindowFiltering.dockIconClickAction(
                isTopmost: false,
                isHidden: false,
                unminimizedNormalWindowCount: 1
            ),
            .bringApplicationToFront
        )
    }

    func testDockClickBringsForwardHiddenApplication() {
        XCTAssertEqual(
            WindowFiltering.dockIconClickAction(
                isTopmost: true,
                isHidden: true,
                unminimizedNormalWindowCount: 1
            ),
            .bringApplicationToFront
        )
    }

    func testDockClickBringsForwardApplicationWithoutVisibleNormalWindows() {
        XCTAssertEqual(
            WindowFiltering.dockIconClickAction(
                isTopmost: true,
                isHidden: false,
                unminimizedNormalWindowCount: 0
            ),
            .bringApplicationToFront
        )
    }

    func testDockClickIsNotInterceptedWhenRunningApplicationHasNoNormalWindows() {
        XCTAssertFalse(WindowFiltering.shouldInterceptDockClick(
            isTopmost: true,
            isHidden: false,
            unminimizedNormalWindowCount: 0,
            onscreenNormalWindowCount: 0
        ))
    }

    func testRunningDockClickIsHandledWhenApplicationHasWindows() {
        XCTAssertTrue(WindowFiltering.shouldHandleRunningDockClick(
            isHidden: false,
            normalWindowCount: 2,
            onscreenNormalWindowCount: 1
        ))
    }

    func testRunningDockClickIsHandledWhenApplicationIsHidden() {
        XCTAssertTrue(WindowFiltering.shouldHandleRunningDockClick(
            isHidden: true,
            normalWindowCount: 0,
            onscreenNormalWindowCount: 0
        ))
    }

    func testRunningDockClickPassesThroughWhenApplicationHasNoWindows() {
        XCTAssertFalse(WindowFiltering.shouldHandleRunningDockClick(
            isHidden: false,
            normalWindowCount: 0,
            onscreenNormalWindowCount: 0
        ))
    }

    func testDockClickInterceptionOnlyAppliesToTopmostVisibleApplications() {
        XCTAssertTrue(WindowFiltering.shouldInterceptDockClick(
            isTopmost: true,
            isHidden: false,
            unminimizedNormalWindowCount: 1,
            onscreenNormalWindowCount: 1
        ))

        XCTAssertFalse(WindowFiltering.shouldInterceptDockClick(
            isTopmost: false,
            isHidden: false,
            unminimizedNormalWindowCount: 1,
            onscreenNormalWindowCount: 1
        ))

        XCTAssertFalse(WindowFiltering.shouldInterceptDockClick(
            isTopmost: true,
            isHidden: true,
            unminimizedNormalWindowCount: 1,
            onscreenNormalWindowCount: 1
        ))

        XCTAssertFalse(WindowFiltering.shouldInterceptDockClick(
            isTopmost: true,
            isHidden: false,
            unminimizedNormalWindowCount: 1,
            onscreenNormalWindowCount: 0
        ))
    }

    func testPreviewIsSuppressedForTopmostVisibleApplication() {
        XCTAssertFalse(WindowFiltering.shouldShowDockPreview(
            isTopmost: true,
            isHidden: false,
            normalWindowCount: 1,
            unminimizedNormalWindowCount: 1
        ))
    }

    func testPreviewIsSuppressedForRunningApplicationWithoutWindows() {
        XCTAssertFalse(WindowFiltering.shouldShowDockPreview(
            isTopmost: false,
            isHidden: false,
            normalWindowCount: 0,
            unminimizedNormalWindowCount: 0
        ))

        XCTAssertFalse(WindowFiltering.shouldShowDockPreview(
            isTopmost: true,
            isHidden: true,
            normalWindowCount: 0,
            unminimizedNormalWindowCount: 0
        ))
    }

    func testPreviewIsShownForBackgroundOrHiddenApplications() {
        XCTAssertTrue(WindowFiltering.shouldShowDockPreview(
            isTopmost: false,
            isHidden: false,
            normalWindowCount: 1,
            unminimizedNormalWindowCount: 1
        ))

        XCTAssertTrue(WindowFiltering.shouldShowDockPreview(
            isTopmost: true,
            isHidden: true,
            normalWindowCount: 1,
            unminimizedNormalWindowCount: 1
        ))
    }

    func testPreviewIsShownForMinimizedWindows() {
        XCTAssertTrue(WindowFiltering.shouldShowDockPreview(
            isTopmost: false,
            isHidden: false,
            normalWindowCount: 1,
            unminimizedNormalWindowCount: 0
        ))
    }

}
