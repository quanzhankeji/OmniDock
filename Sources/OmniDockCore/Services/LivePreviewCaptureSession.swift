import AppKit
import CoreImage
import CoreMedia
import ScreenCaptureKit

enum PreviewStreamFrameMetadata: Equatable {
    case unavailable
    case status(Int)
    case invalid
}

enum PreviewStreamFrameStatusPolicy {
    static func shouldProcess(_ metadata: PreviewStreamFrameMetadata) -> Bool {
        switch metadata {
        case .unavailable:
            return true
        case let .status(rawValue):
            return SCFrameStatus(rawValue: rawValue) == .complete
        case .invalid:
            return false
        }
    }
}

final class LivePreviewCaptureSession: NSObject,
    PreviewCaptureSession,
    PreviewCaptureSessionTerminationReporting {
    private struct StreamIdentity: Equatable {
        let generation: PreviewCaptureStreamLifecycle<UUID>.Generation
        let sessionIdentifier: UUID
    }

    private final class StreamCallbacks: NSObject, SCStreamOutput, SCStreamDelegate {
        weak var session: LivePreviewCaptureSession?
        let identity: StreamIdentity

        init(session: LivePreviewCaptureSession, identity: StreamIdentity) {
            self.session = session
            self.identity = identity
        }

        func stream(
            _ stream: SCStream,
            didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
            of type: SCStreamOutputType
        ) {
            session?.handleSampleBuffer(
                sampleBuffer,
                type: type,
                from: stream,
                identity: identity
            )
        }

        func stream(_ stream: SCStream, didStopWithError error: Error) {
            session?.handleStreamStopped(
                stream,
                error: error,
                identity: identity
            )
        }
    }

    private struct ActiveStream {
        let stream: SCStream
        let callbacks: StreamCallbacks
        let identity: StreamIdentity
        let legacyStaticStartToken: PreviewCaptureStartLimiter.Token?
    }

    private struct QueuedLegacyStaticStart {
        let identifier: UUID
        let token: PreviewCaptureStartLimiter.Token
    }

    private struct PendingTerminationEvent {
        let identity: StreamIdentity
        let event: PreviewCaptureSessionTerminationEvent
    }

    private static let legacyStaticStartLimiter = PreviewCaptureStartLimiter(
        maximumConcurrentStarts: 3
    )

    private let windowID: CGWindowID
    private let window: SCWindow
    private let continuesAfterFirstFrame: Bool
    private let context: CIContext
    private let imageHandler: (CGWindowID, NSImage) -> Void
    private let errorHandler: (String) -> Void
    private let sampleQueue = DispatchQueue(label: "com.quanzhankeji.OmniDock.preview-stream.sample")
    private let lifecycleQueue = DispatchQueue(label: "com.quanzhankeji.OmniDock.preview-stream.lifecycle")
    private let lifecycleQueueKey = DispatchSpecificKey<UInt8>()
    private var activeStream: ActiveStream?
    private var queuedLegacyStaticStart: QueuedLegacyStaticStart?
    private var fallbackWorkItem: DispatchWorkItem?
    private var fallbackCaptureToken: PreviewCaptureStartLimiter.Token?
    private var terminationHandler: ((PreviewCaptureSessionTerminationEvent) -> Void)?
    private var pendingTerminationEvents: [PendingTerminationEvent] = []
    private var terminalIdentity: StreamIdentity?
    private var lifecycle = PreviewCaptureStreamLifecycle<UUID>()
    private var frameProcessor = PreviewContinuousFrameProcessor()
    private var policy: PreviewCapturePolicy
    private var sourceSize: CGSize

    init(
        windowID: CGWindowID,
        window: SCWindow,
        policy: PreviewCapturePolicy,
        context: CIContext,
        imageHandler: @escaping (CGWindowID, NSImage) -> Void,
        errorHandler: @escaping (String) -> Void
    ) {
        self.windowID = windowID
        self.window = window
        self.continuesAfterFirstFrame = policy.continuesAfterFirstFrame
        self.policy = policy
        self.sourceSize = window.frame.size
        self.context = context
        self.imageHandler = imageHandler
        self.errorHandler = errorHandler
        super.init()
        lifecycleQueue.setSpecific(key: lifecycleQueueKey, value: 1)
    }

    func start() {
        onLifecycleQueueSync {
            startOnLifecycleQueue()
        }
    }

    func stop() {
        onLifecycleQueueSync {
            stopCurrentStreamOnLifecycleQueue()
            cancelTerminationOnLifecycleQueue()
        }
    }

    func setTerminationHandler(
        _ handler: @escaping (PreviewCaptureSessionTerminationEvent) -> Void
    ) {
        let pendingEvents = onLifecycleQueueSync {
            terminationHandler = handler
            let events = pendingTerminationEvents.filter { pendingEvent in
                terminalIdentity == pendingEvent.identity
            }
            pendingTerminationEvents.removeAll()
            return events
        }
        for pendingEvent in pendingEvents {
            enqueueTerminationEventDelivery(
                pendingEvent.event,
                identity: pendingEvent.identity,
                handler: handler
            )
        }
    }

    func update(policy: PreviewCapturePolicy) {
        guard policy.continuesAfterFirstFrame == continuesAfterFirstFrame else {
            return
        }
        onLifecycleQueueSync {
            updateOnLifecycleQueue(policy: policy, sourceSize: sourceSize)
        }
    }

    func update(policy: PreviewCapturePolicy, sourceSize: CGSize) {
        guard policy.continuesAfterFirstFrame == continuesAfterFirstFrame else {
            return
        }

        onLifecycleQueueSync {
            updateOnLifecycleQueue(policy: policy, sourceSize: sourceSize)
        }
    }

    private func updateOnLifecycleQueue(policy: PreviewCapturePolicy, sourceSize: CGSize) {
        let requiresConfigurationUpdate = requiresConfigurationUpdate(
            policy: policy,
            sourceSize: sourceSize
        )
        self.policy = policy
        self.sourceSize = sourceSize
        guard requiresConfigurationUpdate, let activeStream else {
            return
        }

        let configuration = PreviewCaptureConfiguration.make(
            sourceSize: sourceSize,
            policy: policy,
            purpose: continuesAfterFirstFrame ? .continuousLive : .singleFrame
        )
        let identity = activeStream.identity
        activeStream.stream.updateConfiguration(configuration) { [weak self, weak stream = activeStream.stream] error in
            guard let self, let stream else {
                return
            }
            self.lifecycleQueue.async { [weak self, weak stream] in
                guard let self,
                      let stream,
                      let error,
                      self.isCurrentOnLifecycleQueue(identity: identity, stream: stream),
                      !self.lifecycle.isTerminal
                else {
                    return
                }
                self.enqueueTransientErrorDelivery(
                    AppStrings.format(.previewStreamCreateFailure, error.localizedDescription),
                    identity: identity
                )
            }
        }
    }

    private func requiresConfigurationUpdate(
        policy: PreviewCapturePolicy,
        sourceSize: CGSize
    ) -> Bool {
        self.policy.thumbnailPixelSize(for: self.sourceSize) != policy.thumbnailPixelSize(for: sourceSize)
            || self.policy.framesPerSecond != policy.framesPerSecond
            || self.policy.queueDepth != policy.queueDepth
    }

    private func handleSampleBuffer(
        _ sampleBuffer: CMSampleBuffer,
        type: SCStreamOutputType,
        from stream: SCStream,
        identity: StreamIdentity
    ) {
        guard type == .screen,
              sampleBuffer.isValid,
              PreviewStreamFrameStatusPolicy.shouldProcess(frameMetadata(in: sampleBuffer)),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else {
            return
        }

        let generation: PreviewCaptureStreamLifecycle<UUID>.Generation? = onLifecycleQueueSync {
            guard isCurrentOnLifecycleQueue(identity: identity, stream: stream),
                  lifecycle.frameGeneration(for: identity.sessionIdentifier) == identity.generation
            else {
                return nil
            }
            return identity.generation
        }
        guard let generation else {
            return
        }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            return
        }

        guard let image = frameProcessor.image(from: cgImage, generation: generation) else {
            return
        }
        let shouldDeliver = onLifecycleQueueSync {
            guard isCurrentOnLifecycleQueue(identity: identity, stream: stream),
                  lifecycle.acceptFrame(
                    generation: identity.generation,
                    streamIdentifier: identity.sessionIdentifier,
                    continuesAfterFirstFrame: continuesAfterFirstFrame
                  )
            else {
                return false
            }
            cancelFallbackOnLifecycleQueue()
            return true
        }
        guard shouldDeliver else {
            return
        }
        enqueueImageDelivery(
            image,
            identity: identity,
            stopCaptureAfterDelivery: !continuesAfterFirstFrame
        )
    }

    private func handleStreamStopped(
        _ stream: SCStream,
        error: Error,
        identity: StreamIdentity
    ) {
        lifecycleQueue.async { [weak self, weak stream] in
            guard let self,
                  let stream,
                  self.isCurrentOnLifecycleQueue(identity: identity, stream: stream)
            else {
                return
            }
            guard self.lifecycle.acceptError(
                generation: identity.generation,
                streamIdentifier: identity.sessionIdentifier
            ) else {
                return
            }
            self.recoverFromTerminalStreamFailureOnLifecycleQueue(
                AppStrings.format(.previewStreamStop, error.localizedDescription),
                identity: identity
            )
        }
    }

    private func startOnLifecycleQueue() {
        stopCurrentStreamOnLifecycleQueue()
        cancelTerminationOnLifecycleQueue()

        guard requiresLegacyStaticStartLimit else {
            startStreamOnLifecycleQueue(legacyStaticStartToken: nil)
            return
        }

        enqueueLegacyStaticStartOnLifecycleQueue()
    }

    private var requiresLegacyStaticStartLimit: Bool {
        guard !continuesAfterFirstFrame else {
            return false
        }
        if #available(macOS 14.0, *) {
            return false
        }
        return true
    }

    private func enqueueLegacyStaticStartOnLifecycleQueue() {
        let identifier = UUID()
        let token = Self.legacyStaticStartLimiter.enqueue { [weak self] token in
            guard let self else {
                Self.legacyStaticStartLimiter.cancel(token)
                return
            }
            self.lifecycleQueue.async { [weak self] in
                self?.startQueuedLegacyStaticCaptureOnLifecycleQueue(
                    identifier: identifier,
                    token: token
                )
            }
        }
        queuedLegacyStaticStart = QueuedLegacyStaticStart(
            identifier: identifier,
            token: token
        )
    }

    private func startQueuedLegacyStaticCaptureOnLifecycleQueue(
        identifier: UUID,
        token: PreviewCaptureStartLimiter.Token
    ) {
        guard queuedLegacyStaticStart?.identifier == identifier,
              queuedLegacyStaticStart?.token == token
        else {
            Self.legacyStaticStartLimiter.cancel(token)
            return
        }
        queuedLegacyStaticStart = nil
        startStreamOnLifecycleQueue(legacyStaticStartToken: token)
    }

    private func startStreamOnLifecycleQueue(
        legacyStaticStartToken: PreviewCaptureStartLimiter.Token?
    ) {

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = PreviewCaptureConfiguration.make(
            for: window,
            policy: policy,
            purpose: continuesAfterFirstFrame ? .continuousLive : .singleFrame
        )

        let sessionIdentifier = UUID()
        let generation = lifecycle.begin(streamIdentifier: sessionIdentifier)
        let identity = StreamIdentity(
            generation: generation,
            sessionIdentifier: sessionIdentifier
        )
        let callbacks = StreamCallbacks(session: self, identity: identity)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: callbacks)
        activeStream = ActiveStream(
            stream: stream,
            callbacks: callbacks,
            identity: identity,
            legacyStaticStartToken: legacyStaticStartToken
        )

        do {
            try stream.addStreamOutput(callbacks, type: .screen, sampleHandlerQueue: sampleQueue)
        } catch {
            guard lifecycle.acceptError(
                generation: identity.generation,
                streamIdentifier: identity.sessionIdentifier
            ) else {
                return
            }
            recoverFromTerminalStreamFailureOnLifecycleQueue(
                AppStrings.format(.previewStreamCreateFailure, error.localizedDescription),
                identity: identity
            )
            return
        }

        stream.startCapture { [weak self, weak stream] error in
            guard let self, let stream else {
                return
            }
            self.lifecycleQueue.async { [weak self, weak stream] in
                guard let self,
                      let stream,
                      self.isCurrentOnLifecycleQueue(identity: identity, stream: stream)
                else {
                    return
                }

                if let error {
                    guard self.lifecycle.acceptError(
                        generation: identity.generation,
                        streamIdentifier: identity.sessionIdentifier
                    ) else {
                        return
                    }
                    self.recoverFromTerminalStreamFailureOnLifecycleQueue(
                        AppStrings.format(.previewStreamStartFailure, error.localizedDescription),
                        identity: identity
                    )
                } else if self.lifecycle.markRunning(
                    generation: identity.generation,
                    streamIdentifier: identity.sessionIdentifier
                ) {
                    self.scheduleStaticFallbackIfNeeded(identity: identity)
                }
            }
        }
    }

    private func scheduleStaticFallbackIfNeeded(identity: StreamIdentity) {
        guard #available(macOS 14.0, *) else {
            return
        }
        guard lifecycle.canStartFallback(
            generation: identity.generation,
            streamIdentifier: identity.sessionIdentifier
        ) else {
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            self?.startStaticFallbackOnLifecycleQueue(identity: identity)
        }
        fallbackWorkItem = workItem
        lifecycleQueue.asyncAfter(deadline: .now() + 0.6, execute: workItem)
    }

    @available(macOS 14.0, *)
    private func startStaticFallbackOnLifecycleQueue(identity: StreamIdentity) {
        fallbackWorkItem = nil
        guard isCurrentOnLifecycleQueue(identity: identity),
              lifecycle.beginFallback(
            generation: identity.generation,
            streamIdentifier: identity.sessionIdentifier
        ) else {
            return
        }

        fallbackCaptureToken = StaticPreviewCaptureSession.capture(
            windowID: windowID,
            window: window,
            policy: policy,
            imageHandler: { [weak self] _, image in
                self?.lifecycleQueue.async { [weak self] in
                    guard let self,
                          self.isCurrentOnLifecycleQueue(identity: identity),
                          self.lifecycle.acceptFallback(
                            generation: identity.generation,
                            streamIdentifier: identity.sessionIdentifier,
                            continuesAfterFirstFrame: self.continuesAfterFirstFrame
                          )
                    else {
                        return
                    }
                    self.fallbackCaptureToken = nil
                    self.enqueueImageDelivery(
                        image,
                        identity: identity,
                        stopCaptureAfterDelivery: !self.continuesAfterFirstFrame
                    )
                }
            },
            errorHandler: { [weak self] message in
                self?.lifecycleQueue.async { [weak self] in
                    guard let self,
                          self.isCurrentOnLifecycleQueue(identity: identity),
                          self.lifecycle.acceptFallbackError(
                            generation: identity.generation,
                            streamIdentifier: identity.sessionIdentifier,
                            continuesAfterFirstFrame: self.continuesAfterFirstFrame
                          )
                    else {
                        return
                    }
                    self.fallbackCaptureToken = nil
                    guard !self.continuesAfterFirstFrame else {
                        return
                    }
                    self.enqueueErrorDelivery(
                        message,
                        identity: identity,
                        stopCaptureAfterDelivery: true
                    )
                }
            }
        )
    }

    private func recoverFromTerminalStreamFailureOnLifecycleQueue(
        _ message: String,
        identity: StreamIdentity
    ) {
        guard isCurrentOnLifecycleQueue(identity: identity) else {
            return
        }

        if continuesAfterFirstFrame {
            terminalIdentity = identity
            publishTerminationEventOnLifecycleQueue(.streamStopped, identity: identity)
        }

        guard #available(macOS 14.0, *) else {
            enqueueErrorDelivery(
                message,
                identity: identity,
                stopCaptureAfterDelivery: true,
                termination: streamTermination(message: message)
            )
            return
        }

        cancelFallbackOnLifecycleQueue()
        let timeout = DispatchWorkItem { [weak self] in
            guard let self,
                  self.fallbackWorkItem != nil,
                  self.isCurrentOnLifecycleQueue(identity: identity)
            else {
                return
            }
            self.fallbackWorkItem = nil
            self.enqueueErrorDelivery(
                message,
                identity: identity,
                stopCaptureAfterDelivery: true,
                termination: self.streamTermination(message: message)
            )
        }
        fallbackWorkItem = timeout
        lifecycleQueue.asyncAfter(deadline: .now() + 0.6, execute: timeout)

        fallbackCaptureToken = StaticPreviewCaptureSession.capture(
            windowID: windowID,
            window: window,
            policy: policy,
            imageHandler: { [weak self] _, image in
                self?.lifecycleQueue.async { [weak self] in
                    guard let self,
                          self.fallbackWorkItem != nil,
                          self.isCurrentOnLifecycleQueue(identity: identity)
                    else {
                        return
                    }
                    self.fallbackCaptureToken = nil
                    self.cancelFallbackOnLifecycleQueue()
                    self.enqueueImageDelivery(
                        image,
                        identity: identity,
                        stopCaptureAfterDelivery: true,
                        termination: self.streamTermination(message: nil)
                    )
                }
            },
            errorHandler: { [weak self] _ in
                self?.lifecycleQueue.async { [weak self] in
                    guard let self,
                          self.fallbackWorkItem != nil,
                          self.isCurrentOnLifecycleQueue(identity: identity)
                    else {
                        return
                    }
                    self.fallbackCaptureToken = nil
                    self.cancelFallbackOnLifecycleQueue()
                    self.enqueueErrorDelivery(
                        message,
                        identity: identity,
                        stopCaptureAfterDelivery: true,
                        termination: self.streamTermination(message: message)
                    )
                }
            }
        )
    }

    private func enqueueImageDelivery(
        _ image: NSImage,
        identity: StreamIdentity,
        stopCaptureAfterDelivery: Bool,
        termination: PreviewCaptureSessionTermination? = nil
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.onLifecycleQueueSync({
                    self.isCurrentOnLifecycleQueue(identity: identity)
                  })
            else {
                return
            }

            self.imageHandler(self.windowID, image)
            if stopCaptureAfterDelivery {
                self.finishDelivery(
                    identity: identity,
                    stopCapture: true,
                    termination: termination
                )
            }
        }
    }

    private func enqueueErrorDelivery(
        _ message: String,
        identity: StreamIdentity,
        stopCaptureAfterDelivery: Bool,
        termination: PreviewCaptureSessionTermination? = nil
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.onLifecycleQueueSync({
                    self.isCurrentOnLifecycleQueue(identity: identity)
                  })
            else {
                return
            }

            if termination == nil {
                self.errorHandler(message)
            }
            self.finishDelivery(
                identity: identity,
                stopCapture: stopCaptureAfterDelivery,
                termination: termination
            )
        }
    }

    private func enqueueTransientErrorDelivery(
        _ message: String,
        identity: StreamIdentity
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.onLifecycleQueueSync({
                    self.isCurrentOnLifecycleQueue(identity: identity)
                        && !self.lifecycle.isTerminal
                  })
            else {
                return
            }
            self.errorHandler(message)
        }
    }

    private func finishDelivery(
        identity: StreamIdentity,
        stopCapture: Bool,
        termination: PreviewCaptureSessionTermination? = nil
    ) {
        lifecycleQueue.async { [weak self] in
            guard let self,
                  self.isCurrentOnLifecycleQueue(identity: identity)
            else {
                return
            }
            self.retireCurrentStreamOnLifecycleQueue(stopCapture: stopCapture)
            if let termination {
                self.finishTerminationOnLifecycleQueue(termination, identity: identity)
            }
        }
    }

    private func streamTermination(message: String?) -> PreviewCaptureSessionTermination? {
        guard continuesAfterFirstFrame else {
            return nil
        }
        return PreviewCaptureSessionTermination(message: message)
    }

    private func publishTerminationEventOnLifecycleQueue(
        _ event: PreviewCaptureSessionTerminationEvent,
        identity: StreamIdentity
    ) {
        guard terminalIdentity == identity else {
            return
        }
        guard let terminationHandler else {
            pendingTerminationEvents.append(PendingTerminationEvent(
                identity: identity,
                event: event
            ))
            return
        }
        enqueueTerminationEventDelivery(
            event,
            identity: identity,
            handler: terminationHandler
        )
    }

    private func enqueueTerminationEventDelivery(
        _ event: PreviewCaptureSessionTerminationEvent,
        identity: StreamIdentity,
        handler: @escaping (PreviewCaptureSessionTerminationEvent) -> Void
    ) {
        DispatchQueue.main.async {
            guard self.onLifecycleQueueSync({
                guard self.terminalIdentity == identity else {
                    return false
                }
                if case .finished = event {
                    self.terminalIdentity = nil
                    self.pendingTerminationEvents.removeAll { $0.identity == identity }
                }
                return true
            }) else {
                return
            }
            handler(event)
        }
    }

    private func finishTerminationOnLifecycleQueue(
        _ termination: PreviewCaptureSessionTermination,
        identity: StreamIdentity
    ) {
        guard terminalIdentity == identity else {
            return
        }
        guard terminationHandler != nil else {
            pendingTerminationEvents.removeAll()
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.onLifecycleQueueSync({
                        guard self.terminalIdentity == identity else {
                            return false
                        }
                        self.terminalIdentity = nil
                        return true
                      })
                else {
                    return
                }
                if let message = termination.message {
                    self.errorHandler(message)
                }
            }
            return
        }
        publishTerminationEventOnLifecycleQueue(
            .finished(termination),
            identity: identity
        )
    }

    private func isCurrentOnLifecycleQueue(
        identity: StreamIdentity,
        stream: SCStream? = nil
    ) -> Bool {
        guard lifecycle.isCurrent(
            generation: identity.generation,
            streamIdentifier: identity.sessionIdentifier
        ), let activeStream,
              activeStream.identity == identity
        else {
            return false
        }
        guard let stream else {
            return true
        }
        return activeStream.stream === stream
    }

    private func stopCurrentStreamOnLifecycleQueue() {
        cancelQueuedLegacyStaticStartOnLifecycleQueue()
        retireCurrentStreamOnLifecycleQueue(stopCapture: true)
    }

    private func retireCurrentStreamOnLifecycleQueue(stopCapture: Bool) {
        cancelFallbackOnLifecycleQueue()
        let activeStream = self.activeStream
        self.activeStream = nil
        lifecycle.invalidate()
        guard let activeStream else {
            return
        }

        guard stopCapture else {
            if let token = activeStream.legacyStaticStartToken {
                Self.legacyStaticStartLimiter.finish(token)
            }
            return
        }

        if let token = activeStream.legacyStaticStartToken {
            Self.legacyStaticStartLimiter.finish(token) { completion in
                activeStream.stream.stopCapture { _ in
                    completion()
                }
            }
        } else {
            activeStream.stream.stopCapture { _ in }
        }
    }

    private func cancelQueuedLegacyStaticStartOnLifecycleQueue() {
        guard let queuedLegacyStaticStart else {
            return
        }
        self.queuedLegacyStaticStart = nil
        Self.legacyStaticStartLimiter.cancel(queuedLegacyStaticStart.token)
    }

    private func cancelTerminationOnLifecycleQueue() {
        terminalIdentity = nil
        pendingTerminationEvents.removeAll()
    }

    private func cancelFallbackOnLifecycleQueue() {
        fallbackWorkItem?.cancel()
        fallbackWorkItem = nil
        if let fallbackCaptureToken {
            if #available(macOS 14.0, *) {
                StaticPreviewCaptureSession.cancelQueuedCapture(fallbackCaptureToken)
            }
            self.fallbackCaptureToken = nil
        }
    }

    private func frameMetadata(in sampleBuffer: CMSampleBuffer) -> PreviewStreamFrameMetadata {
        guard let rawAttachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) else {
            return .unavailable
        }
        guard let attachments = rawAttachments as? [[SCStreamFrameInfo: Any]],
              let first = attachments.first,
              let rawStatus = first[.status]
        else {
            return .invalid
        }
        if let status = rawStatus as? NSNumber {
            return .status(status.intValue)
        }
        if let status = rawStatus as? Int {
            return .status(status)
        }
        return .invalid
    }

    private func onLifecycleQueueSync<T>(_ body: () -> T) -> T {
        if DispatchQueue.getSpecific(key: lifecycleQueueKey) != nil {
            return body()
        }
        return lifecycleQueue.sync(execute: body)
    }
}
