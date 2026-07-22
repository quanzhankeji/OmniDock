import AppKit

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = SettingsStore()
    private let permissionService = PermissionService()
    private let hotkeyRegistrationStatus = AppHotkeyRegistrationStatusStore()
    private let presentationCoordinator = ApplicationPresentationCoordinator()
    private var permissionFeatureActivationQueue = PermissionFeatureActivationQueue()
    private var isRefreshingPermissionState = false
    private lazy var windowControlService = WindowControlService()
    private lazy var dockHitTester = DockHitTester(permissionService: permissionService)
    private lazy var previewService = ScreenCapturePreviewService()
    private lazy var previewPanelController = PreviewPanelController(
        windowControlService: windowControlService
    )
    private lazy var hotkeyService = AppHotkeyService(
        settings: settings,
        permissionService: permissionService,
        windowControlService: windowControlService,
        previewService: previewService,
        registrationStatus: hotkeyRegistrationStatus
    )
    private lazy var coordinator = DockInteractionCoordinator(
        settings: settings,
        permissionService: permissionService,
        dockHitTester: dockHitTester,
        windowControlService: windowControlService,
        previewService: previewService,
        previewPanelController: previewPanelController
    )
    private lazy var cmdTabPreviewService = CmdTabPreviewService(
        settings: settings,
        permissionService: permissionService,
        previewService: previewService,
        previewPanelController: previewPanelController,
        onActivityChanged: { [weak self] isActive in
            self?.coordinator.setCommandTabPreviewActive(isActive)
        }
    )
    private lazy var statusMenuController = StatusMenuController(
        settings: settings,
        permissionService: permissionService,
        coordinator: coordinator,
        hotkeyRegistrationStatus: hotkeyRegistrationStatus,
        presentationCoordinator: presentationCoordinator,
        onPermissionGateRequired: { [weak self] feature in
            self?.showPermissionOnboarding(for: feature, automaticallyOpenSettings: true)
        },
        onOpenPermissionOnboarding: { [weak self] in
            self?.permissionOnboardingController.show(mode: .review)
        }
    )
    private lazy var permissionOnboardingController = PermissionOnboardingWindowController(
        settings: settings,
        permissionService: permissionService,
        presentationCoordinator: presentationCoordinator,
        onCompleted: { [weak self] in
            self?.refreshAfterPermissionChange()
        },
        onSkipped: { [weak self] in
            self?.enterRestrictedModeForCurrentPermissions()
        },
        onPermissionStatusChanged: { [weak self] in
            self?.refreshAfterPermissionChange()
        }
    )
    private lazy var applicationMainMenuController = ApplicationMainMenuController(
        onOpenSettings: { [weak self] in
            self?.statusMenuController.show(tab: .settings)
        }
    )

    public override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(permissionStatusChanged),
            name: PermissionService.changedNotification,
            object: nil
        )
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        permissionFeatureActivationQueue = PermissionFeatureActivationQueue(
            pendingFeatures: settings.pendingPermissionFeatures
        )
        preparePermissionBackedFeaturesForLaunch()
        applicationMainMenuController.install()
        statusMenuController.install()
        coordinator.start()
        cmdTabPreviewService.start()
        hotkeyService.start()
        showPermissionOnboardingIfNeeded()
    }

    public func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
        hotkeyService.stop()
        cmdTabPreviewService.stop()
        coordinator.stop()
        previewPanelController.hide()
    }

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        permissionOnboardingController.prepareForApplicationTermination()
        return .terminateNow
    }

    @objc private func permissionStatusChanged() {
        refreshPermissionState()
    }

    private func refreshPermissionState() {
        guard !isRefreshingPermissionState else {
            return
        }
        isRefreshingPermissionState = true
        defer { isRefreshingPermissionState = false }

        let snapshot = permissionService.snapshot()
        _ = resolvePendingPermissionFeatures(snapshot: snapshot)
        PermissionFeatureGate.disableUnavailableFeatures(in: settings, snapshot: snapshot)
        maybeRelaunchIfPermissionRefreshDidNotAttach()
    }

    private func preparePermissionBackedFeaturesForLaunch() {
        let snapshot = permissionService.snapshot()
        _ = resolvePendingPermissionFeatures(snapshot: snapshot)
        if PermissionFeatureGate.allOnboardingPermissionsGranted(in: snapshot),
           !settings.permissionOnboardingSkipped {
            settings.permissionOnboardingCompleted = true
            return
        }

        PermissionFeatureGate.disableUnavailableFeatures(in: settings, snapshot: snapshot)
    }

    private func showPermissionOnboardingIfNeeded() {
        let snapshot = permissionService.snapshot()
        guard !PermissionFeatureGate.allOnboardingPermissionsGranted(in: snapshot) else {
            return
        }

        if !settings.permissionOnboardingCompleted && !settings.permissionOnboardingSkipped {
            DispatchQueue.main.async { [weak self] in
                self?.permissionOnboardingController.show(mode: .initialSetup)
            }
        } else if settings.permissionOnboardingCompleted {
            DispatchQueue.main.async { [weak self] in
                self?.permissionOnboardingController.show(mode: .review)
            }
        }
    }

    private func showPermissionOnboarding(
        for feature: PermissionFeature,
        automaticallyOpenSettings: Bool
    ) {
        requestPermissionFeature(feature)
        let snapshot = permissionService.snapshot()
        let missingPermission = PermissionFeatureGate.firstMissingPermission(for: feature, in: snapshot)
        permissionOnboardingController.show(
            focus: missingPermission,
            automaticallyOpenSettings: automaticallyOpenSettings,
            mode: .review
        )
    }

    private func requestPermissionFeature(_ feature: PermissionFeature) {
        permissionFeatureActivationQueue.request(feature)
        settings.pendingPermissionFeatures = permissionFeatureActivationQueue.pendingFeatures
    }

    private func resolvePendingPermissionFeatures(
        snapshot: PermissionSnapshot
    ) -> Set<PermissionFeature> {
        let enabled = permissionFeatureActivationQueue.resolve(in: settings, snapshot: snapshot)
        settings.pendingPermissionFeatures = permissionFeatureActivationQueue.pendingFeatures
        return enabled
    }

    private func enterRestrictedModeForCurrentPermissions() {
        let snapshot = permissionService.snapshot()
        PermissionFeatureGate.disableUnavailableFeatures(in: settings, snapshot: snapshot)
        refreshAfterPermissionChange()
    }

    private func refreshAfterPermissionChange() {
        coordinator.refreshPermissionsAndMonitors()
    }

    private func maybeRelaunchIfPermissionRefreshDidNotAttach() {
        let snapshot = permissionService.snapshot()
        let now = Date()
        guard PermissionMonitorRecoveryPolicy.shouldRelaunch(
            isDockClickEnabled: settings.toggleAppVisibilityOnDockClick,
            snapshot: snapshot,
            isMonitoringActive: coordinator.isDockClickMonitoringActive,
            lastRelaunchAttemptAt: settings.lastPermissionRefreshRelaunchAttemptAt,
            now: now
        ) else {
            return
        }

        settings.lastPermissionRefreshRelaunchAttemptAt = now
        permissionOnboardingController.showRefreshingBeforeRelaunch()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            _ = self?.permissionService.relaunchApp()
        }
    }
}
