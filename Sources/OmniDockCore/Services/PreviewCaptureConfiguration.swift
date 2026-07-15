import CoreGraphics
import CoreVideo
import ScreenCaptureKit

enum PreviewCapturePurpose {
    case continuousLive
    case singleFrame

    var usesOpaqueOutput: Bool {
        self == .continuousLive
    }
}

enum PreviewCaptureConfiguration {
    static func clampedQueueDepth(_ requestedDepth: Int) -> Int {
        min(8, max(3, requestedDepth))
    }

    static func make(
        for window: SCWindow,
        policy: PreviewCapturePolicy,
        purpose: PreviewCapturePurpose
    ) -> SCStreamConfiguration {
        make(sourceSize: window.frame.size, policy: policy, purpose: purpose)
    }

    static func make(
        sourceSize: CGSize,
        policy: PreviewCapturePolicy,
        purpose: PreviewCapturePurpose
    ) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        let thumbnailSize = policy.thumbnailPixelSize(for: sourceSize)
        configuration.width = Int(thumbnailSize.width)
        configuration.height = Int(thumbnailSize.height)
        configuration.minimumFrameInterval = policy.minimumFrameInterval
        configuration.queueDepth = clampedQueueDepth(policy.queueDepth)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = false
        configuration.scalesToFit = true
        if #available(macOS 14.0, *) {
            configuration.preservesAspectRatio = true
            configuration.ignoreShadowsSingleWindow = true
            configuration.shouldBeOpaque = purpose.usesOpaqueOutput
        }
        return configuration
    }
}
