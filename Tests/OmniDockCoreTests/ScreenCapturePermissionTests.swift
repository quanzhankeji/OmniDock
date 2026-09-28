import AppKit
import ScreenCaptureKit
import XCTest
@testable import OmniDockCore

@MainActor
final class ScreenCapturePermissionTests: XCTestCase {
    func testClearingGeometryAllowsFreshQueryAndRejectsTheOldReply() async {
        var replies: [(SCShareableContent?, Error?) -> Void] = []
        let service = ScreenCapturePreviewService(
            windowInventory: nil, hasScreenRecordingPermission: { true }, accessibilityWindows: { _ in [] },
            shareableContentLoader: { replies.append($0) }
        )
        var cancelledCount = 0
        var freshCount = 0
        let freshReply = expectation(description: "Fresh display query completes")
        service.loadWindows(for: target) { _ in cancelledCount += 1 }
        XCTAssertEqual(replies.count, 1)

        service.clearAllCachedSnapshots()
        XCTAssertEqual(cancelledCount, 1)
        service.loadWindows(for: target) { _ in freshCount += 1; freshReply.fulfill() }
        XCTAssertEqual(replies.count, 2)
        guard replies.count == 2 else { return }

        replies[0](nil, NSError(domain: "OldDisplayQuery", code: 1))
        let oldReplyDrained = expectation(description: "Old display reply drained")
        DispatchQueue.main.async { oldReplyDrained.fulfill() }
        await fulfillment(of: [oldReplyDrained], timeout: 1)
        XCTAssertEqual(cancelledCount, 1)
        XCTAssertEqual(freshCount, 0)

        replies[1](nil, nil)
        await fulfillment(of: [freshReply], timeout: 1)
        XCTAssertEqual(cancelledCount, 1)
        XCTAssertEqual(freshCount, 1)
    }

    func testMetadataOnlyNavigationKeepsHiddenAndFullScreenState() throws {
        let info = PreviewWindowInfo(id: "document", windowID: 7, processIdentifier: 42, appName: "Editor",
                                     title: "Document", frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                                     isMinimized: false, isApplicationHidden: true, isFullScreen: true)
        let service = ScreenCapturePreviewService(
            windowInventory: nil, hasScreenRecordingPermission: { false }, accessibilityWindows: { _ in [info] },
            shareableContentLoader: { _ in XCTFail("Metadata navigation must not request capture") }
        )
        var result: PreviewWindowSnapshot?
        service.loadWindows(for: target) { result = $0 }
        let window = try XCTUnwrap(result?.windows.first)
        XCTAssertEqual(window.isApplicationHidden, true)
        XCTAssertEqual(window.isFullScreen, true)
        XCTAssertNil(window.staticPreviewImage)
    }

    func testCachedSnapshotsRefreshApplicationVisibilityWithoutLosingWindowState() throws {
        var isHidden: Bool? = true
        let service = ScreenCapturePreviewService(
            windowInventory: nil, hasScreenRecordingPermission: { true }, applicationHiddenState: { _ in isHidden }
        )
        let info = PreviewWindowInfo(
            id: "cached", windowID: 7, processIdentifier: 42,
            appName: "Editor", title: "Document", frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            isMinimized: true, isApplicationHidden: false, isFullScreen: true,
            staticPreviewImage: NSImage(size: NSSize(width: 30, height: 30))
        )
        service.storeCachedSnapshotWindows([info], for: 42)
        for state: Bool? in [true, false, nil] {
            isHidden = state
            let refreshed = try XCTUnwrap(service.cachedSnapshotWindows(for: 42).first)
            XCTAssertEqual(refreshed.isApplicationHidden, state)
            XCTAssertTrue(refreshed.isMinimized)
            XCTAssertEqual(refreshed.isFullScreen, true)
            XCTAssertTrue(refreshed.staticPreviewImage === info.staticPreviewImage)
        }
    }

    func testMissingPermissionUsesMetadataWithoutCallingScreenCaptureKitOrReusingImages() throws {
        let inventory = WindowInventoryService()
        let info = window(image: NSImage(size: NSSize(width: 30, height: 30)))
        inventory.seed(PreviewWindowSnapshot(windows: [info], captureWindows: [:]), for: target)
        let service = ScreenCapturePreviewService(
            windowInventory: inventory,
            hasScreenRecordingPermission: { false },
            accessibilityWindows: { _ in [info] },
            shareableContentLoader: { _ in XCTFail("Metadata navigation must not query ScreenCaptureKit") }
        )
        service.storeCachedSnapshotWindows([info], for: target.processIdentifier)
        XCTAssertTrue(service.cachedSnapshotWindows(for: target).isEmpty)
        var result: PreviewWindowSnapshot?
        service.loadWindows(for: target) { result = $0 }
        let snapshot = try XCTUnwrap(result)
        XCTAssertEqual(snapshot.windows.count, 1)
        XCTAssertEqual(snapshot.windows.first?.title, "Document")
        XCTAssertEqual(snapshot.windows.first?.windowID, 7)
        XCTAssertNil(snapshot.windows.first?.staticPreviewImage)
        XCTAssertNotNil(snapshot.windows.first?.placeholderText)
        XCTAssertTrue(snapshot.captureWindows.isEmpty)
        XCTAssertNil(snapshot.message)
    }

    func testMetadataPreservesMinimizedStateAndEmptyApplicationsStayEmpty() {
        let info = window(isMinimized: true)
        var windows = [info]
        let service = ScreenCapturePreviewService(
            windowInventory: nil, hasScreenRecordingPermission: { false },
            accessibilityWindows: { _ in windows },
            shareableContentLoader: { _ in XCTFail("Unexpected capture request") }
        )
        service.loadWindows(for: target) { snapshot in
            XCTAssertTrue(snapshot.windows[0].isMinimized)
            XCTAssertEqual(snapshot.windows[0].placeholderText, AppStrings.text(.previewMinimizedClickRestore))
        }
        windows = []
        service.loadWindows(for: target) { snapshot in
            XCTAssertTrue(snapshot.windows.isEmpty)
            XCTAssertTrue(snapshot.captureWindows.isEmpty)
        }
    }

    func testCaptureBeforeHideCompletesImmediatelyWithoutPermission() {
        let service = ScreenCapturePreviewService(
            windowInventory: nil, hasScreenRecordingPermission: { false },
            accessibilityWindows: { _ in XCTFail("No metadata needed before hide"); return [] },
            shareableContentLoader: { _ in XCTFail("Unexpected capture request") }
        )
        var completed = false
        service.captureSnapshotsBeforeHide(for: target, policy: .adaptive(
            livePreviewsEnabled: true, windowCount: 1, powerState: .current
        )) { completed = true }
        XCTAssertTrue(completed)
    }

    func testPermissionRevokedDuringLoadFallsBackToMetadataWithoutCaptureError() async {
        var allowed = true
        var reply: ((SCShareableContent?, Error?) -> Void)?
        let info = window()
        let service = ScreenCapturePreviewService(
            windowInventory: nil, hasScreenRecordingPermission: { allowed },
            accessibilityWindows: { _ in [info] },
            shareableContentLoader: { reply = $0 }
        )
        let loaded = expectation(description: "Metadata after revocation")
        service.loadWindows(for: target) { snapshot in
            XCTAssertEqual(snapshot.windows.count, 1)
            XCTAssertNil(snapshot.windows[0].staticPreviewImage)
            XCTAssertEqual(snapshot.windows[0].placeholderText, AppStrings.text(.previewMetadataOnly))
            XCTAssertTrue(snapshot.captureWindows.isEmpty)
            XCTAssertNil(snapshot.message)
            loaded.fulfill()
        }
        XCTAssertNotNil(reply)
        allowed = false
        reply?(nil, NSError(domain: "CaptureDenied", code: 1))
        await fulfillment(of: [loaded], timeout: 2)
    }

    func testPermissionRestorationCanQueryThumbnailsOnTheSameService() async {
        var allowed = false
        var calls = 0
        let info = window()
        let service = ScreenCapturePreviewService(
            windowInventory: nil, hasScreenRecordingPermission: { allowed },
            accessibilityWindows: { _ in [info] },
            shareableContentLoader: { completion in calls += 1; completion(nil, nil) }
        )
        service.loadWindows(for: target) { XCTAssertEqual($0.windows.count, 1) }
        XCTAssertEqual(calls, 0)
        allowed = true
        let loaded = expectation(description: "Capture query after granting")
        service.loadWindows(for: target) { _ in loaded.fulfill() }
        await fulfillment(of: [loaded], timeout: 2)
        XCTAssertEqual(calls, 1)
    }

    private var target: DockAppTarget {
        DockAppTarget(processIdentifier: 42, bundleIdentifier: "com.example.Editor",
                      localizedName: "Editor", dockElementTitle: "Editor", hitPoint: .zero)
    }

    private func window(isMinimized: Bool = false, image: NSImage? = nil) -> PreviewWindowInfo {
        PreviewWindowInfo(id: "ax-7", windowID: 7, processIdentifier: 42, appName: "Editor",
                          title: "Document", frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                          isMinimized: isMinimized, staticPreviewImage: image)
    }
}
