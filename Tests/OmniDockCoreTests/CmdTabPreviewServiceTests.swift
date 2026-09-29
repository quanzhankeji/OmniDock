import AppKit
import ScreenCaptureKit
import XCTest
@testable import OmniDockCore

@MainActor
final class CmdTabPreviewServiceTests: XCTestCase {
    func testTitleChangeUsesVerifiedSurfaceIdentityWhenAXWindowNumberIsMissing() async throws {
        let fixture = Fixture()
        defer { fixture.stop() }
        fixture.hasRecording = true
        let image = NSImage(size: NSSize(width: 80, height: 60))
        let original = fixture.window(1, image: image)
        let sibling = fixture.window(2, image: image)
        fixture.windows = [original, sibling]
        fixture.previewService.storeCachedSnapshotWindows([original, sibling], for: fixture.pid)
        fixture.inventory.seed(PreviewWindowSnapshot(windows: [original, sibling], captureWindows: [:]), for: fixture.target())
        fixture.show()
        let tile = try XCTUnwrap(fixture.tiles().first { $0.info.windowID == 1 })
        func renamed(number: CGWindowID?) -> PreviewWindowInfo {
            PreviewWindowInfo(id: "renamed", windowID: number, processIdentifier: fixture.pid,
                              appName: original.appName, title: "Renamed document", frame: original.frame, isMinimized: false)
        }
        fixture.windows = [renamed(number: nil), sibling]
        fixture.serverWindows = [fixture.pid: [renamed(number: 1), sibling]]
        let refreshed = expectation(description: "Renamed window reconciled")
        fixture.inventory.observeChanges { event in
            if case let .seed(pid, _, records) = event, pid == fixture.pid,
               records.contains(where: { $0.makePreviewWindowInfo().title == "Renamed document" }) {
                refreshed.fulfill()
            }
        }
        fixture.inventory.invalidate(processIdentifier: fixture.pid, reason: .titleChanged)
        await fulfillment(of: [refreshed], timeout: 1)
        await drainMainQueue()

        XCTAssertEqual(fixture.inventoryReads, [fixture.pid])
        XCTAssertEqual(fixture.displayedIDs, [1, 2])
        XCTAssertTrue(try fixture.tiles().first { $0.info.windowID == 1 } === tile)
        XCTAssertEqual(tile.info.title, "Renamed document")
        XCTAssertTrue(tile.subviews.compactMap { $0 as? NSImageView }.contains { $0.image === image })
    }

    func testWindowEventsRefreshOnlyTheSelectedApplicationAndCoalesce() async {
        let fixture = Fixture()
        defer { fixture.stop() }
        fixture.windows = [fixture.window(1), fixture.window(2)]
        fixture.show()
        XCTAssertEqual(fixture.panel.displayedWindowCount, 2)

        fixture.windows = [fixture.window(2), fixture.window(3), fixture.window(4)]
        fixture.inventory.invalidate(processIdentifier: fixture.pid - 1, reason: .created)
        fixture.inventory.invalidate(processIdentifier: fixture.pid, reason: .created)
        fixture.inventory.invalidate(processIdentifier: fixture.pid, reason: .destroyed)
        await drainMainQueue()

        XCTAssertEqual(fixture.inventoryReads, [fixture.pid])
        XCTAssertEqual(fixture.displayedIDs, [2, 3, 4])
        XCTAssertEqual(fixture.activityChanges, [true])
    }

    func testFailedReadPreservesCardsButConfirmedEmptyHidesUntilANewWindowAppears() async {
        let fixture = Fixture()
        defer { fixture.stop() }
        fixture.windows = [fixture.window(1)]
        fixture.show()
        fixture.windows = nil
        fixture.inventory.invalidate(processIdentifier: fixture.pid, reason: .destroyed)
        await drainMainQueue()
        XCTAssertEqual(fixture.displayedIDs, [1])

        fixture.windows = []
        fixture.inventory.invalidate(processIdentifier: fixture.pid, reason: .destroyed)
        await drainMainQueue()
        XCTAssertNil(fixture.panel.frame)

        fixture.windows = [fixture.window(2)]
        fixture.inventory.invalidate(processIdentifier: fixture.pid, reason: .created)
        await drainMainQueue()
        XCTAssertEqual(fixture.displayedIDs, [2])
        XCTAssertEqual(fixture.activityChanges, [true], "Keep the system app switcher interaction alive")
    }

    func testTerminatingTheSelectedApplicationDismissesItsPreview() {
        let fixture = Fixture()
        defer { fixture.stop() }
        fixture.windows = [fixture.window(1)]
        fixture.show()
        fixture.inventory.remove(processIdentifier: fixture.pid - 1)
        XCTAssertEqual(fixture.panel.displayedWindowCount, 1)

        fixture.inventory.remove(processIdentifier: fixture.pid)
        XCTAssertNil(fixture.panel.frame)
        XCTAssertEqual(fixture.activityChanges, [true])
    }

    func testEndingInteractionCancelsQueuedRefreshAndIgnoresLaterEvents() async {
        let fixture = Fixture()
        defer { fixture.stop() }
        fixture.windows = [fixture.window(1)]
        fixture.show()
        fixture.inventory.invalidate(processIdentifier: fixture.pid, reason: .created)
        fixture.service.endInteraction()
        await drainMainQueue()
        fixture.inventory.invalidate(processIdentifier: fixture.pid, reason: .created)
        await drainMainQueue()

        XCTAssertTrue(fixture.inventoryReads.isEmpty)
        XCTAssertNil(fixture.panel.frame)
        XCTAssertEqual(fixture.activityChanges, [true, false])
    }

    func testChangingTargetDiscardsQueuedRefreshForThePreviousApplication() async {
        let fixture = Fixture()
        defer { fixture.stop() }
        fixture.windows = [fixture.window(1)]
        fixture.show()
        fixture.inventory.invalidate(processIdentifier: fixture.pid, reason: .created)
        fixture.windows = [fixture.window(2, pid: fixture.pid - 1)]
        fixture.service.showPreview(for: fixture.target(pid: fixture.pid - 1))
        await drainMainQueue()

        XCTAssertTrue(fixture.inventoryReads.isEmpty)
        XCTAssertEqual(fixture.displayedIDs, [2])
    }

    func testDisablingPreviewsBeforeAQueuedRefreshDoesNotReload() async {
        let fixture = Fixture()
        defer { fixture.stop() }
        fixture.windows = [fixture.window(1)]
        fixture.show()
        fixture.inventory.invalidate(processIdentifier: fixture.pid, reason: .created)
        fixture.settings.showCommandTabPreviews = false
        await drainMainQueue()

        XCTAssertTrue(fixture.inventoryReads.isEmpty)
        XCTAssertNil(fixture.panel.frame)
        XCTAssertEqual(fixture.activityChanges, [true, false])
    }

    func testClosingLastWindowRejectsTheInitialCaptureQuery() async {
        let fixture = Fixture()
        defer { fixture.stop() }
        fixture.hasRecording = true
        fixture.windows = [fixture.window(1)]
        fixture.show()
        XCTAssertEqual(fixture.captureReplies.count, 1)

        fixture.windows = []
        fixture.inventory.invalidate(processIdentifier: fixture.pid, reason: .destroyed)
        await drainMainQueue()
        fixture.windows = [fixture.window(1, minimized: true)]
        fixture.captureReplies.first?(nil, nil)
        await drainMainQueue()

        XCTAssertNil(fixture.panel.frame, "A late query must not resurrect a confirmed closed window")
        XCTAssertTrue(fixture.inventory.windows(for: fixture.pid).isEmpty)
    }

    func testAccessibilityLossBeforeQueuedRefreshEndsInteractionWithoutReadingWindows() async {
        let fixture = Fixture()
        defer { fixture.stop() }
        fixture.windows = [fixture.window(1)]
        fixture.show()
        fixture.inventory.invalidate(processIdentifier: fixture.pid, reason: .created)
        fixture.hasAccessibility = false
        await drainMainQueue()

        XCTAssertTrue(fixture.inventoryReads.isEmpty)
        XCTAssertNil(fixture.panel.frame)
        XCTAssertEqual(fixture.activityChanges, [true, false])
        XCTAssertTrue(fixture.settings.showCommandTabPreviews)
    }

    func testKnownWindowRemovalImmediatelyRemovesOnlyItsCard() async {
        let fixture = Fixture()
        defer { fixture.stop() }
        let first = fixture.window(1)
        let second = fixture.window(2)
        fixture.windows = [first, second]
        fixture.show()
        fixture.windows = [second]
        fixture.inventory.remove(first)
        XCTAssertEqual(fixture.displayedIDs, [2])
        await drainMainQueue()
        XCTAssertEqual(fixture.displayedIDs, [2])
        XCTAssertEqual(fixture.inventoryReads, [fixture.pid])
    }

    func testNewWindowDuringCaptureQueryKeepsAuthoritativeListAndRejectsOldReply() async {
        let fixture = Fixture()
        defer { fixture.stop() }
        fixture.hasRecording = true
        fixture.windows = [fixture.window(1)]
        fixture.show()
        fixture.windows = [fixture.window(2)]
        fixture.inventory.invalidate(processIdentifier: fixture.pid, reason: .created)
        await drainMainQueue()
        XCTAssertEqual(fixture.displayedIDs, [2])
        XCTAssertEqual(fixture.captureReplies.count, 2)
        guard fixture.captureReplies.count == 2 else { return }
        fixture.captureReplies[0](nil, nil)
        await drainMainQueue()
        XCTAssertEqual(fixture.displayedIDs, [2])
        fixture.captureReplies[1](nil, nil)
        await drainMainQueue()
        XCTAssertEqual(fixture.displayedIDs, [2])
    }

    func testSurvivingCardsKeepTheirOrderAndCachedImagesDuringRefresh() async throws {
        let fixture = Fixture()
        defer { fixture.stop() }
        fixture.hasRecording = true
        let image = NSImage(size: NSSize(width: 40, height: 30))
        let first = fixture.window(1, image: image)
        let second = fixture.window(2, image: image)
        fixture.windows = [second, first]
        fixture.previewService.storeCachedSnapshotWindows([second, first], for: fixture.pid)
        fixture.inventory.seed(PreviewWindowSnapshot(windows: [second, first], captureWindows: [:]),
                               for: fixture.target())
        fixture.show()
        XCTAssertEqual(fixture.displayedIDs, [2, 1])

        fixture.windows = [first, second, fixture.window(3)]
        fixture.inventory.invalidate(processIdentifier: fixture.pid, reason: .created)
        await drainMainQueue()
        XCTAssertEqual(fixture.displayedIDs, [2, 1, 3])
        let tiles = try fixture.tiles()
        XCTAssertEqual(tiles.count, 3)
        for tile in tiles {
            XCTAssertTrue(tile.frame.origin.x.isFinite && tile.frame.origin.y.isFinite)
            XCTAssertEqual(tile.bounds.width, tile.preferredTileSize.width, accuracy: 1)
            XCTAssertEqual(tile.bounds.height, tile.preferredTileSize.height, accuracy: 1)
            if tile.info.windowID != 3 {
                XCTAssertTrue(tile.subviews.compactMap { $0 as? NSImageView }.contains { $0.image === image })
            }
        }
        XCTAssertEqual(fixture.captureReplies.count, 1)
        fixture.windows = [first, second]
        fixture.inventory.invalidate(processIdentifier: fixture.pid, reason: .destroyed)
        await drainMainQueue()
        XCTAssertEqual(fixture.displayedIDs, [2, 1])
        for tile in try fixture.tiles() {
            XCTAssertEqual(tile.bounds.width, tile.preferredTileSize.width, accuracy: 1)
            XCTAssertEqual(tile.bounds.height, tile.preferredTileSize.height, accuracy: 1)
            XCTAssertTrue(tiles.contains { $0 === tile }, "Structural changes retain surviving views")
        }
        fixture.service.endInteraction()
        fixture.captureReplies.first?(nil, nil)
        await drainMainQueue()
        XCTAssertNil(fixture.panel.frame)
    }

    private func drainMainQueue() async {
        let drained = expectation(description: "Queued window refresh completed")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 2)
    }

    func testStructuralRefreshDuringMinimizeKeepsCardIdentityOrderAndImage() async throws {
        let fixture = Fixture()
        defer { fixture.stop() }
        fixture.hasRecording = true
        let image = NSImage(size: NSSize(width: 40, height: 30))
        let first = fixture.window(1, image: image)
        let second = fixture.window(2, image: image)
        fixture.windows = [first, second]
        fixture.previewService.storeCachedSnapshotWindows([first, second], for: fixture.pid)
        fixture.inventory.seed(PreviewWindowSnapshot(windows: [first, second], captureWindows: [:]),
                               for: fixture.target())
        fixture.show()
        let original = try XCTUnwrap(fixture.tiles().first { $0.info.windowID == 1 })
        fixture.windows = [PreviewWindowInfo(
            id: "minimized-ax", windowID: nil, processIdentifier: fixture.pid, appName: first.appName,
            title: first.title, frame: first.frame, isMinimized: true
        ), second]
        fixture.inventory.invalidate(processIdentifier: fixture.pid, reason: .destroyed)
        await drainMainQueue()
        XCTAssertEqual(fixture.displayedIDs, [1, 2])
        let minimized = try XCTUnwrap(fixture.tiles().first { $0.info.windowID == 1 })
        XCTAssertTrue(minimized === original)
        XCTAssertTrue(minimized.info.isMinimized)
        XCTAssertTrue(minimized.subviews.compactMap { $0 as? NSImageView }.contains { $0.image === image })

        fixture.windows = [second, first]
        fixture.inventory.invalidate(processIdentifier: fixture.pid, reason: .created)
        await drainMainQueue()
        XCTAssertEqual(fixture.displayedIDs, [1, 2])
        let restored = try XCTUnwrap(fixture.tiles().first { $0.info.windowID == 1 })
        XCTAssertTrue(restored === original)
        XCTAssertFalse(restored.info.isMinimized)
        XCTAssertTrue(restored.subviews.compactMap { $0 as? NSImageView }.contains { $0.image === image })
    }

    @MainActor
    private final class Fixture {
        let pid = pid_t.max
        let settings: SettingsStore
        var windows: [PreviewWindowInfo]?
        var serverWindows: [pid_t: [PreviewWindowInfo]] = [:]
        var inventoryReads: [pid_t] = []
        var hasRecording = false
        var hasAccessibility = true
        var activityChanges: [Bool] = []
        var captureReplies: [(SCShareableContent?, Error?) -> Void] = []
        let panel = PreviewPanelController(requestWindowFocus: { _, _, _, _ in }, requestWindowClose: { _, _, _, _ in })
        lazy var inventory = WindowInventoryService(
            accessibilityWindowsProvider: { [unowned self] pid, _ in
                inventoryReads.append(pid)
                return windows
            }, windowServerWindowsProvider: { [unowned self] in serverWindows }
        )
        lazy var previewService = ScreenCapturePreviewService(
            windowInventory: inventory, hasScreenRecordingPermission: { [unowned self] in hasRecording },
            accessibilityWindows: { [unowned self] _ in windows ?? [] },
            shareableContentLoader: { [unowned self] in captureReplies.append($0) }
        )
        lazy var service = CmdTabPreviewService(
            settings: settings, permissionService: PermissionService(), windowInventory: inventory,
            previewService: previewService, previewPanelController: panel,
            permissionSnapshotProvider: { [unowned self] in
                PermissionSnapshot(accessibility: hasAccessibility, screenRecording: hasRecording, inputMonitoring: true)
            }, onActivityChanged: { [unowned self] in activityChanges.append($0) }
        )

        init() {
            _ = NSApplication.shared
            settings = SettingsStore(defaults: UserDefaults(suiteName: "CmdTabPreviewTests.\(UUID().uuidString)")!)
            settings.showDockPreviews = true
            settings.showCommandTabPreviews = true
        }

        func show() {
            service.beginInteraction()
            service.showPreview(for: target())
        }

        func stop() {
            service.stop()
            inventory.stop()
            panel.hide()
        }

        var displayedIDs: [CGWindowID] {
            panel.commandTabButtonHitTargets().sorted { $0.screenFrame.minX < $1.screenFrame.minX }.compactMap {
                if case let .closeWindow(identity) = $0.action { return identity.windowID }
                return nil
            }
        }

        func tiles() throws -> [PreviewThumbnailView] {
            let window = try XCTUnwrap(NSApp.windows.first { $0.isVisible && $0.frame == panel.frame })
            func descendants(_ view: NSView) -> [NSView] {
                view.subviews.flatMap { [$0] + descendants($0) }
            }
            return descendants(try XCTUnwrap(window.contentView)).compactMap { $0 as? PreviewThumbnailView }
        }

        func target(pid: pid_t? = nil) -> DockAppTarget {
            DockAppTarget(processIdentifier: pid ?? self.pid, bundleIdentifier: "com.example.Editor",
                          localizedName: "Editor", dockElementTitle: "Editor", hitPoint: CGPoint(x: 300, y: 300),
                          previewAnchorKind: .commandTab)
        }

        func window(_ id: CGWindowID, pid: pid_t? = nil, minimized: Bool = false, image: NSImage? = nil) -> PreviewWindowInfo {
            PreviewWindowInfo(id: "window-\(id)", windowID: id, processIdentifier: pid ?? self.pid,
                              appName: "Editor", title: "Document \(id)",
                              frame: CGRect(x: Int(id) * 40, y: 0, width: 800, height: 600),
                              isMinimized: minimized, staticPreviewImage: image)
        }
    }
}
