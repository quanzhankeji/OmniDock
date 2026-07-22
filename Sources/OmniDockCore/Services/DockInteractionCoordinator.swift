import AppKit

enum DockTargetOwnershipPolicy {
    static func shouldHandle(targetProcessIdentifier: pid_t, currentProcessIdentifier: pid_t = getpid()) -> Bool {
        targetProcessIdentifier != currentProcessIdentifier
    }
}

enum DockClickMonitoringPolicy {
    static func shouldInstall(
        isEnabled: Bool,
        hasRequiredPermissions: Bool,
        isSuspended: Bool
    ) -> Bool {
        isEnabled && hasRequiredPermissions && !isSuspended
    }
}

enum PreviewWindowValidationPolicy {
    static let validationInterval: TimeInterval = 0.25
}

enum PreviewRequestValidationPolicy {
    static func accepts(
        responseGeneration: Int,
        currentGeneration: Int,
        isSameDockTile: Bool
    ) -> Bool {
        responseGeneration == currentGeneration && isSameDockTile
    }
}

struct PreviewCaptureRecoveryContext: Equatable {
    let dockTileIdentifier: String
    let contentGeneration: Int
}

enum PreviewCaptureRecoveryAction: Equatable {
    case ignore
    case restartLive
    case retainStatic
}

struct PreviewCaptureRecoveryTracker {
    private var context: PreviewCaptureRecoveryContext?
    private var restartedIdentities: Set<PreviewWindowIdentity> = []
    private var staticIdentities: Set<PreviewWindowIdentity> = []

    mutating func action(
        for identity: PreviewWindowIdentity,
        mode: PreviewCaptureMode,
        expectedContext: PreviewCaptureRecoveryContext,
        currentContext: PreviewCaptureRecoveryContext?,
        isIdentityTracked: Bool
    ) -> PreviewCaptureRecoveryAction {
        guard mode == .live,
              let currentContext,
              currentContext == expectedContext,
              isIdentityTracked
        else {
            return .ignore
        }

        if context != currentContext {
            context = currentContext
            restartedIdentities.removeAll()
            staticIdentities.removeAll()
        }
        guard !staticIdentities.contains(identity) else {
            return .ignore
        }
        if restartedIdentities.insert(identity).inserted {
            return .restartLive
        }
        staticIdentities.insert(identity)
        return .retainStatic
    }

    func forcedStaticIdentities(
        for context: PreviewCaptureRecoveryContext
    ) -> Set<PreviewWindowIdentity> {
        self.context == context ? staticIdentities : []
    }

    func isRetainingStatic(
        _ identity: PreviewWindowIdentity,
        in context: PreviewCaptureRecoveryContext
    ) -> Bool {
        self.context == context && staticIdentities.contains(identity)
    }

    mutating func reset() {
        context = nil
        restartedIdentities.removeAll()
        staticIdentities.removeAll()
    }
}

private final class RetainedStaticPreviewCaptureSession: PreviewCaptureSession {
    func stop() {}
}

struct DockPreviewHoverSuppressionPolicy {
    static func shouldSuspend(
        commandTabPreviewIsActive: Bool,
        windowCycleIsActive: Bool
    ) -> Bool {
        commandTabPreviewIsActive || windowCycleIsActive
    }
}

@MainActor
public final class DockInteractionCoordinator {
    private let settings: SettingsStore
    private let permissionService: PermissionService
    private let dockHitTester: DockHitTester
    private let windowControlService: WindowControlService
    private let previewService: ScreenCapturePreviewService
    private let previewPanelController: PreviewPanelController

    private var clickEventTap: DockClickEventTap?
    private var hoverTimer: Timer?
    private var permissionTimer: Timer?
    private var lastPermissionSnapshot: PermissionSnapshot?
    private var hoverTarget: DockAppTarget?
    private var hoverBeganAt: Date?
    private var shownTarget: DockAppTarget?
    private let captureSessionRegistry = PreviewCaptureSessionRegistry()
    private var previewRequestID = 0
    private var previewExitBeganAt: Date?
    private var shownSnapshot: PreviewWindowSnapshot?
    private var snapshotStabilizer = PreviewWindowSnapshotStabilizer()
    private var contentReadiness = PreviewContentReadinessTracker()
    private var latestPreviewImages: [PreviewWindowIdentity: NSImage] = [:]
    private var previewContentGeneration = 0
    private var captureRecoveryTracker = PreviewCaptureRecoveryTracker()
    private var contentTimeoutWorkItem: DispatchWorkItem?
    private var scheduledContentTimeoutDeadline: Date?
    private var isPreviewValidationInFlight = false
    private var lastPreviewWindowValidationAt: Date?
    private var isClickMonitoringSuspended = false
    private var isCommandTabPreviewActive = false
    private var isWindowCycleActive = false
    private var powerStateObserver: NSObjectProtocol?
    private let proxyOwnerStore: DockProxyOwnerStore
    private let proxyTargetRouter: DockProxyTargetRouter

    public var isDockClickMonitoringActive: Bool {
        clickEventTap != nil
    }

    public init(
        settings: SettingsStore,
        permissionService: PermissionService,
        dockHitTester: DockHitTester,
        windowControlService: WindowControlService,
        previewService: ScreenCapturePreviewService,
        previewPanelController: PreviewPanelController
    ) {
        self.settings = settings
        self.permissionService = permissionService
        self.dockHitTester = dockHitTester
        self.windowControlService = windowControlService
        self.previewService = previewService
        self.previewPanelController = previewPanelController
        let proxyOwnerStore = DockProxyOwnerStore()
        self.proxyOwnerStore = proxyOwnerStore
        self.proxyTargetRouter = DockProxyTargetRouter(ownerStore: proxyOwnerStore)
        previewPanelController.onWindowClosed = { [weak self] window in
            guard let self else {
                return
            }
            let identity = PreviewWindowIdentity(window)
            self.previewService.removeCachedSnapshot(matching: window)
            self.captureSessionRegistry.remove(identity)
            self.contentReadiness.remove(identity)
            self.latestPreviewImages[identity] = nil
            self.shownSnapshot = self.shownSnapshot?.removing(identity)
            self.snapshotStabilizer.reset(acceptedIdentities: self.shownSnapshot?.identities)
            self.lastPreviewWindowValidationAt = nil
            if self.shownSnapshot?.windows.isEmpty == true {
                let target = self.shownTarget
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.shownSnapshot?.windows.isEmpty == true else {
                        return
                    }
                    self.hidePreview()
                    self.hoverTarget = target
                    self.hoverBeganAt = nil
                }
            } else if let target = self.shownTarget, let snapshot = self.shownSnapshot {
                self.refreshPreviewPanel(target: target, snapshot: snapshot)
                guard self.shownTarget?.isSameDockTile(as: target) == true else {
                    return
                }
                self.reconcileCaptureSessions(for: snapshot)
                self.scheduleContentTimeoutIfNeeded()
            }
        }
        previewPanelController.onPreviewLifecycleEndRequested = { [weak self] in
            self?.endPreviewLifecycleForWindowFocus()
        }
        previewPanelController.onApplicationQuitRequested = { [weak self] processIdentifier in
            self?.previewService.clearCachedSnapshots(for: processIdentifier)
        }
    }

    public func start() {
        stop()
        lastPermissionSnapshot = permissionService.snapshot()
        synchronizeClickEventTap()
        installHoverTimer()
        installPermissionTimer()
        installPowerStateObserver()
    }

    public func stop() {
        clickEventTap?.stop()
        clickEventTap = nil
        hoverTimer?.invalidate()
        hoverTimer = nil
        permissionTimer?.invalidate()
        permissionTimer = nil
        if let powerStateObserver {
            NotificationCenter.default.removeObserver(powerStateObserver)
            self.powerStateObserver = nil
        }
        resetPreviewContentState()
        captureSessionRegistry.stopAll()
        previewService.clearAllCachedSnapshots()
        proxyTargetRouter.removeAll()
    }

    public func refreshForSettingsChange() {
        synchronizeClickEventTap()
        if !settings.showDockPreviews {
            hidePreview()
            previewService.clearAllCachedSnapshots()
        } else if let shownTarget, let shownSnapshot {
            refreshPreviewPanel(target: shownTarget, snapshot: shownSnapshot)
            guard self.shownTarget?.isSameDockTile(as: shownTarget) == true else {
                return
            }
            reconcileCaptureSessions(for: shownSnapshot)
            scheduleContentTimeoutIfNeeded()
        }
    }

    public func suspendDockClickMonitoring() {
        isClickMonitoringSuspended = true
        synchronizeClickEventTap()
        hidePreview()
        hoverTarget = nil
        hoverBeganAt = nil
        proxyTargetRouter.removeAll()
    }

    public func resumeDockClickMonitoring() {
        guard isClickMonitoringSuspended else {
            return
        }
        isClickMonitoringSuspended = false
        synchronizeClickEventTap()
    }

    public func setCommandTabPreviewActive(_ isActive: Bool) {
        guard isCommandTabPreviewActive != isActive else {
            return
        }
        isCommandTabPreviewActive = isActive
        if isActive {
            hidePreview()
            hoverTarget = nil
            hoverBeganAt = nil
        }
    }

    public func setWindowCycleActive(_ isActive: Bool) {
        guard isWindowCycleActive != isActive else {
            return
        }
        isWindowCycleActive = isActive
        if isActive {
            // The switcher temporarily owns the shared preview panel.
            hidePreview()
            hoverTarget = nil
            hoverBeganAt = nil
        }
    }

    public func refreshPermissionsAndMonitors() {
        lastPermissionSnapshot = permissionService.snapshot()
        hidePreview()
        hoverTarget = nil
        hoverBeganAt = nil
        shownTarget = nil
        previewService.clearAllCachedSnapshots()
        proxyTargetRouter.removeAll()

        clickEventTap?.stop()
        clickEventTap = nil
        synchronizeClickEventTap()
        NotificationCenter.default.post(name: PermissionService.changedNotification, object: nil)
    }

    private func synchronizeClickEventTap() {
        let permissionSnapshot = permissionService.snapshot()
        let shouldInstall = DockClickMonitoringPolicy.shouldInstall(
            isEnabled: settings.toggleAppVisibilityOnDockClick,
            hasRequiredPermissions: PermissionFeatureGate.isSatisfied(
                for: .dockClick,
                in: permissionSnapshot
            ),
            isSuspended: isClickMonitoringSuspended
        )

        guard shouldInstall else {
            clickEventTap?.stop()
            clickEventTap = nil
            return
        }
        guard clickEventTap == nil else {
            return
        }
        installClickEventTap()
    }

    private func installClickEventTap() {
        let permissionSnapshot = permissionService.snapshot()
        guard DockClickMonitoringPolicy.shouldInstall(
            isEnabled: settings.toggleAppVisibilityOnDockClick,
            hasRequiredPermissions: PermissionFeatureGate.isSatisfied(
                for: .dockClick,
                in: permissionSnapshot
            ),
            isSuspended: isClickMonitoringSuspended
        ) else {
            return
        }

        let snapshotService = DockInteractionSnapshotService(
            dockHitTester: dockHitTester,
            windowControlService: windowControlService,
            proxyOwnerStore: proxyOwnerStore
        )
        let tap = DockClickEventTap(
            settings: settings,
            snapshotService: snapshotService,
            actionHandler: { [weak self] target in
                self?.performDockClickToggle(target: target)
            }
        )
        guard tap.start() else {
            let snapshot = permissionService.snapshot()
            NSLog(
                "OmniDock dock click monitoring unavailable. Accessibility: \(snapshot.accessibility), Input Monitoring: \(snapshot.inputMonitoring)"
            )
            return
        }
        clickEventTap = tap
    }

    private func installHoverTimer() {
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleHoverTick()
            }
        }
        if let hoverTimer {
            RunLoop.main.add(hoverTimer, forMode: .common)
        }
    }

    private func installPermissionTimer() {
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handlePermissionTick()
            }
        }
        if let permissionTimer {
            RunLoop.main.add(permissionTimer, forMode: .common)
        }
    }

    private func installPowerStateObserver() {
        powerStateObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name.NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handlePowerStateChange()
            }
        }
    }

    private func handlePermissionTick() {
        let snapshot = permissionService.snapshot()
        guard snapshot != lastPermissionSnapshot else {
            return
        }
        lastPermissionSnapshot = snapshot
        refreshPermissionsAndMonitors()
    }

    private func handlePowerStateChange() {
        guard shownTarget != nil, let shownSnapshot else {
            return
        }
        reconcileCaptureSessions(for: shownSnapshot)
    }

    private func performDockClickToggle(target: DockAppTarget) {
        guard DockTargetOwnershipPolicy.shouldHandle(
            targetProcessIdentifier: target.processIdentifier
        ) else {
            return
        }
        windowControlService.toggleApplicationDockTile(
            target: target,
            prefersMinimizeInsteadOfHide: settings.minimizeWindowsOnDockClickInsteadOfHide,
            beforeHide: { [weak self] continuation in
                guard let self else {
                    continuation()
                    return
                }
                self.captureSnapshotsBeforeHide(target: target, completion: continuation)
            }
        )
        hidePreview()
    }

    private func handleHoverTick() {
        guard !DockPreviewHoverSuppressionPolicy.shouldSuspend(
            commandTabPreviewIsActive: isCommandTabPreviewActive,
            windowCycleIsActive: isWindowCycleActive
        ) else {
            return
        }
        let point = NSEvent.mouseLocation
        let dockGeometry = DockGeometry()
        let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main

        guard settings.showDockPreviews else {
            hidePreview()
            return
        }

        if dockGeometry.isPointInLikelyDockArea(point, screen: screen),
           let target = dockHitTester.target(at: point) {
            previewExitBeganAt = nil
            let target = resolvedDockTarget(for: target)
            guard DockTargetOwnershipPolicy.shouldHandle(
                targetProcessIdentifier: target.processIdentifier
            ) else {
                hidePreview()
                hoverTarget = nil
                hoverBeganAt = nil
                return
            }
            handleDockHoverTarget(target)
            return
        }

        if shouldRetainPreview(at: point) {
            return
        }

        hidePreview()
        hoverTarget = nil
        hoverBeganAt = nil
    }

    private func handleDockHoverTarget(_ target: DockAppTarget) {
        if hoverTarget?.isSameDockTile(as: target) != true {
            hoverTarget = target
            hoverBeganAt = Date()
            return
        }

        if shownTarget?.isSameDockTile(as: target) == true {
            revalidateShownPreviewIfNeeded(for: target)
            return
        }

        guard let hoverBeganAt,
              Date().timeIntervalSince(hoverBeganAt) >= 0.12
        else {
            return
        }

        showPreview(for: target)
    }

    private func shouldRetainPreview(at point: CGPoint) -> Bool {
        guard let shownTarget else {
            previewExitBeganAt = nil
            return false
        }

        revalidateShownPreviewIfNeeded(for: shownTarget)
        guard self.shownTarget != nil else {
            previewExitBeganAt = nil
            return false
        }

        if previewPanelController.contains(point: point) {
            previewExitBeganAt = nil
            return true
        }

        if let panelFrame = previewPanelController.frame,
           let dockItemFrame = shownTarget.dockItemFrame,
           PreviewHoverRetentionPolicy.isPointInInteractionRegion(
            point,
            dockItemFrame: dockItemFrame,
            panelFrame: panelFrame
           ) {
            previewExitBeganAt = nil
            return true
        }

        let now = Date()
        if let previewExitBeganAt {
            return now.timeIntervalSince(previewExitBeganAt) < PreviewHoverRetentionPolicy.exitGraceDuration
        }

        previewExitBeganAt = now
        return true
    }

    private func resolvedDockTarget(for target: DockAppTarget) -> DockAppTarget {
        let originalHasNormalWindow = windowControlService.hasNormalWindow(
            processIdentifier: target.processIdentifier
        )
        return proxyTargetRouter.resolvedTarget(
            for: target,
            originalNormalWindowCount: originalHasNormalWindow ? 1 : 0
        )
    }

    private func showPreview(for target: DockAppTarget) {
        guard DockTargetOwnershipPolicy.shouldHandle(
            targetProcessIdentifier: target.processIdentifier
        ) else {
            hidePreview()
            return
        }
        let summary = windowControlService.interactionSummary(for: target.processIdentifier)
        let isHidden = NSRunningApplication(processIdentifier: target.processIdentifier)?.isHidden ?? false
        if !isHidden, summary.normalWindowCount == 0 {
            previewService.clearCachedSnapshots(for: target)
            dismissPreviewWithoutResettingHover(target: target)
            return
        }
        let isDisplacedByDesktopReveal = windowControlService.isApplicationDisplacedByDesktopReveal(
            processIdentifier: target.processIdentifier
        )
        if !isHidden,
           !WindowFiltering.shouldShowDockPreview(
            isTopmost: windowControlService.isApplicationTopmost(
                processIdentifier: target.processIdentifier
            ) && !isDisplacedByDesktopReveal,
            isHidden: false,
            normalWindowCount: summary.normalWindowCount,
            unminimizedNormalWindowCount: summary.unminimizedNormalWindowCount
           ) {
            hidePreview()
            hoverTarget = nil
            hoverBeganAt = nil
            return
        }

        prepareToShowPreview(for: target)
        let permission = permissionService.snapshot()
        guard permission.screenRecording else {
            captureSessionRegistry.stopAll()
            resetPreviewContentState()
            shownSnapshot = nil
            previewPanelController.show(
                target: target,
                windows: [],
                message: AppStrings.text(.previewNeedsScreenRecording)
            )
            return
        }

        if isHidden {
            let cachedWindows = previewService.cachedSnapshotWindows(for: target)
            guard !cachedWindows.isEmpty else {
                hidePreview()
                hoverTarget = nil
                hoverBeganAt = nil
                return
            }

            lastPreviewWindowValidationAt = Date()
            previewRequestID += 1
            captureSessionRegistry.stopAll()
            let snapshot = PreviewWindowSnapshot(
                windows: cachedWindows,
                captureWindows: [:]
            )
            shownSnapshot = snapshot
            snapshotStabilizer.reset(acceptedIdentities: snapshot.identities)
            synchronizeContentReadiness(for: snapshot)
            refreshPreviewPanel(target: target, snapshot: snapshot)
            scheduleContentTimeoutIfNeeded()
            return
        } else {
            previewService.clearCachedSnapshots(for: target)
        }

        lastPreviewWindowValidationAt = Date()
        previewRequestID += 1
        let requestID = previewRequestID

        previewService.loadWindows(for: target) { [weak self] bundle in
            guard let self else {
                return
            }
            guard PreviewRequestValidationPolicy.accepts(
                responseGeneration: requestID,
                currentGeneration: self.previewRequestID,
                isSameDockTile: self.shownTarget?.isSameDockTile(as: target) == true
            ) else {
                return
            }

            self.lastPreviewWindowValidationAt = Date()

            guard !bundle.windows.isEmpty else {
                self.previewService.clearCachedSnapshots(for: target)
                self.dismissPreviewWithoutResettingHover(target: target)
                return
            }

            self.shownSnapshot = bundle
            self.snapshotStabilizer.reset(acceptedIdentities: bundle.identities)
            self.synchronizeContentReadiness(for: bundle)
            self.refreshPreviewPanel(target: target, snapshot: bundle)
            guard self.shownTarget?.isSameDockTile(as: target) == true else {
                return
            }
            self.reconcileCaptureSessions(for: bundle)
            self.scheduleContentTimeoutIfNeeded()
        }
    }

    private func hidePreview() {
        previewRequestID += 1
        shownTarget = nil
        previewExitBeganAt = nil
        shownSnapshot = nil
        snapshotStabilizer.reset()
        resetPreviewContentState()
        isPreviewValidationInFlight = false
        lastPreviewWindowValidationAt = nil
        captureSessionRegistry.stopAll()
        previewPanelController.hide()
    }

    private func endPreviewLifecycleForWindowFocus() {
        hidePreview()
        hoverTarget = nil
        hoverBeganAt = nil
    }

    private func revalidateShownPreviewIfNeeded(for target: DockAppTarget) {
        guard shownSnapshot != nil,
              !isPreviewValidationInFlight,
              shownTarget?.isSameDockTile(as: target) == true
        else {
            return
        }

        guard let runningApplication = NSRunningApplication(
            processIdentifier: target.processIdentifier
        ) else {
            previewService.clearCachedSnapshots(for: target)
            dismissPreviewWithoutResettingHover(target: target)
            return
        }

        let now = Date()
        if let lastPreviewWindowValidationAt,
           now.timeIntervalSince(lastPreviewWindowValidationAt) < PreviewWindowValidationPolicy.validationInterval {
            return
        }
        self.lastPreviewWindowValidationAt = now

        if runningApplication.isHidden {
            captureSessionRegistry.stopAll()
            let cachedWindows = previewService.cachedSnapshotWindows(for: target)
            guard !cachedWindows.isEmpty else {
                previewService.clearCachedSnapshots(for: target)
                dismissPreviewWithoutResettingHover(target: target)
                return
            }

            let snapshot = PreviewWindowSnapshot(
                windows: cachedWindows,
                captureWindows: [:]
            )
            shownSnapshot = snapshot
            snapshotStabilizer.reset(acceptedIdentities: snapshot.identities)
            synchronizeContentReadiness(for: snapshot)
            refreshPreviewPanel(target: target, snapshot: snapshot)
            scheduleContentTimeoutIfNeeded()
            return
        }

        isPreviewValidationInFlight = true
        previewRequestID += 1
        let requestID = previewRequestID

        previewService.loadWindows(for: target) { [weak self] snapshot in
            guard let self else {
                return
            }
            guard PreviewRequestValidationPolicy.accepts(
                responseGeneration: requestID,
                currentGeneration: self.previewRequestID,
                isSameDockTile: self.shownTarget?.isSameDockTile(as: target) == true
            ) else {
                return
            }
            self.isPreviewValidationInFlight = false

            switch self.snapshotStabilizer.evaluate(snapshot.identities) {
            case .pending:
                return
            case .unchanged, .apply:
                guard !snapshot.windows.isEmpty else {
                    self.previewService.clearCachedSnapshots(for: target)
                    self.dismissPreviewWithoutResettingHover(target: target)
                    return
                }
                self.applyStableSnapshot(snapshot, to: target)
            }
        }
    }

    private func prepareToShowPreview(for target: DockAppTarget) {
        if shownTarget?.isSameDockTile(as: target) != true {
            previewRequestID += 1
            resetPreviewContentState()
            captureSessionRegistry.stopAll()
            shownSnapshot = nil
            snapshotStabilizer.reset()
            isPreviewValidationInFlight = false
            previewPanelController.hide()
        }
        shownTarget = target
        previewExitBeganAt = nil
    }

    private func applyStableSnapshot(_ snapshot: PreviewWindowSnapshot, to target: DockAppTarget) {
        shownSnapshot = snapshot
        synchronizeContentReadiness(for: snapshot)
        refreshPreviewPanel(target: target, snapshot: snapshot)
        guard shownTarget?.isSameDockTile(as: target) == true else {
            return
        }
        reconcileCaptureSessions(for: snapshot)
        scheduleContentTimeoutIfNeeded()
    }

    private func previewCandidateWindows(in snapshot: PreviewWindowSnapshot) -> [PreviewWindowInfo] {
        Array(snapshot.windows.prefix(previewPolicy(for: snapshot).maxVisibleWindows))
    }

    private func previewPolicy(for snapshot: PreviewWindowSnapshot) -> PreviewCapturePolicy {
        PreviewCapturePolicy.adaptive(
            livePreviewsEnabled: settings.liveDockPreviewsEnabled,
            windowCount: snapshot.windows.count,
            powerState: .current,
            requestedLiveStreamCount: settings.livePreviewWindowLimit
        )
    }

    private func reconcileCaptureSessions(for snapshot: PreviewWindowSnapshot) {
        guard let shownTarget,
              permissionService.snapshot().screenRecording,
              NSRunningApplication(processIdentifier: shownTarget.processIdentifier)?.isHidden != true
        else {
            captureSessionRegistry.stopAll()
            return
        }

        let policy = previewPolicy(for: snapshot)
        let orderedIdentities = previewCandidateWindows(in: snapshot).map(PreviewWindowIdentity.init)
        let availableIdentities = PreviewCaptureAvailabilityPolicy.identities(
            currentCaptureIdentities: Set(snapshot.captureWindows.keys),
            registeredIdentities: captureSessionRegistry.identities,
            contentEligibleIdentities: contentReadiness.captureEligibleIdentities
        )
        let contentGeneration = previewContentGeneration
        let recoveryContext = PreviewCaptureRecoveryContext(
            dockTileIdentifier: shownTarget.dockTileIdentifier,
            contentGeneration: contentGeneration
        )
        captureSessionRegistry.reconcile(
            orderedIdentities: orderedIdentities,
            availableIdentities: availableIdentities,
            sourceSizes: snapshot.captureWindows.mapValues { $0.frame.size },
            policy: policy,
            forcedStaticIdentities: captureRecoveryTracker.forcedStaticIdentities(
                for: recoveryContext
            ),
            onSessionTermination: { [weak self] identity, mode, termination in
                self?.handlePreviewCaptureSessionTermination(
                    identity: identity,
                    mode: mode,
                    termination: termination,
                    expectedContext: recoveryContext
                )
            }
        ) { [weak self] identity, mode, sessionPolicy in
            guard let self else {
                return nil
            }
            if mode == .staticImage,
               self.captureRecoveryTracker.isRetainingStatic(identity, in: recoveryContext),
               self.latestPreviewImages[identity] != nil {
                return RetainedStaticPreviewCaptureSession()
            }
            guard let window = snapshot.captureWindows[identity] else {
                return nil
            }
            return self.previewService.startPreviewCaptureSession(
                identity: identity,
                window: window,
                mode: mode,
                policy: sessionPolicy,
                imageHandler: { [weak self] windowID, image in
                    self?.handleCapturedPreviewImage(
                        identity: identity,
                        windowID: windowID,
                        image: image,
                        generation: contentGeneration
                    )
                },
                errorHandler: { [weak self] message in
                    self?.handlePreviewCaptureError(
                        message,
                        identity: identity,
                        generation: contentGeneration
                    )
                }
            )
        }
    }

    private func synchronizeContentReadiness(for snapshot: PreviewWindowSnapshot) {
        var sources: [PreviewWindowIdentity: PreviewContentSource] = [:]
        for window in previewCandidateWindows(in: snapshot) {
            let identity = PreviewWindowIdentity(window)
            sources[identity] = PreviewContentSourcePolicy.source(
                hasCachedImage: window.staticPreviewImage != nil,
                isMinimized: window.isMinimized,
                hasCaptureWindow: snapshot.captureWindows[identity] != nil
            )
        }

        let activeIdentities = Set(sources.keys)
        latestPreviewImages = latestPreviewImages.filter { activeIdentities.contains($0.key) }
        contentReadiness.synchronize(
            sources: sources,
            now: Date(),
            timeout: PreviewContentTimeoutPolicy.current
        )
    }

    private func displayableWindows(in snapshot: PreviewWindowSnapshot) -> [PreviewWindowInfo] {
        previewCandidateWindows(in: snapshot).compactMap { window in
            let identity = PreviewWindowIdentity(window)
            switch contentReadiness.state(for: identity) {
            case .ready:
                guard let image = latestPreviewImages[identity] ?? window.staticPreviewImage else {
                    return nil
                }
                return PreviewWindowInfo(
                    id: window.id,
                    windowID: window.windowID,
                    processIdentifier: window.processIdentifier,
                    appName: window.appName,
                    title: window.title,
                    frame: window.frame,
                    isMinimized: window.isMinimized,
                    staticPreviewImage: image
                )
            case .textOnly:
                return PreviewWindowInfo(
                    id: window.id,
                    windowID: window.windowID,
                    processIdentifier: window.processIdentifier,
                    appName: window.appName,
                    title: window.title,
                    frame: window.frame,
                    isMinimized: window.isMinimized,
                    placeholderText: window.placeholderText
                )
            case .waiting, .unavailable, nil:
                return nil
            }
        }
    }

    @discardableResult
    private func refreshPreviewPanel(
        target: DockAppTarget,
        snapshot: PreviewWindowSnapshot
    ) -> Bool {
        let windows = displayableWindows(in: snapshot)
        guard !windows.isEmpty else {
            previewPanelController.hide()
            guard !contentReadiness.hasWaitingContent else {
                return true
            }
            dismissPreviewWithoutResettingHover(target: target)
            return false
        }

        if previewPanelController.frame == nil {
            previewPanelController.show(
                target: target,
                windows: windows,
                message: snapshot.message
            )
        } else {
            previewPanelController.update(
                target: target,
                windows: windows,
                message: snapshot.message
            )
        }
        return true
    }

    private func handleCapturedPreviewImage(
        identity: PreviewWindowIdentity,
        windowID: CGWindowID,
        image: NSImage,
        generation: Int
    ) {
        guard PreviewContentGenerationPolicy.accepts(
            responseGeneration: generation,
            currentGeneration: previewContentGeneration,
            isIdentityTracked: contentReadiness.state(for: identity) != nil
        ) else {
            return
        }

        let acceptance = contentReadiness.acceptFrame(for: identity)
        guard acceptance != .rejected else {
            return
        }
        latestPreviewImages[identity] = image

        switch acceptance {
        case .becameReady:
            guard let target = shownTarget, let snapshot = shownSnapshot else {
                return
            }
            refreshPreviewPanel(target: target, snapshot: snapshot)
        case .updatedReady:
            previewPanelController.updatePreview(windowID: windowID, image: image)
        case .rejected:
            break
        }
        scheduleContentTimeoutIfNeeded()
    }

    private func handlePreviewCaptureSessionTermination(
        identity: PreviewWindowIdentity,
        mode: PreviewCaptureMode,
        termination: PreviewCaptureSessionTermination,
        expectedContext: PreviewCaptureRecoveryContext
    ) {
        let action = captureRecoveryTracker.action(
            for: identity,
            mode: mode,
            expectedContext: expectedContext,
            currentContext: activePreviewCaptureRecoveryContext(),
            isIdentityTracked: shownSnapshot?.identities.contains(identity) == true
                && contentReadiness.state(for: identity) != nil
        )
        guard action != .ignore else {
            return
        }

        if let message = termination.message,
           contentReadiness.state(for: identity) == .ready {
            previewPanelController.showTransientMessage(message)
        }
        guard let snapshot = shownSnapshot else {
            return
        }
        reconcileCaptureSessions(for: snapshot)
        scheduleContentTimeoutIfNeeded()
    }

    private func activePreviewCaptureRecoveryContext() -> PreviewCaptureRecoveryContext? {
        guard let shownTarget,
              hoverTarget?.isSameDockTile(as: shownTarget) == true
        else {
            return nil
        }
        return PreviewCaptureRecoveryContext(
            dockTileIdentifier: shownTarget.dockTileIdentifier,
            contentGeneration: previewContentGeneration
        )
    }

    private func handlePreviewCaptureError(
        _ message: String,
        identity: PreviewWindowIdentity,
        generation: Int
    ) {
        guard PreviewContentGenerationPolicy.accepts(
            responseGeneration: generation,
            currentGeneration: previewContentGeneration,
            isIdentityTracked: contentReadiness.state(for: identity) != nil
        ) else {
            return
        }

        if contentReadiness.state(for: identity) == .ready {
            previewPanelController.showTransientMessage(message)
            return
        }
        guard contentReadiness.markUnavailable(identity) else {
            return
        }

        latestPreviewImages[identity] = nil
        captureSessionRegistry.remove(identity)
        guard let target = shownTarget, let snapshot = shownSnapshot else {
            return
        }
        refreshPreviewPanel(target: target, snapshot: snapshot)
        guard shownTarget?.isSameDockTile(as: target) == true else {
            return
        }
        if previewPanelController.frame != nil {
            previewPanelController.showTransientMessage(message)
        }
        reconcileCaptureSessions(for: snapshot)
        scheduleContentTimeoutIfNeeded()
    }

    private func scheduleContentTimeoutIfNeeded() {
        guard let deadline = contentReadiness.nextWaitingDeadline else {
            contentTimeoutWorkItem?.cancel()
            contentTimeoutWorkItem = nil
            scheduledContentTimeoutDeadline = nil
            return
        }
        if let scheduledContentTimeoutDeadline,
           abs(scheduledContentTimeoutDeadline.timeIntervalSince(deadline)) < 0.001,
           contentTimeoutWorkItem != nil {
            return
        }

        contentTimeoutWorkItem?.cancel()
        let generation = previewContentGeneration
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }
            self.contentTimeoutWorkItem = nil
            self.scheduledContentTimeoutDeadline = nil
            self.handleContentTimeout(generation: generation)
        }
        contentTimeoutWorkItem = workItem
        scheduledContentTimeoutDeadline = deadline
        DispatchQueue.main.asyncAfter(
            deadline: .now() + max(0, deadline.timeIntervalSinceNow),
            execute: workItem
        )
    }

    private func handleContentTimeout(generation: Int) {
        guard generation == previewContentGeneration else {
            return
        }
        let expiredIdentities = contentReadiness.expireWaiting(at: Date())
        for identity in expiredIdentities {
            latestPreviewImages[identity] = nil
            captureSessionRegistry.remove(identity)
        }

        guard let target = shownTarget, let snapshot = shownSnapshot else {
            return
        }
        refreshPreviewPanel(target: target, snapshot: snapshot)
        guard shownTarget?.isSameDockTile(as: target) == true else {
            return
        }
        reconcileCaptureSessions(for: snapshot)
        scheduleContentTimeoutIfNeeded()
    }

    private func resetPreviewContentState() {
        previewContentGeneration &+= 1
        captureRecoveryTracker.reset()
        contentReadiness.reset()
        latestPreviewImages.removeAll()
        contentTimeoutWorkItem?.cancel()
        contentTimeoutWorkItem = nil
        scheduledContentTimeoutDeadline = nil
    }

    private func dismissPreviewWithoutResettingHover(target: DockAppTarget) {
        hidePreview()
        hoverTarget = target
        hoverBeganAt = nil
    }

    private func captureSnapshotsBeforeHide(target: DockAppTarget, completion: @escaping () -> Void) {
        guard settings.showDockPreviews,
              permissionService.snapshot().screenRecording
        else {
            completion()
            return
        }

        previewService.captureSnapshotsBeforeHide(
            for: target,
            policy: .hiddenSnapshot(powerState: .current),
            completion: completion
        )
    }

}

enum PreviewHoverRetentionPolicy {
    static let exitGraceDuration: TimeInterval = 0.22

    static func interactionRegion(dockItemFrame: CGRect, panelFrame: CGRect) -> CGRect {
        dockItemFrame
            .union(panelFrame)
            .insetBy(dx: -18, dy: -18)
    }

    static func isPointInInteractionRegion(
        _ point: CGPoint,
        dockItemFrame: CGRect,
        panelFrame: CGRect
    ) -> Bool {
        interactionRegion(dockItemFrame: dockItemFrame, panelFrame: panelFrame).contains(point)
    }
}
