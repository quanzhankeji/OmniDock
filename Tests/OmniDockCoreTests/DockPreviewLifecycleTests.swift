import AppKit
import XCTest
@testable import OmniDockCore

@MainActor
final class DockPreviewLifecycleTests: XCTestCase {
    func testDisplayChangeClosesDockPreviewAndCancelsPendingFocus() {
        let applicationCenter = NotificationCenter()
        var cancellations = 0
        let panel = PreviewPanelController(
            requestWindowFocus: { _, _ in XCTFail("Display changes must not focus a window") },
            requestWindowClose: { _, _, _, _ in },
            cancelWindowFocus: { cancellations += 1 }
        )
        let coordinator = makeCoordinator(panel: panel, applicationNotificationCenter: applicationCenter)
        coordinator.start()
        defer { coordinator.stop(); panel.hide() }
        showPreview(panel: panel, kind: .dock)
        let previousCancellations = cancellations

        applicationCenter.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)

        XCTAssertNil(panel.frame)
        XCTAssertFalse(panel.hasInstalledContentView)
        XCTAssertGreaterThan(cancellations, previousCancellations)
        XCTAssertFalse(coordinator.isDockClickMonitoringActive)
        XCTAssertFalse(coordinator.isDockClickMonitoringSuspended)
    }

    func testScreenSleepClosesDockPreviewAndWakeDoesNotRestoreIt() {
        let center = NotificationCenter()
        let panel = PreviewPanelController(
            requestWindowFocus: { _, _ in XCTFail("Suspension must not focus a window") },
            requestWindowClose: { _, _, _, _ in }
        )
        let coordinator = makeCoordinator(panel: panel, workspaceNotificationCenter: center)
        coordinator.start()
        defer { coordinator.stop(); panel.hide() }
        showPreview(panel: panel, kind: .dock)
        XCTAssertNotNil(panel.frame)

        center.post(name: NSWorkspace.screensDidSleepNotification, object: nil)

        XCTAssertNil(panel.frame)
        XCTAssertFalse(panel.hasInstalledContentView)
        XCTAssertFalse(coordinator.isDockClickMonitoringActive)
        XCTAssertTrue(coordinator.isDockClickMonitoringSuspended)
        coordinator.refreshForSettingsChange()
        coordinator.refreshPermissionsAndMonitors()
        center.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        XCTAssertFalse(coordinator.isDockClickMonitoringSuspended)
        XCTAssertNil(panel.frame)
        XCTAssertFalse(panel.hasInstalledContentView)
    }

    func testStoppingDockServiceClosesItsPanelAndReleasesContent() {
        let panel = PreviewPanelController(
            requestWindowFocus: { _, _ in }, requestWindowClose: { _, _, _, _ in }
        )
        let coordinator = makeCoordinator(panel: panel)
        defer { panel.hide() }
        showPreview(panel: panel, kind: .dock)
        XCTAssertNotNil(panel.frame)

        coordinator.stop()

        XCTAssertNil(panel.frame)
        XCTAssertFalse(panel.hasInstalledContentView)
        coordinator.stop()
        XCTAssertNil(panel.frame)
    }

    func testStoppingDockServiceLeavesAnActiveSwitcherPanelAlone() {
        for kind in [PreviewAnchorKind.commandTab, .windowCycle] {
            let panel = PreviewPanelController(
                requestWindowFocus: { _, _ in }, requestWindowClose: { _, _, _, _ in }
            )
            let coordinator = makeCoordinator(panel: panel)
            defer { panel.hide() }
            if kind == .commandTab {
                coordinator.setCommandTabPreviewActive(true)
            } else {
                coordinator.setWindowCycleActive(true)
            }
            showPreview(panel: panel, kind: kind)

            coordinator.stop()

            XCTAssertNotNil(panel.frame)
            XCTAssertTrue(panel.hasInstalledContentView)
        }
    }

    private func showPreview(panel: PreviewPanelController, kind: PreviewAnchorKind) {
        panel.show(
            target: DockAppTarget(
                processIdentifier: 123, bundleIdentifier: "com.example.Editor", localizedName: "Editor",
                dockElementTitle: "Editor", hitPoint: CGPoint(x: 400, y: 80), previewAnchorKind: kind
            ),
            windows: [PreviewWindowInfo(
                id: "document", windowID: 12, processIdentifier: 123, appName: "Editor",
                title: "Document", frame: CGRect(x: 0, y: 0, width: 800, height: 600), isMinimized: false
            )],
            message: nil
        )
    }

    private func makeCoordinator(
        panel: PreviewPanelController,
        workspaceNotificationCenter: NotificationCenter = NotificationCenter(),
        applicationNotificationCenter: NotificationCenter = NotificationCenter()
    ) -> DockInteractionCoordinator {
        let name = "DockPreviewLifecycleTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        let permissionService = PermissionService()
        let settings = SettingsStore(defaults: defaults)
        settings.toggleAppVisibilityOnDockClick = false
        settings.showDockPreviews = false
        return DockInteractionCoordinator(
            settings: settings,
            permissionService: permissionService,
            dockHitTester: DockHitTester(permissionService: permissionService),
            windowControlService: WindowControlService(),
            previewService: ScreenCapturePreviewService(),
            previewPanelController: panel,
            workspaceNotificationCenter: workspaceNotificationCenter,
            applicationNotificationCenter: applicationNotificationCenter
        )
    }
}
