import AppKit
import CoreImage
import ScreenCaptureKit

enum ShareableContentReusePolicy {
    static func canReuse(
        capturedAt: Date,
        now: Date = Date(),
        maximumAge: TimeInterval
    ) -> Bool {
        let age = now.timeIntervalSince(capturedAt)
        return age >= 0 && age <= maximumAge
    }
}

public final class ScreenCapturePreviewService {
    private struct CachedShareableContent {
        let content: SCShareableContent
        let capturedAt: Date
    }

    private static let shareableContentCacheLifetime: TimeInterval = 0.75

    private let ciContext = CIContext()
    private let windowInventory: WindowInventoryService?
    private let snapshotCache = PreviewSnapshotCache()
    private let snapshotRequests = PreviewCaptureRequestRegistry<any PreviewCaptureSession> { session in
        session.stop()
    }
    private var snapshotCleanupWorkItem: DispatchWorkItem?
    private var cachedShareableContent: CachedShareableContent?
    private var pendingShareableContentCompletions: [(SCShareableContent?, Error?) -> Void] = []
    private var isLoadingShareableContent = false

    public convenience init() {
        self.init(windowInventory: nil)
    }

    init(windowInventory: WindowInventoryService?) {
        self.windowInventory = windowInventory
    }

    func cachedSnapshotWindows(for target: DockAppTarget) -> [PreviewWindowInfo] {
        snapshotCache.windows(for: target.processIdentifier)
    }

    func cachedSnapshotWindows(for processIdentifier: pid_t) -> [PreviewWindowInfo] {
        snapshotCache.windows(for: processIdentifier)
    }

    func storeCachedSnapshotWindows(
        _ windows: [PreviewWindowInfo],
        for processIdentifier: pid_t
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        snapshotCache.store(processIdentifier: processIdentifier, windows: windows)
        scheduleSnapshotCacheCleanup()
    }

    func clearCachedSnapshots(for target: DockAppTarget) {
        dispatchPrecondition(condition: .onQueue(.main))
        snapshotCache.clear(processIdentifier: target.processIdentifier)
        snapshotRequests.clear(processIdentifier: target.processIdentifier)
    }

    func clearCachedSnapshots(for processIdentifier: pid_t) {
        dispatchPrecondition(condition: .onQueue(.main))
        snapshotCache.clear(processIdentifier: processIdentifier)
        snapshotRequests.clear(processIdentifier: processIdentifier)
    }

    func removeCachedSnapshot(matching window: PreviewWindowInfo) {
        dispatchPrecondition(condition: .onQueue(.main))
        MainActor.assumeIsolated {
            windowInventory?.remove(window)
        }
        snapshotCache.removeWindow(
            processIdentifier: window.processIdentifier,
            matching: window
        )
    }

    func clearAllCachedSnapshots() {
        dispatchPrecondition(condition: .onQueue(.main))
        snapshotCache.clearAll()
        cachedShareableContent = nil
        snapshotCleanupWorkItem?.cancel()
        snapshotCleanupWorkItem = nil
        snapshotRequests.clearAll()
    }

    func captureSnapshotsBeforeHide(
        for target: DockAppTarget,
        policy: PreviewCapturePolicy,
        timeout: TimeInterval = 0.18,
        completion: @escaping () -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        let request = snapshotRequests.begin(
            processIdentifier: target.processIdentifier,
            completion: completion
        )
        guard snapshotRequests.isCurrent(request) else {
            return
        }

        var capturedImages: [CGWindowID: NSImage] = [:]
        var visibleSnapshotWindows: [PreviewWindowInfo] = []
        var captureCandidates: [PreviewWindowInfo] = []

        func finish() {
            guard snapshotRequests.isCurrent(request) else {
                return
            }

            let capturedWindows = visibleSnapshotWindows.map { info -> PreviewWindowInfo in
                let image = info.windowID.flatMap { capturedImages[$0] }
                return windowInfo(
                    info,
                    staticPreviewImage: image,
                    placeholderText: image == nil ? AppStrings.text(.previewHiddenNoStatic) : nil
                )
            }
            if !capturedWindows.isEmpty {
                snapshotCache.store(
                    processIdentifier: target.processIdentifier,
                    windows: capturedWindows
                )
                scheduleSnapshotCacheCleanup()
            }
            snapshotRequests.finish(request)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            finish()
        }

        loadWindows(for: target, allowsInventoryReuse: false) { [weak self] bundle in
            guard let self, self.snapshotRequests.isCurrent(request) else {
                return
            }

            visibleSnapshotWindows = Array(bundle.windows.prefix(policy.maxVisibleWindows))
            captureCandidates = visibleSnapshotWindows.filter { info in
                bundle.captureWindows[PreviewWindowIdentity(info)] != nil
            }

            guard !captureCandidates.isEmpty else {
                finish()
                return
            }

            let expectedWindowIDs = Set(captureCandidates.compactMap(\.windowID))
            let imageHandler: (CGWindowID, NSImage) -> Void = { windowID, image in
                guard self.snapshotRequests.isCurrent(request) else {
                    return
                }
                capturedImages[windowID] = image
                if expectedWindowIDs.isSubset(of: Set(capturedImages.keys)) {
                    finish()
                }
            }

            let sessions: [any PreviewCaptureSession]
            if #available(macOS 14.0, *) {
                sessions = self.startStaticCaptureSessions(
                    for: captureCandidates,
                    captureWindows: bundle.captureWindows,
                    policy: policy,
                    imageHandler: imageHandler,
                    errorHandler: { _ in }
                )
            } else {
                sessions = self.startLiveCaptureSessions(
                    for: captureCandidates,
                    captureWindows: bundle.captureWindows,
                    policy: policy,
                    imageHandler: imageHandler,
                    errorHandler: { _ in }
                )
            }
            self.snapshotRequests.install(sessions, for: request)
        }
    }

    func loadWindows(for target: DockAppTarget, completion: @escaping (PreviewWindowSnapshot) -> Void) {
        loadWindows(for: target, allowsInventoryReuse: true, completion: completion)
    }

    private func loadWindows(
        for target: DockAppTarget,
        allowsInventoryReuse: Bool,
        completion: @escaping (PreviewWindowSnapshot) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        if allowsInventoryReuse,
           let snapshot = MainActor.assumeIsolated({
               windowInventory?.previewSnapshot(for: target)
           }) {
            completion(snapshot)
            return
        }

        let inventoryRequestRevision = MainActor.assumeIsolated {
            windowInventory?.beginSnapshotRequest(for: target)
        }

        shareableContent { [weak self] content, error in
            guard let self else {
                return
            }

            // WindowServer may retain closed surfaces. Sample AX as late as possible so
            // only currently interactive windows can authorize offscreen capture rows.
            let axWindows = PreviewWindowCatalog.stableDisplayOrder(self.loadAXWindows(for: target))
            let unminimizedAXWindows = axWindows.filter { !$0.isMinimized }
            if let error {
                self.completeWindowLoad(PreviewWindowSnapshot(
                    windows: axWindows,
                    captureWindows: [:],
                    message: AppStrings.format(.previewReadFailure, error.localizedDescription)
                ),
                for: target,
                inventoryRequestRevision: inventoryRequestRevision,
                completion: completion
                )
                return
            }

            guard let content else {
                self.completeWindowLoad(PreviewWindowSnapshot(
                    windows: axWindows,
                    captureWindows: [:],
                    message: AppStrings.text(.previewNoContent)
                ),
                for: target,
                inventoryRequestRevision: inventoryRequestRevision,
                completion: completion
                )
                return
            }

            var availableCaptureWindows: [PreviewWindowIdentity: SCWindow] = [:]
            let captureCandidates = content.windows.compactMap { window -> PreviewCaptureWindowCandidate? in
                guard window.owningApplication?.processID == target.processIdentifier else {
                    return nil
                }
                let info = PreviewWindowInfo(
                    id: "sc-\(window.windowID)",
                    windowID: window.windowID,
                    processIdentifier: target.processIdentifier,
                    appName: target.localizedName,
                    title: window.title ?? target.localizedName,
                    frame: window.frame,
                    isMinimized: false
                )
                guard WindowFiltering.hasNormalWindowGeometry(
                    layer: window.windowLayer,
                    frame: window.frame
                ) else {
                    return nil
                }
                availableCaptureWindows[PreviewWindowIdentity(info)] = window
                return PreviewCaptureWindowCandidate(info: info, isOnScreen: window.isOnScreen)
            }

            let reconciledCandidates = PreviewWindowCatalog.reconcileCaptureCandidates(
                axWindows: unminimizedAXWindows,
                candidates: captureCandidates
            )
            let shareableWindows = reconciledCandidates.map(\.info)
            let captureWindowPairs: [(PreviewWindowIdentity, SCWindow)] = reconciledCandidates.compactMap { candidate in
                let identity = PreviewWindowIdentity(candidate.info)
                guard let window = availableCaptureWindows[identity]
                else {
                    return nil
                }
                return (identity, window)
            }
            let captureWindows = Dictionary(uniqueKeysWithValues: captureWindowPairs)

            let windows = PreviewWindowCatalog.mergeForDisplay(
                axWindows: axWindows,
                shareableWindows: shareableWindows
            )
            self.completeWindowLoad(PreviewWindowSnapshot(
                windows: windows,
                captureWindows: captureWindows,
                message: windows.isEmpty ? AppStrings.text(.previewNoNormalWindow) : nil
            ),
            for: target,
            inventoryRequestRevision: inventoryRequestRevision,
            completion: completion
            )
        }
    }

    private func shareableContent(
        completion: @escaping (SCShareableContent?, Error?) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        if let cachedShareableContent,
           ShareableContentReusePolicy.canReuse(
                capturedAt: cachedShareableContent.capturedAt,
                maximumAge: Self.shareableContentCacheLifetime
           ) {
            completion(cachedShareableContent.content, nil)
            return
        }

        pendingShareableContentCompletions.append(completion)
        guard !isLoadingShareableContent else {
            return
        }
        isLoadingShareableContent = true
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: false) { [weak self] content, error in
            DispatchQueue.main.async {
                guard let self else {
                    return
                }
                self.isLoadingShareableContent = false
                if let content {
                    self.cachedShareableContent = CachedShareableContent(
                        content: content,
                        capturedAt: Date()
                    )
                }
                let completions = self.pendingShareableContentCompletions
                self.pendingShareableContentCompletions.removeAll()
                completions.forEach { $0(content, error) }
            }
        }
    }

    private func completeWindowLoad(
        _ snapshot: PreviewWindowSnapshot,
        for target: DockAppTarget,
        inventoryRequestRevision: UInt64?,
        completion: @escaping (PreviewWindowSnapshot) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        MainActor.assumeIsolated {
            windowInventory?.seed(
                snapshot,
                for: target,
                requestRevision: inventoryRequestRevision
            )
        }
        completion(snapshot)
    }

    func startLiveCaptureSessions(
        for windows: [PreviewWindowInfo],
        captureWindows: [PreviewWindowIdentity: SCWindow],
        policy: PreviewCapturePolicy,
        imageHandler: @escaping (CGWindowID, NSImage) -> Void,
        errorHandler: @escaping (String) -> Void
    ) -> [PreviewCaptureSession] {
        PreviewCaptureCandidatePolicy.identities(
            for: windows,
            availableIdentities: Set(captureWindows.keys),
            maximumCount: policy.maxStreamCount
        ).compactMap { identity in
            captureWindows[identity].map { (identity, $0) }
        }.compactMap { identity, window in
            guard let windowID = identity.windowID else {
                return nil
            }
                let session = LivePreviewCaptureSession(
                    windowID: windowID,
                    window: window,
                    policy: policy,
                    context: ciContext,
                    imageHandler: imageHandler,
                    errorHandler: errorHandler
                )
                session.start()
                return session
            }
    }

    @available(macOS 14.0, *)
    private func startStaticCaptureSessions(
        for windows: [PreviewWindowInfo],
        captureWindows: [PreviewWindowIdentity: SCWindow],
        policy: PreviewCapturePolicy,
        imageHandler: @escaping (CGWindowID, NSImage) -> Void,
        errorHandler: @escaping (String) -> Void
    ) -> [PreviewCaptureSession] {
        PreviewCaptureCandidatePolicy.identities(
            for: windows,
            availableIdentities: Set(captureWindows.keys),
            maximumCount: policy.maxStreamCount
        ).compactMap { identity in
            captureWindows[identity].map { (identity, $0) }
        }.compactMap { identity, window in
            guard let windowID = identity.windowID else {
                return nil
            }
                let session = StaticPreviewCaptureSession(
                    windowID: windowID,
                    window: window,
                    policy: policy,
                    imageHandler: imageHandler,
                    errorHandler: errorHandler
                )
                session.start()
                return session
            }
    }

    func startPreviewCaptureSession(
        identity: PreviewWindowIdentity,
        window: SCWindow,
        mode: PreviewCaptureMode,
        policy: PreviewCapturePolicy,
        imageHandler: @escaping (CGWindowID, NSImage) -> Void,
        errorHandler: @escaping (String) -> Void
    ) -> (any PreviewCaptureSession)? {
        guard let windowID = identity.windowID else {
            return nil
        }

        switch mode {
        case .live:
            let session = LivePreviewCaptureSession(
                windowID: windowID,
                window: window,
                policy: policy,
                context: ciContext,
                imageHandler: imageHandler,
                errorHandler: errorHandler
            )
            session.start()
            return session
        case .staticImage:
            let staticPolicy = policy.staticSnapshotPolicy(streamCount: 1)
            if #available(macOS 14.0, *) {
                let session = StaticPreviewCaptureSession(
                    windowID: windowID,
                    window: window,
                    policy: staticPolicy,
                    imageHandler: imageHandler,
                    errorHandler: errorHandler
                )
                session.start()
                return session
            }

            let session = LivePreviewCaptureSession(
                windowID: windowID,
                window: window,
                policy: staticPolicy,
                context: ciContext,
                imageHandler: imageHandler,
                errorHandler: errorHandler
            )
            session.start()
            return session
        }
    }

    private func loadAXWindows(for target: DockAppTarget) -> [PreviewWindowInfo] {
        loadAXWindows(
            processIdentifier: target.processIdentifier,
            appName: target.localizedName,
            target: target
        )
    }

    private func loadAXWindows(
        processIdentifier: pid_t,
        appName: String?,
        target: DockAppTarget
    ) -> [PreviewWindowInfo] {
        AccessibilityPreviewWindowReader.windows(
            for: processIdentifier,
            appName: appName ?? target.localizedName
        )
    }

    private func scheduleSnapshotCacheCleanup() {
        snapshotCleanupWorkItem?.cancel()
        guard let delay = snapshotCache.nextCleanupDelay() else {
            snapshotCleanupWorkItem = nil
            return
        }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }
            self.snapshotCache.removeExpired()
            self.snapshotCleanupWorkItem = nil
            self.scheduleSnapshotCacheCleanup()
        }
        snapshotCleanupWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + delay,
            execute: workItem
        )
    }

    private func windowInfo(
        _ info: PreviewWindowInfo,
        staticPreviewImage: NSImage?,
        placeholderText: String?
    ) -> PreviewWindowInfo {
        PreviewWindowInfo(
            id: info.id,
            windowID: info.windowID,
            processIdentifier: info.processIdentifier,
            appName: info.appName,
            title: info.title,
            frame: info.frame,
            isMinimized: info.isMinimized,
            staticPreviewImage: staticPreviewImage,
            placeholderText: placeholderText
        )
    }

}
