import CoreGraphics
import CoreMedia
import Darwin
import Foundation
import IOKit.ps

struct PreviewPowerState: Equatable {
    let isLowPowerModeEnabled: Bool
    let isOnBatteryPower: Bool

    var prefersReducedPreviewLoad: Bool {
        isLowPowerModeEnabled || isOnBatteryPower
    }

    static var current: PreviewPowerState {
        PreviewPowerState(
            isLowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
            isOnBatteryPower: Self.isCurrentlyOnBatteryPower()
        )
    }

    private static func isCurrentlyOnBatteryPower() -> Bool {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let source = IOPSGetProvidingPowerSourceType(info).takeRetainedValue() as NSString as String
        return source == kIOPMBatteryPowerKey
    }
}

struct PreviewPerformanceProfile: Equatable {
    static let safetyMaximumLiveWindowLimit = 32

    let physicalMemoryBytes: UInt64
    let processorCount: Int
    let chipName: String

    var recommendedLiveWindowLimit: Int {
        let memoryGB = memoryGigabytes
        let normalizedChipName = chipName.lowercased()
        var limit: Int

        switch memoryGB {
        case 192...:
            limit = 24
        case 96...:
            limit = 16
        case 36...:
            limit = 12
        case 24...:
            limit = 8
        case 16...:
            limit = 6
        default:
            limit = 3
        }

        if processorCount <= 4 || memoryGB <= 8 {
            limit = min(limit, 3)
        }
        if normalizedChipName.contains("ultra"), memoryGB >= 64 {
            limit = max(limit, 16)
        } else if normalizedChipName.contains("max"), memoryGB >= 36 {
            limit = max(limit, 12)
        } else if normalizedChipName.contains("pro"), memoryGB >= 24 {
            limit = max(limit, 8)
        }

        if memoryGB >= 256, processorCount >= 32 {
            let memorySteps = max(0, (memoryGB - 256) / 128)
            let coreSteps = max(0, (processorCount - 32) / 8)
            limit = max(limit, 24 + min(8, (memorySteps + coreSteps) * 2))
        }

        return min(limit, Self.safetyMaximumLiveWindowLimit)
    }

    static var current: PreviewPerformanceProfile {
        PreviewPerformanceProfile(
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            processorCount: ProcessInfo.processInfo.processorCount,
            chipName: currentChipName()
        )
    }

    private var memoryGigabytes: Int {
        let gibibyte = 1_073_741_824.0
        return max(1, Int((Double(physicalMemoryBytes) / gibibyte).rounded()))
    }

    private static func currentChipName() -> String {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else {
            return ""
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 else {
            return ""
        }
        return String(cString: buffer)
    }
}

struct PreviewCapturePolicy: Equatable {
    static let normalVisibleWindowLimit = 24
    let maxVisibleWindows: Int
    let maxStreamCount: Int
    let maxStaticSnapshotCount: Int
    let framesPerSecond: Int
    let maxThumbnailPixelSize: CGSize
    let minimumThumbnailPixelSize: CGSize
    let queueDepth: Int
    let continuesAfterFirstFrame: Bool

    var minimumFrameInterval: CMTime {
        CMTime(value: 1, timescale: CMTimeScale(framesPerSecond))
    }

    static func adaptive(
        livePreviewsEnabled: Bool,
        windowCount: Int,
        powerState: PreviewPowerState,
        requestedLiveStreamCount: Int = 6,
        performanceProfile: PreviewPerformanceProfile = .current
    ) -> PreviewCapturePolicy {
        let reducedLoad = powerState.prefersReducedPreviewLoad
        let visibleWindowCount = min(max(0, windowCount), normalVisibleWindowLimit)
        let livePowerLimit = reducedLoad ? 3 : PreviewPerformanceProfile.safetyMaximumLiveWindowLimit
        let effectiveLiveStreamCount = livePreviewsEnabled
            ? min(
                max(0, requestedLiveStreamCount),
                visibleWindowCount,
                performanceProfile.recommendedLiveWindowLimit,
                livePowerLimit
            )
            : 0
        let staticSnapshotCount = max(0, visibleWindowCount - effectiveLiveStreamCount)

        if !livePreviewsEnabled {
            return PreviewCapturePolicy(
                maxVisibleWindows: normalVisibleWindowLimit,
                maxStreamCount: 0,
                maxStaticSnapshotCount: staticSnapshotCount,
                framesPerSecond: reducedLoad ? 4 : 8,
                maxThumbnailPixelSize: reducedLoad ? CGSize(width: 320, height: 220) : CGSize(width: 440, height: 300),
                minimumThumbnailPixelSize: CGSize(width: 160, height: 100),
                queueDepth: 3,
                continuesAfterFirstFrame: false
            )
        }

        if reducedLoad {
            return PreviewCapturePolicy(
                maxVisibleWindows: normalVisibleWindowLimit,
                maxStreamCount: effectiveLiveStreamCount,
                maxStaticSnapshotCount: staticSnapshotCount,
                framesPerSecond: 4,
                maxThumbnailPixelSize: CGSize(width: 320, height: 220),
                minimumThumbnailPixelSize: CGSize(width: 160, height: 100),
                queueDepth: 3,
                continuesAfterFirstFrame: effectiveLiveStreamCount > 0
            )
        }

        return PreviewCapturePolicy(
            maxVisibleWindows: normalVisibleWindowLimit,
            maxStreamCount: effectiveLiveStreamCount,
            maxStaticSnapshotCount: staticSnapshotCount,
            framesPerSecond: 8,
            maxThumbnailPixelSize: CGSize(width: 440, height: 300),
            minimumThumbnailPixelSize: CGSize(width: 160, height: 100),
            queueDepth: 3,
            continuesAfterFirstFrame: effectiveLiveStreamCount > 0
        )
    }

    static func hiddenSnapshot(powerState: PreviewPowerState) -> PreviewCapturePolicy {
        let reducedLoad = powerState.prefersReducedPreviewLoad
        return PreviewCapturePolicy(
            maxVisibleWindows: normalVisibleWindowLimit,
            maxStreamCount: reducedLoad ? 3 : 6,
            maxStaticSnapshotCount: 0,
            framesPerSecond: 4,
            maxThumbnailPixelSize: reducedLoad ? CGSize(width: 256, height: 180) : CGSize(width: 320, height: 220),
            minimumThumbnailPixelSize: CGSize(width: 140, height: 90),
            queueDepth: 3,
            continuesAfterFirstFrame: false
        )
    }

    func thumbnailPixelSize(for sourceSize: CGSize) -> CGSize {
        guard sourceSize.width > 0, sourceSize.height > 0 else {
            return maxThumbnailPixelSize
        }
        let scale = min(maxThumbnailPixelSize.width / sourceSize.width, maxThumbnailPixelSize.height / sourceSize.height)
        return CGSize(
            width: max(minimumThumbnailPixelSize.width, floor(sourceSize.width * scale)),
            height: max(minimumThumbnailPixelSize.height, floor(sourceSize.height * scale))
        )
    }

    func staticSnapshotPolicy(streamCount: Int) -> PreviewCapturePolicy {
        PreviewCapturePolicy(
            maxVisibleWindows: maxVisibleWindows,
            maxStreamCount: max(0, streamCount),
            maxStaticSnapshotCount: 0,
            framesPerSecond: framesPerSecond,
            maxThumbnailPixelSize: maxThumbnailPixelSize,
            minimumThumbnailPixelSize: minimumThumbnailPixelSize,
            queueDepth: 3,
            continuesAfterFirstFrame: false
        )
    }
}
