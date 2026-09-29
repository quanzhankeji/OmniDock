import AppKit
import XCTest
@testable import OmniDockCore

@MainActor
final class PreviewWindowStatusMonitorTests: XCTestCase {
    func testRepeatedStateChangesRefreshWithoutReopeningOrReplacingImages() async throws {
        let workspace = NotificationCenter()
        let inventory = WindowInventoryService(workspaceNotificationCenter: workspace)
        inventory.start()
        defer { inventory.stop() }
        let original = window(image: NSImage(size: NSSize(width: 80, height: 60)))
        var current = window(minimized: true, hidden: true, fullScreen: true,
                             frame: CGRect(x: 1200, y: 0, width: 1000, height: 800))
        var reads: [pid_t] = []
        let monitor = PreviewWindowStatusMonitor(inventory: inventory) { pid, _ in
            reads.append(pid)
            return [current]
        }
        defer { monitor.stop() }
        var updates: [[PreviewWindowInfo]] = []
        monitor.onChange = { updates.append($0) }
        _ = monitor.updateWindows([original])
        XCTAssertTrue(reads.isEmpty)

        postVisibilityChange(to: workspace)
        await drain()
        let refreshed = try XCTUnwrap(updates.last?.first)
        XCTAssertTrue(refreshed.isMinimized)
        XCTAssertEqual(refreshed.isApplicationHidden, true)
        XCTAssertEqual(refreshed.isFullScreen, true)
        XCTAssertEqual(refreshed.frame, current.frame)
        XCTAssertEqual(PreviewWindowIdentity(refreshed), PreviewWindowIdentity(original))
        XCTAssertTrue(refreshed.staticPreviewImage === original.staticPreviewImage)

        current = window(minimized: false, hidden: false, fullScreen: false)
        postVisibilityChange(to: workspace)
        await drain()
        XCTAssertEqual(updates.count, 2)
        XCTAssertEqual(reads, [original.processIdentifier, original.processIdentifier])
        XCTAssertEqual(updates.last?.first?.isMinimized, false)
        XCTAssertEqual(updates.last?.first?.isApplicationHidden, false)
        XCTAssertEqual(updates.last?.first?.isFullScreen, false)
    }

    func testLateSnapshotKeepsFreshStatusButAcceptsItsNewImage() async throws {
        let center = NotificationCenter()
        let inventory = WindowInventoryService(applicationNotificationCenter: center)
        inventory.start()
        defer { inventory.stop() }
        let monitor = PreviewWindowStatusMonitor(inventory: inventory) { _, _ in
            [self.window(minimized: true, hidden: true, fullScreen: true)]
        }
        defer { monitor.stop() }
        _ = monitor.updateWindows([window()])
        center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        await drain()

        let newImage = NSImage(size: NSSize(width: 120, height: 90))
        let updated = try XCTUnwrap(monitor.updateWindows([window(image: newImage)]).first)
        XCTAssertTrue(updated.isMinimized)
        XCTAssertEqual(updated.isApplicationHidden, true)
        XCTAssertEqual(updated.isFullScreen, true)
        XCTAssertTrue(updated.staticPreviewImage === newImage)
    }

    func testStatusEventsReadOnlyVisibleProcessesAndCoalesceWithinOneTurn() async {
        let workspace = NotificationCenter()
        let inventory = WindowInventoryService(workspaceNotificationCenter: workspace)
        inventory.start()
        defer { inventory.stop() }
        var reads: [pid_t] = []
        let monitor = PreviewWindowStatusMonitor(inventory: inventory) { pid, _ in
            reads.append(pid)
            return []
        }
        defer { monitor.stop() }
        _ = monitor.updateWindows([window(pid: 999_999)])
        postVisibilityChange(to: workspace)
        await drain()
        XCTAssertTrue(reads.isEmpty)

        _ = monitor.updateWindows([window(), window(id: 2), window(pid: 999_999)])
        postVisibilityChange(to: workspace)
        postVisibilityChange(to: workspace)
        await drain()
        XCTAssertEqual(reads, [NSRunningApplication.current.processIdentifier])
    }

    func testStoppingDropsQueuedRefreshAndOldStateBeforePanelReuse() async {
        let center = NotificationCenter()
        let inventory = WindowInventoryService(applicationNotificationCenter: center)
        inventory.start()
        defer { inventory.stop() }
        var reads = 0
        let monitor = PreviewWindowStatusMonitor(inventory: inventory) { _, _ in
            reads += 1
            return [self.window(minimized: true)]
        }
        defer { monitor.stop() }
        var changes = 0
        monitor.onChange = { _ in changes += 1 }
        _ = monitor.updateWindows([window()])
        center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        monitor.stop()
        _ = monitor.updateWindows([window()])
        await drain()
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(changes, 0)

        center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        await drain()
        XCTAssertEqual(changes, 1)
        _ = monitor.updateWindows([])
        center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        await drain()
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(monitor.updateWindows([window()]).first?.isMinimized, false)
    }

    func testAmbiguousOrDifferentWindowIdentityNeverSuppliesState() async {
        let center = NotificationCenter()
        let inventory = WindowInventoryService(applicationNotificationCenter: center)
        inventory.start()
        defer { inventory.stop() }
        var observations: [PreviewWindowInfo] = []
        let monitor = PreviewWindowStatusMonitor(inventory: inventory) { _, _ in observations }
        defer { monitor.stop() }
        _ = monitor.updateWindows([window()])
        var changes = 0
        monitor.onChange = { _ in changes += 1 }
        for candidate in [
            [window(id: 2, minimized: true)],
            [window(pid: 999_999, minimized: true)],
            [window(minimized: true), window(minimized: false)],
            [window(id: nil, minimized: true), window(id: nil, minimized: false)]
        ] {
            observations = candidate
            center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
            await drain()
        }
        XCTAssertEqual(changes, 0)
    }

    func testUniqueTitleAndFrameCanRefreshStateWhenAXHasNoWindowNumber() async {
        let center = NotificationCenter()
        let inventory = WindowInventoryService(applicationNotificationCenter: center)
        inventory.start()
        defer { inventory.stop() }
        let monitor = PreviewWindowStatusMonitor(inventory: inventory) { _, _ in
            [self.window(id: nil, minimized: true)]
        }
        defer { monitor.stop() }
        _ = monitor.updateWindows([window()])
        var result: PreviewWindowInfo?
        monitor.onChange = { result = $0.first }
        center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        await drain()
        XCTAssertEqual(result?.windowID, 1)
        XCTAssertEqual(result?.isMinimized, true)
    }

    func testOneUnnumberedAXWindowCannotSupplyStateToTwoSameTitleCards() async {
        let center = NotificationCenter()
        let inventory = WindowInventoryService(applicationNotificationCenter: center)
        inventory.start()
        defer { inventory.stop() }
        let monitor = PreviewWindowStatusMonitor(inventory: inventory) { _, _ in
            [self.window(id: nil, minimized: true)]
        }
        defer { monitor.stop() }
        _ = monitor.updateWindows([window(), window(id: 2)])
        var changes = 0
        monitor.onChange = { _ in changes += 1 }
        center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        await drain()
        XCTAssertEqual(changes, 0)
        XCTAssertEqual(monitor.updateWindows([window(), window(id: 2)]).map(\.isMinimized), [false, false])

        _ = monitor.updateWindows([window()])
        center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        await drain()
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(monitor.updateWindows([window(), window(id: 2)]).map(\.isMinimized), [false, false])
    }

    func testRemovedWindowDoesNotReturnFromQueuedStateRefresh() async {
        let center = NotificationCenter()
        let inventory = WindowInventoryService(applicationNotificationCenter: center)
        inventory.start()
        defer { inventory.stop() }
        let monitor = PreviewWindowStatusMonitor(inventory: inventory) { _, _ in
            [self.window(minimized: true), self.window(id: 2, minimized: true)]
        }
        defer { monitor.stop() }
        _ = monitor.updateWindows([window(), window(id: 2)])
        var result: [PreviewWindowInfo] = []
        monitor.onChange = { result = $0 }
        center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        _ = monitor.updateWindows([window(id: 2)])
        await drain()
        XCTAssertEqual(result.map(\.windowID), [2])
    }

    func testMetadataPlaceholderFollowsMinimizeAndRestore() async {
        let center = NotificationCenter()
        let inventory = WindowInventoryService(applicationNotificationCenter: center)
        inventory.start()
        defer { inventory.stop() }
        var minimized = true
        let monitor = PreviewWindowStatusMonitor(inventory: inventory) { _, _ in
            [self.window(minimized: minimized)]
        }
        defer { monitor.stop() }
        let original = window()
        let metadata = PreviewWindowInfo(
            id: original.id, windowID: original.windowID, processIdentifier: original.processIdentifier,
            appName: original.appName, title: original.title, frame: original.frame, isMinimized: false,
            placeholderText: AppStrings.text(.previewMetadataOnly)
        )
        _ = monitor.updateWindows([metadata])
        var placeholder: String?
        monitor.onChange = { placeholder = $0.first?.placeholderText }
        center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        await drain()
        XCTAssertEqual(placeholder, AppStrings.text(.previewMinimizedClickRestore))
        minimized = false
        center.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        await drain()
        XCTAssertEqual(placeholder, AppStrings.text(.previewMetadataOnly))
    }

    private func postVisibilityChange(to center: NotificationCenter) {
        center.post(name: NSWorkspace.didHideApplicationNotification, object: nil,
                    userInfo: [NSWorkspace.applicationUserInfoKey: NSRunningApplication.current])
    }

    private func drain() async {
        for _ in 0..<3 {
            let drained = expectation(description: "State events drained")
            DispatchQueue.main.async { drained.fulfill() }
            await fulfillment(of: [drained], timeout: 1)
        }
    }

    private func window(
        id: CGWindowID? = 1, pid: pid_t = NSRunningApplication.current.processIdentifier,
        minimized: Bool = false, hidden: Bool = false, fullScreen: Bool = false,
        frame: CGRect = CGRect(x: 0, y: 0, width: 800, height: 600), image: NSImage? = nil
    ) -> PreviewWindowInfo {
        PreviewWindowInfo(id: "document", windowID: id, processIdentifier: pid, appName: "Editor",
                          title: "Document", frame: frame, isMinimized: minimized,
                          isApplicationHidden: hidden, isFullScreen: fullScreen, staticPreviewImage: image)
    }
}
