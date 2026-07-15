import AppKit
import XCTest
@testable import OmniDockCore

@MainActor
final class PreviewPanelControllerTests: XCTestCase {
    func testWindowFocusEndsPreviewLifecycleBeforeRequestingFocus() {
        let info = previewInfo()
        var events: [String] = []
        var focusedWindowID: CGWindowID?
        let controller = PreviewPanelController(
            requestWindowFocus: { _, _, windowID in
                events.append("focus")
                focusedWindowID = windowID
            },
            requestWindowClose: { _, _, _, _ in }
        )
        controller.onPreviewLifecycleEndRequested = {
            events.append("lifecycle")
        }

        controller.focusWindowAndHidePreview(info)

        XCTAssertEqual(events, ["lifecycle", "focus"])
        XCTAssertEqual(focusedWindowID, info.windowID)
        XCTAssertNil(controller.frame)
    }

    func testHideReleasesInstalledPreviewContentAndPanelCanBeReused() {
        let controller = PreviewPanelController(
            requestWindowFocus: { _, _, _ in },
            requestWindowClose: { _, _, _, _ in }
        )
        controller.show(target: dockTarget(), windows: [previewInfo()], message: nil)

        XCTAssertTrue(controller.hasInstalledContentView)

        controller.hide()

        XCTAssertFalse(controller.hasInstalledContentView)
        XCTAssertNil(controller.frame)

        controller.show(target: dockTarget(), windows: [previewInfo()], message: nil)

        XCTAssertTrue(controller.hasInstalledContentView)
        XCTAssertNotNil(controller.frame)
        controller.hide()
    }

    func testConfirmedCloseRemovesWindowOnlyAfterCompletion() async {
        let info = previewInfo()
        var closeRequests = 0
        var closeCompletion: ((Bool) -> Void)?
        let controller = PreviewPanelController(
            requestWindowFocus: { _, _, _ in },
            requestWindowClose: { _, _, _, completion in
                closeRequests += 1
                closeCompletion = completion
            }
        )
        defer { controller.hide() }
        let closed = expectation(description: "confirmed window disappearance")
        controller.onWindowClosed = { closedInfo in
            XCTAssertTrue(closedInfo === info)
            closed.fulfill()
        }
        controller.show(target: dockTarget(), windows: [info], message: nil)

        controller.closeWindowFromPreview(info)
        controller.closeWindowFromPreview(info)

        XCTAssertEqual(closeRequests, 1)
        XCTAssertTrue(controller.isWindowClosePending(info))
        XCTAssertEqual(controller.displayedWindowCount, 1)

        closeCompletion?(true)
        await fulfillment(of: [closed], timeout: 1)

        XCTAssertFalse(controller.isWindowClosePending(info))
        XCTAssertEqual(controller.displayedWindowCount, 0)
    }

    func testFailedCloseKeepsWindowAndShowsExistingFeedback() async {
        let info = previewInfo()
        var closeCompletion: ((Bool) -> Void)?
        var closedWindowCount = 0
        let controller = PreviewPanelController(
            requestWindowFocus: { _, _, _ in },
            requestWindowClose: { _, _, _, completion in
                closeCompletion = completion
            }
        )
        defer { controller.hide() }
        controller.onWindowClosed = { _ in
            closedWindowCount += 1
        }
        controller.show(target: dockTarget(), windows: [info], message: nil)
        controller.closeWindowFromPreview(info)

        closeCompletion?(false)
        while controller.isWindowClosePending(info) {
            await Task.yield()
        }

        XCTAssertEqual(closedWindowCount, 0)
        XCTAssertEqual(controller.displayedWindowCount, 1)
        XCTAssertEqual(
            controller.displayedMessage,
            AppStrings.text(.previewCloseFailed)
        )
    }

    func testDelayedCloseFailureDoesNotAppearOnDifferentTarget() async {
        let firstInfo = previewInfo()
        let secondInfo = previewInfo(
            id: "window-2",
            windowID: 52,
            processIdentifier: 456,
            title: "Other"
        )
        var closeCompletion: ((Bool) -> Void)?
        let controller = PreviewPanelController(
            requestWindowFocus: { _, _, _ in },
            requestWindowClose: { _, _, _, completion in
                closeCompletion = completion
            }
        )
        defer { controller.hide() }
        controller.show(target: dockTarget(), windows: [firstInfo], message: nil)
        controller.closeWindowFromPreview(firstInfo)
        controller.show(
            target: dockTarget(
                processIdentifier: 456,
                identifier: "dock-item:other"
            ),
            windows: [secondInfo],
            message: nil
        )

        closeCompletion?(false)
        while controller.isWindowClosePending(firstInfo) {
            await Task.yield()
        }

        XCTAssertEqual(controller.displayedWindowCount, 1)
        XCTAssertNil(controller.displayedMessage)
    }

    private func dockTarget(
        processIdentifier: pid_t = 123,
        identifier: String = "dock-item:example"
    ) -> DockAppTarget {
        DockAppTarget(
            processIdentifier: processIdentifier,
            bundleIdentifier: "com.example.app",
            localizedName: "Example",
            dockElementTitle: "Example",
            hitPoint: CGPoint(x: 100, y: 20),
            dockItemFrame: CGRect(x: 80, y: 0, width: 48, height: 48),
            dockTileIdentifierOverride: identifier
        )
    }

    private func previewInfo(
        id: String = "window-1",
        windowID: CGWindowID = 42,
        processIdentifier: pid_t = 123,
        title: String = "Document"
    ) -> PreviewWindowInfo {
        PreviewWindowInfo(
            id: id,
            windowID: windowID,
            processIdentifier: processIdentifier,
            appName: "Example",
            title: title,
            frame: CGRect(x: 0, y: 0, width: 1200, height: 800),
            isMinimized: false
        )
    }
}
