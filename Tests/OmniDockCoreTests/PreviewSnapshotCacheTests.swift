import AppKit
import XCTest
@testable import OmniDockCore

final class PreviewSnapshotCacheTests: XCTestCase {
    func testCachePreservesWindowRowsWithoutImagesWhenAtLeastOneSnapshotExists() {
        let cache = PreviewSnapshotCache(limits: PreviewSnapshotCacheLimits(
            timeToLive: 45,
            maxWindowsPerApplication: 6,
            maxTotalWindows: 12
        ))
        let windows = [
            previewWindow(title: "Window 1", windowID: 1, image: image()),
            previewWindow(title: "Window 2", windowID: 2, image: nil),
            previewWindow(title: "Window 3", windowID: 3, image: nil)
        ]

        cache.store(processIdentifier: 100, windows: windows, capturedAt: Date(timeIntervalSince1970: 10))

        let cached = cache.windows(for: 100, now: Date(timeIntervalSince1970: 20))
        XCTAssertEqual(cached.map(\.title), ["Window 1", "Window 2", "Window 3"])
        XCTAssertNotNil(cached[0].staticPreviewImage)
        XCTAssertNil(cached[1].staticPreviewImage)
    }

    func testCacheIgnoresWindowRowsWhenNoSnapshotsWereCaptured() {
        let cache = PreviewSnapshotCache()

        cache.store(processIdentifier: 100, windows: [
            previewWindow(title: "Window 1", windowID: 1, image: nil),
            previewWindow(title: "Window 2", windowID: 2, image: nil)
        ])

        XCTAssertTrue(cache.windows(for: 100).isEmpty)
    }

    func testBalancedCacheKeepsAllVisibleRowsWhenOnlySomeHaveImages() {
        let cache = PreviewSnapshotCache()
        let windows = (1...PreviewCapturePolicy.normalVisibleWindowLimit).map { index in
            previewWindow(
                title: "Window \(index)",
                windowID: CGWindowID(index),
                image: index <= 6 ? image() : nil
            )
        }

        cache.store(processIdentifier: 100, windows: windows)

        XCTAssertEqual(cache.windows(for: 100).count, PreviewCapturePolicy.normalVisibleWindowLimit)
        XCTAssertEqual(cache.windows(for: 100).compactMap(\.staticPreviewImage).count, 6)
    }

    func testCacheExpiresOldSnapshots() {
        let cache = PreviewSnapshotCache(limits: PreviewSnapshotCacheLimits(
            timeToLive: 30,
            maxWindowsPerApplication: 6,
            maxTotalWindows: 12
        ))

        cache.store(
            processIdentifier: 100,
            windows: [previewWindow(title: "Window", windowID: 1, image: image())],
            capturedAt: Date(timeIntervalSince1970: 0)
        )

        XCTAssertTrue(cache.windows(for: 100, now: Date(timeIntervalSince1970: 31)).isEmpty)
    }

    func testClockRollbackExpiresSnapshotsInsteadOfExtendingTheirLifetime() {
        let cache = PreviewSnapshotCache(limits: PreviewSnapshotCacheLimits(
            timeToLive: 45,
            maxWindowsPerApplication: 6,
            maxTotalWindows: 12
        ))
        cache.store(
            processIdentifier: 100,
            windows: [previewWindow(title: "Window", windowID: 1, image: image())],
            capturedAt: Date(timeIntervalSince1970: 100)
        )

        XCTAssertTrue(cache.windows(
            for: 100,
            now: Date(timeIntervalSince1970: 90)
        ).isEmpty)
        XCTAssertNil(cache.nextCleanupDelay(now: Date(timeIntervalSince1970: 90)))
    }

    func testCleanupDelayTracksOldestSnapshotInsteadOfLatestStore() {
        let cache = PreviewSnapshotCache(limits: PreviewSnapshotCacheLimits(
            timeToLive: 45,
            maxWindowsPerApplication: 6,
            maxTotalWindows: 12
        ))
        cache.store(
            processIdentifier: 100,
            windows: [previewWindow(title: "Old", windowID: 1, image: image())],
            capturedAt: Date(timeIntervalSince1970: 0)
        )
        cache.store(
            processIdentifier: 200,
            windows: [previewWindow(title: "New", windowID: 2, image: image())],
            capturedAt: Date(timeIntervalSince1970: 40)
        )

        XCTAssertEqual(
            cache.nextCleanupDelay(now: Date(timeIntervalSince1970: 40)),
            5
        )
        cache.removeExpired(now: Date(timeIntervalSince1970: 46))
        XCTAssertTrue(cache.windows(for: 100, now: Date(timeIntervalSince1970: 46)).isEmpty)
        XCTAssertEqual(
            cache.nextCleanupDelay(now: Date(timeIntervalSince1970: 46)),
            39
        )
    }

    func testCacheLimitsWindowsPerApplication() {
        let cache = PreviewSnapshotCache(limits: PreviewSnapshotCacheLimits(
            timeToLive: 45,
            maxWindowsPerApplication: 2,
            maxTotalWindows: 12
        ))
        let windows = (1...4).map { index in
            previewWindow(title: "Window \(index)", windowID: CGWindowID(index), image: image())
        }

        cache.store(processIdentifier: 100, windows: windows)

        XCTAssertEqual(cache.windows(for: 100).map(\.title), ["Window 1", "Window 2"])
    }

    func testCacheDropsOldestApplicationsWhenTotalWindowLimitIsExceeded() {
        let cache = PreviewSnapshotCache(limits: PreviewSnapshotCacheLimits(
            timeToLive: 45,
            maxWindowsPerApplication: 6,
            maxTotalWindows: 2
        ))

        cache.store(
            processIdentifier: 100,
            windows: [previewWindow(title: "Old", windowID: 1, image: image())],
            capturedAt: Date(timeIntervalSince1970: 1)
        )
        cache.store(
            processIdentifier: 200,
            windows: [
                previewWindow(title: "New 1", windowID: 2, image: image()),
                previewWindow(title: "New 2", windowID: 3, image: image())
            ],
            capturedAt: Date(timeIntervalSince1970: 2)
        )

        XCTAssertTrue(cache.windows(for: 100, now: Date(timeIntervalSince1970: 3)).isEmpty)
        XCTAssertEqual(cache.windows(for: 200, now: Date(timeIntervalSince1970: 3)).count, 2)
    }

    func testProxyDockIconsShareResolvedApplicationSnapshots() {
        let cache = PreviewSnapshotCache()
        let firstTarget = dockTarget(processIdentifier: 100, identifier: "dock-item:first")
            .proxying(to: 200, bundleIdentifier: "com.example.owner", localizedName: "Owner")
        let secondTarget = dockTarget(processIdentifier: 101, identifier: "dock-item:second")
            .proxying(to: 200, bundleIdentifier: "com.example.owner", localizedName: "Owner")

        cache.store(
            processIdentifier: firstTarget.processIdentifier,
            windows: [previewWindow(title: "Owner Window", windowID: 1, image: image())]
        )

        XCTAssertFalse(firstTarget.isSameDockTile(as: secondTarget))
        XCTAssertEqual(
            cache.windows(for: secondTarget.processIdentifier).map(\.title),
            ["Owner Window"]
        )
    }

    func testClearingApplicationDropsItsSnapshots() {
        let cache = PreviewSnapshotCache()
        cache.store(
            processIdentifier: 100,
            windows: [previewWindow(title: "Window", windowID: 1, image: image())]
        )

        cache.clear(processIdentifier: 100)

        XCTAssertTrue(cache.windows(for: 100).isEmpty)
    }

    func testRemovingWindowKeepsOtherApplicationSnapshots() {
        let cache = PreviewSnapshotCache()
        let first = previewWindow(title: "First", windowID: 1, image: image())
        let second = previewWindow(title: "Second", windowID: 2, image: image())
        cache.store(processIdentifier: 100, windows: [first, second])

        cache.removeWindow(processIdentifier: 100, matching: first)

        XCTAssertEqual(cache.windows(for: 100).map(\.title), ["Second"])
    }

    func testRemovingLastCapturedWindowClearsApplicationSnapshots() {
        let cache = PreviewSnapshotCache()
        let captured = previewWindow(title: "Captured", windowID: 1, image: image())
        let placeholder = previewWindow(title: "Placeholder", windowID: 2, image: nil)
        cache.store(processIdentifier: 100, windows: [captured, placeholder])

        cache.removeWindow(processIdentifier: 100, matching: captured)

        XCTAssertTrue(cache.windows(for: 100).isEmpty)
    }

    func testRemovingFallbackIdentityDoesNotRemoveDifferentWindow() {
        let cache = PreviewSnapshotCache()
        let first = previewWindow(title: "First", windowID: 1, image: image())
        let second = previewWindow(title: "Second", windowID: 2, image: image())
        cache.store(processIdentifier: 100, windows: [first, second])
        let unknown = PreviewWindowInfo(
            id: "unknown-window",
            windowID: nil,
            processIdentifier: 100,
            appName: "Test",
            title: "Unknown",
            frame: .zero,
            isMinimized: false
        )

        cache.removeWindow(processIdentifier: 100, matching: unknown)

        XCTAssertEqual(cache.windows(for: 100).map(\.title), ["First", "Second"])
    }

    private func dockTarget(processIdentifier: pid_t, identifier: String) -> DockAppTarget {
        DockAppTarget(
            processIdentifier: processIdentifier,
            bundleIdentifier: "com.example.\(processIdentifier)",
            localizedName: "Dock Item",
            dockElementTitle: "Owner Window",
            hitPoint: .zero,
            dockTileIdentifierOverride: identifier
        )
    }

    private func previewWindow(title: String, windowID: CGWindowID, image: NSImage?) -> PreviewWindowInfo {
        PreviewWindowInfo(
            id: "window-\(windowID)",
            windowID: windowID,
            processIdentifier: 100,
            appName: "Test",
            title: title,
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            isMinimized: false,
            staticPreviewImage: image
        )
    }

    private func image() -> NSImage {
        NSImage(size: CGSize(width: 24, height: 16))
    }
}
