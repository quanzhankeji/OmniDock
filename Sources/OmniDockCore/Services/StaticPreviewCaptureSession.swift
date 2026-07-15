import AppKit
import ScreenCaptureKit

@available(macOS 14.0, *)
final class StaticPreviewCaptureSession: PreviewCaptureSession {
    private static let captureStartLimiter = PreviewCaptureStartLimiter(
        maximumConcurrentStarts: 3
    )

    private let windowID: CGWindowID
    private let window: SCWindow
    private let policy: PreviewCapturePolicy
    private let imageHandler: (CGWindowID, NSImage) -> Void
    private let errorHandler: (String) -> Void
    private var isStopped = false
    private var captureToken: PreviewCaptureStartLimiter.Token?

    init(
        windowID: CGWindowID,
        window: SCWindow,
        policy: PreviewCapturePolicy,
        imageHandler: @escaping (CGWindowID, NSImage) -> Void,
        errorHandler: @escaping (String) -> Void
    ) {
        self.windowID = windowID
        self.window = window
        self.policy = policy
        self.imageHandler = imageHandler
        self.errorHandler = errorHandler
    }

    func start() {
        captureToken = Self.capture(
            windowID: windowID,
            window: window,
            policy: policy,
            imageHandler: { [weak self] windowID, image in
                guard let self else {
                    return
                }
                self.captureToken = nil
                guard !self.isStopped else {
                    return
                }
                self.imageHandler(windowID, image)
            },
            errorHandler: { [weak self] message in
                guard let self else {
                    return
                }
                self.captureToken = nil
                guard !self.isStopped else {
                    return
                }
                self.errorHandler(message)
            }
        )
    }

    func stop() {
        isStopped = true
        if let captureToken,
           Self.captureStartLimiter.cancelQueued(captureToken) {
            self.captureToken = nil
        }
    }

    @discardableResult
    static func capture(
        windowID: CGWindowID,
        window: SCWindow,
        policy: PreviewCapturePolicy,
        imageHandler: @escaping (CGWindowID, NSImage) -> Void,
        errorHandler: @escaping (String) -> Void
    ) -> PreviewCaptureStartLimiter.Token {
        captureStartLimiter.enqueue { token in
            DispatchQueue.main.async {
                performCapture(
                    token: token,
                    windowID: windowID,
                    window: window,
                    policy: policy,
                    imageHandler: imageHandler,
                    errorHandler: errorHandler
                )
            }
        }
    }

    static func cancelQueuedCapture(_ token: PreviewCaptureStartLimiter.Token) {
        _ = captureStartLimiter.cancelQueued(token)
    }

    private static func performCapture(
        token: PreviewCaptureStartLimiter.Token,
        windowID: CGWindowID,
        window: SCWindow,
        policy: PreviewCapturePolicy,
        imageHandler: @escaping (CGWindowID, NSImage) -> Void,
        errorHandler: @escaping (String) -> Void
    ) {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = PreviewCaptureConfiguration.make(
            for: window,
            policy: policy,
            purpose: .singleFrame
        )

        SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, error in
            captureStartLimiter.finish(token)
            if let error {
                DispatchQueue.main.async {
                    errorHandler(AppStrings.format(.previewStaticFailureWithReason, error.localizedDescription))
                }
                return
            }

            guard let image else {
                DispatchQueue.main.async {
                    errorHandler(AppStrings.text(.previewStaticFailure))
                }
                return
            }

            let previewImage = PreviewCapturedImageProcessor.image(from: image)
            DispatchQueue.main.async {
                imageHandler(windowID, previewImage)
            }
        }
    }
}
