import XCTest
@testable import OmniDockCore

final class PreviewWindowCatalogTests: XCTestCase {
    func testStableDisplayOrderUsesWindowIDAsCreationOrder() {
        let windows = [
            previewWindow(title: "New", windowID: 40),
            previewWindow(title: "Unknown", windowID: nil),
            previewWindow(title: "Old", windowID: 10),
            previewWindow(title: "Middle", windowID: 25)
        ]

        let ordered = PreviewWindowCatalog.stableDisplayOrder(windows)

        XCTAssertEqual(ordered.map(\.title), ["Old", "Middle", "New", "Unknown"])
    }

    func testMergeKeepsMinimizedWindowInCreationOrder() {
        let axWindows = [
            previewWindow(title: "AX New", windowID: 30),
            previewWindow(title: "AX Old", windowID: 10),
            previewWindow(title: "AX Middle Minimized", windowID: 20, frame: CGRect(x: 20, y: 20, width: 400, height: 300), isMinimized: true)
        ]
        let shareableWindows = [
            previewWindow(title: "Live New", windowID: 30)
        ]

        let merged = PreviewWindowCatalog.mergeForDisplay(
            axWindows: axWindows,
            shareableWindows: shareableWindows
        )

        XCTAssertEqual(merged.map(\.title), ["AX Middle Minimized", "Live New"])
    }

    func testMergeCollapsesTabbedWindowsWithSameWindowID() {
        let axWindows = [
            previewWindow(title: "Tab A", windowID: 10),
            previewWindow(title: "Tab B", windowID: 10),
            previewWindow(title: "Independent Window", windowID: 20)
        ]
        let shareableWindows = [
            previewWindow(title: "Visible Document Window", windowID: 10),
            previewWindow(title: "Independent Window", windowID: 20)
        ]

        let merged = PreviewWindowCatalog.mergeForDisplay(
            axWindows: axWindows,
            shareableWindows: shareableWindows
        )

        XCTAssertEqual(merged.map(\.title), ["Visible Document Window", "Independent Window"])
    }

    func testMergeUsesShareableWindowsAsVisibleWindowTruthWhenAXTabsHaveDifferentIDs() {
        let sharedFrame = CGRect(x: 20, y: 30, width: 700, height: 500)
        let axWindows = [
            previewWindow(title: "Tab A", windowID: 101, frame: sharedFrame),
            previewWindow(title: "Tab B", windowID: 102, frame: sharedFrame)
        ]
        let shareableWindows = [
            previewWindow(title: "Document Window", windowID: 10, frame: sharedFrame)
        ]

        let merged = PreviewWindowCatalog.mergeForDisplay(
            axWindows: axWindows,
            shareableWindows: shareableWindows
        )

        XCTAssertEqual(merged.map(\.title), ["Document Window"])
    }

    func testMergeKeepsIndependentShareableWindowsWithMatchingMaximizedFrames() {
        let maximizedFrame = CGRect(x: 0, y: 24, width: 1_440, height: 876)
        let shareableWindows = [
            previewWindow(title: "First Window", windowID: 10, frame: maximizedFrame),
            previewWindow(title: "Second Window", windowID: 20, frame: maximizedFrame),
            previewWindow(title: "Third Window", windowID: 30, frame: maximizedFrame)
        ]

        let merged = PreviewWindowCatalog.mergeForDisplay(
            axWindows: shareableWindows,
            shareableWindows: shareableWindows
        )

        XCTAssertEqual(
            merged.map(\.title),
            ["First Window", "Second Window", "Third Window"]
        )
    }

    func testCollapseTreatsMatchingFramesWithoutWindowIDsAsOneWindow() {
        let windows = [
            previewWindow(title: "Tab A", windowID: nil, frame: CGRect(x: 20, y: 30, width: 500, height: 400)),
            previewWindow(title: "Tab B", windowID: nil, frame: CGRect(x: 20, y: 30, width: 500, height: 400)),
            previewWindow(title: "Independent Window", windowID: nil, frame: CGRect(x: 80, y: 90, width: 500, height: 400))
        ]

        let collapsed = PreviewWindowCatalog.collapseTabbedWindows(windows)

        XCTAssertEqual(collapsed.map(\.title), ["Tab A", "Independent Window"])
    }

    func testReconciliationUsesUniqueFrameWhenWindowIDsDiffer() {
        let axWindow = previewWindow(
            title: "AX Window",
            windowID: 101,
            frame: CGRect(x: 20.2, y: 30.4, width: 700.1, height: 500.2)
        )
        let shareableWindow = previewWindow(
            title: "ScreenCapture Window",
            windowID: 202,
            frame: CGRect(x: 20.1, y: 30.3, width: 700.3, height: 500.4)
        )
        let otherWindow = previewWindow(
            title: "Other",
            windowID: 303,
            frame: CGRect(x: 90, y: 90, width: 700, height: 500)
        )

        let reconciled = PreviewWindowCatalog.reconcileCaptureCandidates(
            axWindows: [axWindow],
            candidates: [
                PreviewCaptureWindowCandidate(info: shareableWindow, isOnScreen: false),
                PreviewCaptureWindowCandidate(info: otherWindow, isOnScreen: false)
            ]
        )

        XCTAssertEqual(reconciled.map(\.info.id), [shareableWindow.id])
    }

    func testReconciliationRejectsHistoricalSurfacesAfterOnscreenWindowConsumesAXMatch() {
        let sharedFrame = CGRect(x: 20, y: 30, width: 1_200, height: 700)
        let axWindows = [
            previewWindow(title: "Current", windowID: nil, frame: sharedFrame)
        ]
        let candidates = [
            captureCandidate(title: "Current", windowID: 50, frame: sharedFrame, isOnScreen: true),
            captureCandidate(title: "Old One", windowID: 10, frame: sharedFrame, isOnScreen: false),
            captureCandidate(title: "Old Two", windowID: 20, frame: sharedFrame, isOnScreen: false),
            captureCandidate(title: "Current", windowID: 30, frame: sharedFrame, isOnScreen: false),
            captureCandidate(title: "Old Three", windowID: 40, frame: sharedFrame, isOnScreen: false)
        ]

        let reconciled = PreviewWindowCatalog.reconcileCaptureCandidates(
            axWindows: axWindows,
            candidates: candidates
        )

        XCTAssertEqual(reconciled.compactMap { $0.info.windowID }, [50])
    }

    func testReconciliationRejectsOffscreenSurfacesWithoutAXWindows() {
        let candidates = [
            captureCandidate(title: "Old One", windowID: 10, isOnScreen: false),
            captureCandidate(title: "Old Two", windowID: 20, isOnScreen: false)
        ]

        let reconciled = PreviewWindowCatalog.reconcileCaptureCandidates(
            axWindows: [],
            candidates: candidates
        )

        XCTAssertTrue(reconciled.isEmpty)
    }

    func testReconciliationKeepsIndependentOffscreenWindowsWithExactIDs() {
        let sharedFrame = CGRect(x: 0, y: 24, width: 1_440, height: 876)
        let axWindows = [
            previewWindow(title: "First", windowID: 10, frame: sharedFrame),
            previewWindow(title: "Second", windowID: 20, frame: sharedFrame),
            previewWindow(title: "Third", windowID: 30, frame: sharedFrame)
        ]
        let candidates = [
            captureCandidate(title: "First", windowID: 10, frame: sharedFrame, isOnScreen: false),
            captureCandidate(title: "Second", windowID: 20, frame: sharedFrame, isOnScreen: false),
            captureCandidate(title: "Third", windowID: 30, frame: sharedFrame, isOnScreen: false)
        ]

        let reconciled = PreviewWindowCatalog.reconcileCaptureCandidates(
            axWindows: axWindows,
            candidates: candidates
        )

        XCTAssertEqual(reconciled.compactMap { $0.info.windowID }, [10, 20, 30])
    }

    func testReconciliationDoesNotLetOneAXWindowAuthorizeAmbiguousOffscreenCandidates() {
        let sharedFrame = CGRect(x: 20, y: 30, width: 900, height: 600)
        let axWindows = [
            previewWindow(title: "Current", windowID: nil, frame: sharedFrame)
        ]
        let candidates = [
            captureCandidate(title: "Old One", windowID: 10, frame: sharedFrame, isOnScreen: false),
            captureCandidate(title: "Old Two", windowID: 20, frame: sharedFrame, isOnScreen: false)
        ]

        let reconciled = PreviewWindowCatalog.reconcileCaptureCandidates(
            axWindows: axWindows,
            candidates: candidates
        )

        XCTAssertTrue(reconciled.isEmpty)
    }

    func testReconciliationPrefersUniqueTitleAndFrameBeforeFrameOnlyMatching() {
        let sharedFrame = CGRect(x: 20, y: 30, width: 900, height: 600)
        let axWindows = [
            previewWindow(title: "Current Document", windowID: nil, frame: sharedFrame)
        ]
        let candidates = [
            captureCandidate(
                title: "Previous Document",
                windowID: 10,
                frame: sharedFrame,
                isOnScreen: false
            ),
            captureCandidate(
                title: "Current Document",
                windowID: 20,
                frame: sharedFrame,
                isOnScreen: false
            )
        ]

        let reconciled = PreviewWindowCatalog.reconcileCaptureCandidates(
            axWindows: axWindows,
            candidates: candidates
        )

        XCTAssertEqual(reconciled.compactMap { $0.info.windowID }, [20])
    }

    private func previewWindow(title: String, windowID: CGWindowID?, isMinimized: Bool = false) -> PreviewWindowInfo {
        let offset = CGFloat(windowID ?? 0)
        return previewWindow(
            title: title,
            windowID: windowID,
            frame: CGRect(x: offset, y: offset, width: 400, height: 300),
            isMinimized: isMinimized
        )
    }

    private func previewWindow(
        title: String,
        windowID: CGWindowID?,
        frame: CGRect,
        isMinimized: Bool = false
    ) -> PreviewWindowInfo {
        PreviewWindowInfo(
            id: windowID.map { "window-\($0)" } ?? "window-\(title)",
            windowID: windowID,
            processIdentifier: 123,
            appName: "Test",
            title: title,
            frame: frame,
            isMinimized: isMinimized
        )
    }

    private func captureCandidate(
        title: String,
        windowID: CGWindowID,
        frame: CGRect = CGRect(x: 20, y: 30, width: 700, height: 500),
        isOnScreen: Bool
    ) -> PreviewCaptureWindowCandidate {
        PreviewCaptureWindowCandidate(
            info: previewWindow(title: title, windowID: windowID, frame: frame),
            isOnScreen: isOnScreen
        )
    }
}
