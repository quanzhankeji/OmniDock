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
    private let permissionSnapshotProvider: () -> PermissionSnapshot
    private let windowInventory: WindowInventoryService
    private let previewService: ScreenCapturePreviewService
    private let previewPanelController: PreviewPanelController
    private let onActivityChanged: (Bool) -> Void
    private let captureSessionRegistry = PreviewCaptureSessionRegistry()
    private var requestState = CmdTabPreviewRequestState()
    private var currentWindows: [PreviewWindowInfo] = []
    private var currentImages: [PreviewWindowIdentity: NSImage] = [:]
    private var captureRetryCounts: [PreviewWindowIdentity: Int] = [:]
    private var captureSnapshot: PreviewWindowSnapshot?
    private var currentTarget: DockAppTarget?
    private var isInteractionActive = false
    private var inventoryObserverIdentifier: UUID?
    private var inventoryRefreshWorkItem: DispatchWorkItem?
    private var windowLoadGeneration: UInt64 = 0
    private var permissionObserver: NSObjectProtocol?
    private var lastPermissionSnapshot: PermissionSnapshot?

    private lazy var observer = CmdTabPreviewObserver(
        isFeatureEnabled: { [weak self] in
            guard let self else {
                return false
            }
            return self.settings.showDockPreviews
                && self.settings.showCommandTabPreviews
                && PermissionFeatureGate.isSatisfied(
                    for: .dockPreview,
                    in: self.permissionSnapshotProvider()
                )
        }
    )

    init(
        settings: SettingsStore,
        permissionService: PermissionService,
        windowInventory: WindowInventoryService,
        previewService: ScreenCapturePreviewService,
        previewPanelController: PreviewPanelController,
        permissionSnapshotProvider: (() -> PermissionSnapshot)? = nil,
        onActivityChanged: @escaping (Bool) -> Void
    ) {
        self.settings = settings
        self.permissionSnapshotProvider = permissionSnapshotProvider ?? { permissionService.snapshot() }
        self.windowInventory = windowInventory
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
        observer.onPreviewScroll = { [weak self] invocation, deltaX in
            guard let self, self.accepts(invocation) else { return }
            self.previewPanelController.scrollCommandTabPreview(deltaX: deltaX)
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
        lastPermissionSnapshot = permissionSnapshotProvider()
        if let permissionObserver { NotificationCenter.default.removeObserver(permissionObserver) }
        permissionObserver = NotificationCenter.default.addObserver(
            forName: PermissionService.changedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let snapshot = self.permissionSnapshotProvider()
                let changed = self.lastPermissionSnapshot?.accessibility != snapshot.accessibility
                    || self.lastPermissionSnapshot?.screenRecording != snapshot.screenRecording
                self.lastPermissionSnapshot = snapshot
                guard changed, self.isInteractionActive, let target = self.currentTarget else { return }
                self.showPreview(for: target)
            }
        }
        observer.start()
    }

    func stop() {
        if let permissionObserver { NotificationCenter.default.removeObserver(permissionObserver) }
        permissionObserver = nil
        observer.stop()
        endInteraction()
    }

    func beginInteraction() {
        guard !isInteractionActive else {
            return
        }
        previewPanelController.cancelPendingWindowFocus()
        isInteractionActive = true
        onActivityChanged(true)
        resetPresentation()
        inventoryObserverIdentifier = windowInventory.observeChanges { [weak self] event in
            self?.handleInventoryChange(event)
        }
    }

    func endInteraction() {
        guard isInteractionActive else {
            return
        }
        resetPresentation()
        if let inventoryObserverIdentifier {
            windowInventory.removeChangeObserver(inventoryObserverIdentifier)
        }
        inventoryObserverIdentifier = nil
        isInteractionActive = false
        onActivityChanged(false)
    }

    private var canPresent: Bool {
        isInteractionActive && settings.showCommandTabPreviews
            && PermissionFeatureGate.availability(
                for: .dockPreview, settings: settings, snapshot: permissionSnapshotProvider()
            ).canRun
    }

    func showPreview(for target: DockAppTarget) {
        guard canPresent else {
            endInteraction()
            return
        }

        resetPresentation()
        currentTarget = target

        _ = requestState.begin(targetIdentifier: target.dockTileIdentifier)
        let cachedWindows = previewService.cachedSnapshotWindows(for: target.processIdentifier)
        currentImages = Dictionary(
            cachedWindows.compactMap { window -> (PreviewWindowIdentity, NSImage)? in
                guard let image = window.staticPreviewImage else {
                    return nil
                }
                return (PreviewWindowIdentity(window), image)
            },
            uniquingKeysWith: { first, _ in first }
        )
        loadPreview(for: target, refreshingInventory: false)
    }

    private func loadPreview(for target: DockAppTarget, refreshingInventory: Bool) {
        windowLoadGeneration &+= 1
        publishButtonTargets()
        let loadGeneration = windowLoadGeneration
        let generation = requestState.generation
        let targetIdentifier = target.dockTileIdentifier
        previewService.loadWindows(for: target, requiresFreshContent: refreshingInventory) { [weak self] snapshot in
            guard let self,
                  self.windowLoadGeneration == loadGeneration,
                  self.requestState.accepts(
                    generation: generation,
                    targetIdentifier: targetIdentifier
                  ),
                  self.canPresent
            else {
                return
            }

            if !refreshingInventory {
                self.replaceWindows(snapshot.windows, preservingOrder: false)
            }
            // The refreshed AX list is authoritative. A late capture surface must not
            // restore a closed card or replace an unaffected card's running stream.
            let identities = Set(self.currentWindows.map(PreviewWindowIdentity.init))
            var captureWindows = self.captureSnapshot?.captureWindows ?? [:]
            captureWindows.merge(snapshot.captureWindows) { _, new in new }
            self.captureSnapshot = PreviewWindowSnapshot(
                windows: self.currentWindows,
                captureWindows: captureWindows.filter { identities.contains($0.key) }
            )
            self.refreshPanel(target: target, message: snapshot.message)
            self.reconcileCaptureSessions(
                target: target,
                generation: generation,
                targetIdentifier: targetIdentifier
            )
        }
    }

    private func replaceWindows(_ windows: [PreviewWindowInfo], preservingOrder: Bool) {
        let previousIdentities = Set(currentWindows.map(PreviewWindowIdentity.init))
        var orderedWindows = windows
        if preservingOrder {
            let byIdentity = Dictionary(
                windows.map { (PreviewWindowIdentity($0), $0) }, uniquingKeysWith: { first, _ in first }
            )
            orderedWindows = currentWindows.compactMap { byIdentity[PreviewWindowIdentity($0)] }
                + windows.filter { !previousIdentities.contains(PreviewWindowIdentity($0)) }
        }
        let policy = capturePolicy(windowCount: orderedWindows.count)
        currentWindows = Array(orderedWindows.prefix(policy.maxVisibleWindows))
        let identities = Set(currentWindows.map(PreviewWindowIdentity.init))
        currentImages = currentImages.filter { identities.contains($0.key) }
        captureRetryCounts = captureRetryCounts.filter { identities.contains($0.key) }
        for identity in previousIdentities.subtracting(identities) {
            captureSessionRegistry.remove(identity)
        }
        if let snapshot = captureSnapshot {
            captureSnapshot = PreviewWindowSnapshot(
                windows: currentWindows,
                captureWindows: snapshot.captureWindows.filter { identities.contains($0.key) }
            )
        }
    }

    private func capturePolicy(windowCount: Int) -> PreviewCapturePolicy {
        PreviewCapturePolicy.adaptive(
            livePreviewsEnabled: settings.liveDockPreviewsEnabled, windowCount: windowCount,
            powerState: .current, requestedLiveStreamCount: settings.livePreviewWindowLimit
        )
    }

    private func handleInventoryChange(_ event: WindowInventoryEvent) {
        guard isInteractionActive, let target = currentTarget else { return }
        switch event {
        case let .processTerminated(pid) where pid == target.processIdentifier,
             let .processLaunched(pid) where pid == target.processIdentifier:
            resetPresentation()
        case let .windowRemoved(identity) where identity.processIdentifier == target.processIdentifier:
            replaceWindows(currentWindows.filter { PreviewWindowIdentity($0) != identity }, preservingOrder: true)
            scheduleInventoryRefresh(for: target)
            refreshPanel(target: target, message: nil)
        case let .processInvalidated(pid, reason)
            where pid == target.processIdentifier && (reason == .created || reason == .destroyed || reason == .titleChanged):
            scheduleInventoryRefresh(for: target)
        default:
            break
        }
    }

    private func scheduleInventoryRefresh(for target: DockAppTarget) {
        // Query revisions are separate from capture generations so retained streams
        // can keep delivering frames while an out-of-date window query is rejected.
        windowLoadGeneration &+= 1
        publishButtonTargets()
        guard inventoryRefreshWorkItem == nil else { return }
        let generation = requestState.generation
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.requestState.accepts(generation: generation, targetIdentifier: target.dockTileIdentifier)
            else { return }
            self.inventoryRefreshWorkItem = nil
            guard self.canPresent else { self.endInteraction(); return }
            guard let records = self.windowInventory.reconcileWindows(for: target.processIdentifier) else { return }
            self.replaceWindows(records.map { $0.makePreviewWindowInfo() }, preservingOrder: true)
            self.refreshPanel(target: target, message: nil)
            guard !self.currentWindows.isEmpty, self.permissionSnapshotProvider().screenRecording else { return }
            self.loadPreview(for: target, refreshingInventory: true)
        }
        inventoryRefreshWorkItem = workItem
        DispatchQueue.main.async(execute: workItem)
    }

    private func reconcileCaptureSessions(
        target: DockAppTarget,
        generation: UInt64,
        targetIdentifier: String
    ) {
        guard permissionSnapshotProvider().screenRecording else {
            captureSessionRegistry.stopAll()
            return
        }
        guard let snapshot = captureSnapshot else { return }
        let policy = capturePolicy(windowCount: currentWindows.count)
        let identities = currentWindows.map(PreviewWindowIdentity.init)
        captureSessionRegistry.reconcile(
            orderedIdentities: identities,
            availableIdentities: Set(snapshot.captureWindows.keys),
            sourceSizes: snapshot.captureWindows.mapValues { $0.frame.size },
            policy: policy
        ) { [weak self] identity, mode, sessionPolicy in
            guard let self,
                  let window = snapshot.captureWindows[identity]
            else {
                return nil
            }
            // The registry decides which windows stream and which get a single
            // frame; refusing the live ones here left them with no session at
            // all once the policy started asking for them.
            return self.previewService.startPreviewCaptureSession(
                identity: identity,
                window: window,
                mode: mode,
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
                    self?.handleCaptureFailure(
                        for: identity,
                        target: target,
                        generation: generation,
                        targetIdentifier: targetIdentifier
                    )
                }
            )
        }
    }

    private func handleCaptureFailure(
        for identity: PreviewWindowIdentity,
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
        let retryCount = captureRetryCounts[identity, default: 0]
        guard retryCount < 1 else {
            return
        }
        captureRetryCounts[identity] = retryCount + 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self,
                  self.requestState.accepts(
                    generation: generation,
                    targetIdentifier: targetIdentifier
                  ),
                  self.isInteractionActive,
                  self.currentTarget?.isSameDockTile(as: target) == true,
                  self.currentWindows.contains(where: { PreviewWindowIdentity($0) == identity })
            else {
                return
            }
            self.reconcileCaptureSessions(
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
        guard permissionSnapshotProvider().screenRecording,
              requestState.accepts(
            generation: generation,
            targetIdentifier: targetIdentifier
        ),
        currentWindows.contains(where: { PreviewWindowIdentity($0) == identity }) else {
            return
        }
        captureRetryCounts[identity] = nil
        currentImages[identity] = image
        refreshPanel(target: target, message: nil)
        cacheCurrentImages(for: target.processIdentifier)
    }

    private func refreshPanel(target: DockAppTarget, message: String?) {
        let metadataOnly = !permissionSnapshotProvider().screenRecording
        let displayableWindows = currentWindows.map { window -> PreviewWindowInfo in
            let identity = PreviewWindowIdentity(window)
            if metadataOnly {
                return copy(window, image: nil, placeholderText: AppStrings.text(
                    window.isMinimized ? .previewMinimizedClickRestore : .previewMetadataOnly
                ))
            }
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
            return copy(window, image: nil, placeholderText: AppStrings.text(.previewWindowContentUnavailable))
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
        guard accepts(invocation) else { return }
        previewPanelController.performCommandTabAction(invocation.action)
    }

    private func accepts(_ invocation: CmdTabPreviewButtonInvocation) -> Bool {
        isInteractionActive
            && invocation.requestGeneration == windowLoadGeneration
            && currentTarget?.dockTileIdentifier == invocation.targetIdentifier
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
            requestGeneration: windowLoadGeneration,
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
        replaceWindows(currentWindows.filter { PreviewWindowIdentity($0) != identity }, preservingOrder: true)
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
            isApplicationHidden: window.isApplicationHidden,
            isFullScreen: window.isFullScreen,
            staticPreviewImage: image,
            placeholderText: placeholderText,
            accessibilityReference: window.accessibilityReference
        )
    }

    private func resetPresentation() {
        inventoryRefreshWorkItem?.cancel()
        inventoryRefreshWorkItem = nil
        windowLoadGeneration &+= 1
        requestState.cancel()
        captureSessionRegistry.stopAll()
        captureSnapshot = nil
        currentWindows = []
        currentImages = [:]
        captureRetryCounts = [:]
        currentTarget = nil
        previewPanelController.hide()
        publishButtonTargets()
    }
}
