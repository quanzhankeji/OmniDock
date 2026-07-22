import AppKit
import ApplicationServices
import CoreImage
import ScreenCaptureKit

public final class ScreenCapturePreviewService {
    private let ciContext = CIContext()
    private let snapshotCache = PreviewSnapshotCache()
    private let snapshotRequests = PreviewCaptureRequestRegistry<any PreviewCaptureSession> { session in
        session.stop()
    }
    private var snapshotCleanupWorkItem: DispatchWorkItem?

    public init() {}

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
        snapshotCache.removeWindow(
            processIdentifier: window.processIdentifier,
            matching: window
        )
    }

    func clearAllCachedSnapshots() {
        dispatchPrecondition(condition: .onQueue(.main))
        snapshotCache.clearAll()
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

        loadWindows(for: target) { [weak self] bundle in
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
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: false) { [self] content, error in
            // WindowServer may retain closed surfaces. Sample AX as late as possible so
            // only currently interactive windows can authorize offscreen capture rows.
            let axWindows = PreviewWindowCatalog.stableDisplayOrder(loadAXWindows(for: target))
            let unminimizedAXWindows = axWindows.filter { !$0.isMinimized }
            if let error {
                DispatchQueue.main.async {
                    completion(PreviewWindowSnapshot(
                        windows: axWindows,
                        captureWindows: [:],
                        message: AppStrings.format(.previewReadFailure, error.localizedDescription)
                    ))
                }
                return
            }

            guard let content else {
                DispatchQueue.main.async {
                    completion(PreviewWindowSnapshot(
                        windows: axWindows,
                        captureWindows: [:],
                        message: AppStrings.text(.previewNoContent)
                    ))
                }
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
            DispatchQueue.main.async {
                completion(PreviewWindowSnapshot(
                    windows: windows,
                    captureWindows: captureWindows,
                    message: windows.isEmpty ? AppStrings.text(.previewNoNormalWindow) : nil
                ))
            }
        }
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
        let appElement = AXUIElementCreateApplication(processIdentifier)
        var rawValue: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &rawValue)
        guard error == .success, let windows = rawValue as? [AXUIElement] else {
            return []
        }

        return windows.enumerated().compactMap { index, window -> PreviewWindowInfo? in
            let role = stringAttribute(kAXRoleAttribute, from: window)
            let subrole = stringAttribute(kAXSubroleAttribute, from: window)
            let title = stringAttribute(kAXTitleAttribute, from: window)
            guard WindowFiltering.shouldIncludeAXPreviewWindow(role: role, subrole: subrole, title: title) else {
                return nil
            }

            let windowID = intAttribute("AXWindowNumber", from: window).map { CGWindowID($0) }
            let fallbackID = "ax-\(processIdentifier)-\(index)-\(title ?? appName ?? target.localizedName)"
            return PreviewWindowInfo(
                id: windowID.map { "ax-\($0)" } ?? fallbackID,
                windowID: windowID,
                processIdentifier: processIdentifier,
                appName: appName ?? target.localizedName,
                title: title ?? appName ?? target.localizedName,
                frame: windowFrame(from: window),
                isMinimized: boolAttribute(kAXMinimizedAttribute, from: window) ?? false
            )
        }
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

    private func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue) == .success else {
            return nil
        }
        return rawValue as? String
    }

    private func intAttribute(_ attribute: String, from element: AXUIElement) -> Int? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue) == .success else {
            return nil
        }
        if let number = rawValue as? NSNumber {
            return number.intValue
        }
        return rawValue as? Int
    }

    private func boolAttribute(_ attribute: String, from element: AXUIElement) -> Bool? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue) == .success else {
            return nil
        }
        return rawValue as? Bool
    }

    private func windowFrame(from element: AXUIElement) -> CGRect {
        let origin = pointAttribute(kAXPositionAttribute, from: element) ?? .zero
        let size = sizeAttribute(kAXSizeAttribute, from: element) ?? .zero
        return CGRect(origin: origin, size: size)
    }

    private func pointAttribute(_ attribute: String, from element: AXUIElement) -> CGPoint? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue) == .success,
              let rawValue,
              CFGetTypeID(rawValue) == AXValueGetTypeID()
        else {
            return nil
        }

        let value = rawValue as! AXValue
        var point = CGPoint.zero
        guard AXValueGetValue(value, .cgPoint, &point) else {
            return nil
        }
        return point
    }

    private func sizeAttribute(_ attribute: String, from element: AXUIElement) -> CGSize? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue) == .success,
              let rawValue,
              CFGetTypeID(rawValue) == AXValueGetTypeID()
        else {
            return nil
        }

        let value = rawValue as! AXValue
        var size = CGSize.zero
        guard AXValueGetValue(value, .cgSize, &size) else {
            return nil
        }
        return size
    }
}
