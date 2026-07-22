import AppKit

struct CmdTabPreviewRequestState: Equatable {
    private(set) var generation: UInt64 = 0
    private(set) var targetIdentifier: String?

    mutating func begin(targetIdentifier: String) -> UInt64 {
        generation &+= 1
        self.targetIdentifier = targetIdentifier
        return generation
    }

    mutating func cancel() {
        generation &+= 1
        targetIdentifier = nil
    }

    func accepts(generation: UInt64, targetIdentifier: String) -> Bool {
        self.generation == generation && self.targetIdentifier == targetIdentifier
    }
}

@MainActor
final class CmdTabPreviewService {
    private let settings: SettingsStore
    private let permissionService: PermissionService
    private let previewService: ScreenCapturePreviewService
    private let previewPanelController: PreviewPanelController
    private let onActivityChanged: (Bool) -> Void
    private let captureSessionRegistry = PreviewCaptureSessionRegistry()
    private var requestState = CmdTabPreviewRequestState()
    private var currentWindows: [PreviewWindowInfo] = []
    private var currentImages: [PreviewWindowIdentity: NSImage] = [:]
    private var staticCaptureRetryCounts: [PreviewWindowIdentity: Int] = [:]
    private var currentTarget: DockAppTarget?
    private var isInteractionActive = false

    private lazy var observer = CmdTabPreviewObserver(
        isFeatureEnabled: { [weak self] in
            guard let self else {
                return false
            }
            return self.settings.showDockPreviews
                && self.settings.showCommandTabPreviews
                && PermissionFeatureGate.isSatisfied(
                    for: .dockPreview,
                    in: self.permissionService.snapshot()
                )
        }
    )

    init(
        settings: SettingsStore,
        permissionService: PermissionService,
        previewService: ScreenCapturePreviewService,
        previewPanelController: PreviewPanelController,
        onActivityChanged: @escaping (Bool) -> Void
    ) {
        self.settings = settings
        self.permissionService = permissionService
        self.previewService = previewService
        self.previewPanelController = previewPanelController
        self.onActivityChanged = onActivityChanged

        observer.onInteractionBegan = { [weak self] in
            self?.beginInteraction()
        }
        observer.onSelectionChanged = { [weak self] target in
            self?.showPreview(for: target)
        }
        observer.onSelectionBecameUnavailable = { [weak self] in
            self?.resetPresentation()
        }
        observer.onPreviewButtonAction = { [weak self] invocation in
            self?.performPreviewButtonAction(invocation)
        }
        observer.onPreviewButtonHoverChanged = { [weak self] action in
            self?.previewPanelController.setCommandTabHoveredAction(action)
        }
        observer.onInteractionEnded = { [weak self] in
            self?.endInteraction()
        }
        previewPanelController.setPresentationHandler(
            for: .commandTab,
            onLifecycleEndRequested: { [weak self] in
                self?.observer.cancelInteraction()
            },
            onWindowClosed: { [weak self] window in
                self?.handleConfirmedWindowClose(window)
            },
            onApplicationQuitRequested: { [weak self] processIdentifier in
                self?.previewService.clearCachedSnapshots(for: processIdentifier)
            }
        )
        previewPanelController.onCommandTabButtonTargetsChanged = { [weak self] in
            self?.publishButtonTargets()
        }
    }

    func start() {
        observer.start()
    }

    func stop() {
        observer.stop()
        endInteraction()
    }

    private func beginInteraction() {
        guard !isInteractionActive else {
            return
        }
        isInteractionActive = true
        onActivityChanged(true)
        resetPresentation()
    }

    private func endInteraction() {
        guard isInteractionActive else {
            return
        }
        resetPresentation()
        isInteractionActive = false
        onActivityChanged(false)
    }

    private func showPreview(for target: DockAppTarget) {
        guard isInteractionActive,
              settings.showDockPreviews,
              settings.showCommandTabPreviews,
              PermissionFeatureGate.isSatisfied(
                for: .dockPreview,
                in: permissionService.snapshot()
              )
        else {
            endInteraction()
            return
        }

        guard DockTargetOwnershipPolicy.shouldHandle(
            targetProcessIdentifier: target.processIdentifier
        ) else {
            resetPresentation()
            return
        }

        resetPresentation()
        currentTarget = target

        let targetIdentifier = target.dockTileIdentifier
        let generation = requestState.begin(targetIdentifier: targetIdentifier)
        let cachedWindows = previewService.cachedSnapshotWindows(for: target.processIdentifier)
        let cachedImages = Dictionary(
            cachedWindows.compactMap { window -> (PreviewWindowIdentity, NSImage)? in
                guard let image = window.staticPreviewImage else {
                    return nil
                }
                return (PreviewWindowIdentity(window), image)
            },
            uniquingKeysWith: { first, _ in first }
        )

        previewService.loadWindows(for: target) { [weak self] snapshot in
            guard let self,
                  self.requestState.accepts(
                    generation: generation,
                    targetIdentifier: targetIdentifier
                  ),
                  self.isInteractionActive
            else {
                return
            }

            let policy = PreviewCapturePolicy.adaptive(
                livePreviewsEnabled: false,
                windowCount: snapshot.windows.count,
                powerState: .current
            )
            self.currentWindows = Array(snapshot.windows.prefix(policy.maxVisibleWindows))
            let identities = self.currentWindows.map(PreviewWindowIdentity.init)
            let identitySet = Set(identities)
            self.currentImages = cachedImages.filter { identitySet.contains($0.key) }
            self.refreshPanel(target: target, message: snapshot.message)
            self.reconcileStaticCaptureSessions(
                snapshot: snapshot,
                policy: policy,
                target: target,
                generation: generation,
                targetIdentifier: targetIdentifier
            )
        }
    }

    private func reconcileStaticCaptureSessions(
        snapshot: PreviewWindowSnapshot,
        policy: PreviewCapturePolicy,
        target: DockAppTarget,
        generation: UInt64,
        targetIdentifier: String
    ) {
        let identities = currentWindows.map(PreviewWindowIdentity.init)
        captureSessionRegistry.reconcile(
            orderedIdentities: identities,
            availableIdentities: Set(snapshot.captureWindows.keys),
            sourceSizes: snapshot.captureWindows.mapValues { $0.frame.size },
            policy: policy
        ) { [weak self] identity, mode, sessionPolicy in
            guard let self,
                  mode == .staticImage,
                  let window = snapshot.captureWindows[identity]
            else {
                return nil
            }
            return self.previewService.startPreviewCaptureSession(
                identity: identity,
                window: window,
                mode: .staticImage,
                policy: sessionPolicy,
                imageHandler: { [weak self] _, image in
                    self?.accept(
                        image: image,
                        for: identity,
                        target: target,
                        generation: generation,
                        targetIdentifier: targetIdentifier
                    )
                },
                errorHandler: { [weak self] _ in
                    self?.handleStaticCaptureFailure(
                        for: identity,
                        snapshot: snapshot,
                        policy: policy,
                        target: target,
                        generation: generation,
                        targetIdentifier: targetIdentifier
                    )
                }
            )
        }
    }

    private func handleStaticCaptureFailure(
        for identity: PreviewWindowIdentity,
        snapshot: PreviewWindowSnapshot,
        policy: PreviewCapturePolicy,
        target: DockAppTarget,
        generation: UInt64,
        targetIdentifier: String
    ) {
        guard requestState.accepts(
            generation: generation,
            targetIdentifier: targetIdentifier
        ),
        isInteractionActive,
        currentTarget?.isSameDockTile(as: target) == true,
        currentImages[identity] == nil,
        currentWindows.contains(where: { PreviewWindowIdentity($0) == identity })
        else {
            return
        }

        captureSessionRegistry.remove(identity)
        let retryCount = staticCaptureRetryCounts[identity, default: 0]
        guard retryCount < 1 else {
            return
        }
        staticCaptureRetryCounts[identity] = retryCount + 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self,
                  self.requestState.accepts(
                    generation: generation,
                    targetIdentifier: targetIdentifier
                  ),
                  self.isInteractionActive,
                  self.currentTarget?.isSameDockTile(as: target) == true
            else {
                return
            }
            self.reconcileStaticCaptureSessions(
                snapshot: snapshot,
                policy: policy,
                target: target,
                generation: generation,
                targetIdentifier: targetIdentifier
            )
        }
    }

    private func accept(
        image: NSImage,
        for identity: PreviewWindowIdentity,
        target: DockAppTarget,
        generation: UInt64,
        targetIdentifier: String
    ) {
        guard requestState.accepts(
            generation: generation,
            targetIdentifier: targetIdentifier
        ),
        currentWindows.contains(where: { PreviewWindowIdentity($0) == identity }) else {
            return
        }
        staticCaptureRetryCounts[identity] = nil
        currentImages[identity] = image
        refreshPanel(target: target, message: nil)
        cacheCurrentImages(for: target.processIdentifier)
    }

    private func refreshPanel(target: DockAppTarget, message: String?) {
        let displayableWindows = currentWindows.compactMap { window -> PreviewWindowInfo? in
            let identity = PreviewWindowIdentity(window)
            if let image = currentImages[identity] {
                return copy(window, image: image, placeholderText: nil)
            }
            if window.isMinimized {
                return copy(
                    window,
                    image: nil,
                    placeholderText: AppStrings.text(.previewMinimizedClickRestore)
                )
            }
            return nil
        }
        guard !displayableWindows.isEmpty else {
            previewPanelController.hide()
            publishButtonTargets()
            return
        }

        if previewPanelController.frame == nil {
            previewPanelController.show(
                target: target,
                windows: displayableWindows,
                message: message
            )
        } else {
            previewPanelController.update(
                target: target,
                windows: displayableWindows,
                message: message
            )
        }
        publishButtonTargets()
    }

    private func performPreviewButtonAction(_ invocation: CmdTabPreviewButtonInvocation) {
        guard isInteractionActive,
              let currentTarget,
              requestState.accepts(
                generation: invocation.requestGeneration,
                targetIdentifier: invocation.targetIdentifier
              ),
              currentTarget.dockTileIdentifier == invocation.targetIdentifier
        else {
            return
        }
        previewPanelController.performCommandTabAction(invocation.action)
    }

    private func publishButtonTargets() {
        guard isInteractionActive,
              let currentTarget,
              currentTarget.previewAnchorKind == .commandTab
        else {
            observer.updatePreviewButtonTargets(
                [],
                panelFrame: nil,
                requestGeneration: 0,
                targetIdentifier: ""
            )
            return
        }
        observer.updatePreviewButtonTargets(
            previewPanelController.commandTabButtonHitTargets(),
            panelFrame: previewPanelController.frame,
            requestGeneration: requestState.generation,
            targetIdentifier: currentTarget.dockTileIdentifier
        )
    }

    private func cacheCurrentImages(for processIdentifier: pid_t) {
        let windows = currentWindows.compactMap { window -> PreviewWindowInfo? in
            guard let image = currentImages[PreviewWindowIdentity(window)] else {
                return nil
            }
            return copy(window, image: image, placeholderText: nil)
        }
        guard !windows.isEmpty else {
            return
        }
        previewService.storeCachedSnapshotWindows(windows, for: processIdentifier)
    }

    private func handleConfirmedWindowClose(_ window: PreviewWindowInfo) {
        let identity = PreviewWindowIdentity(window)
        guard currentWindows.contains(where: { PreviewWindowIdentity($0) == identity }) else {
            return
        }
        captureSessionRegistry.remove(identity)
        currentWindows.removeAll { PreviewWindowIdentity($0) == identity }
        currentImages[identity] = nil
        staticCaptureRetryCounts[identity] = nil
        previewService.removeCachedSnapshot(matching: window)
    }

    private func copy(
        _ window: PreviewWindowInfo,
        image: NSImage?,
        placeholderText: String?
    ) -> PreviewWindowInfo {
        PreviewWindowInfo(
            id: window.id,
            windowID: window.windowID,
            processIdentifier: window.processIdentifier,
            appName: window.appName,
            title: window.title,
            frame: window.frame,
            isMinimized: window.isMinimized,
            staticPreviewImage: image,
            placeholderText: placeholderText
        )
    }

    private func resetPresentation() {
        requestState.cancel()
        captureSessionRegistry.stopAll()
        currentWindows = []
        currentImages = [:]
        staticCaptureRetryCounts = [:]
        currentTarget = nil
        previewPanelController.hide()
        publishButtonTargets()
    }
}
