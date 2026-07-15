import XCTest
@testable import OmniDockCore

final class PreviewCapturePolicyTests: XCTestCase {
    func testNormalLivePolicyUsesBalancedDefaults() {
        let policy = PreviewCapturePolicy.adaptive(
            livePreviewsEnabled: true,
            windowCount: 3,
            powerState: PreviewPowerState(isLowPowerModeEnabled: false, isOnBatteryPower: false),
            requestedLiveStreamCount: 6,
            performanceProfile: profile(memoryGB: 16, processorCount: 10)
        )

        XCTAssertEqual(policy.maxVisibleWindows, 24)
        XCTAssertEqual(policy.maxStreamCount, 3)
        XCTAssertEqual(policy.maxStaticSnapshotCount, 0)
        XCTAssertEqual(policy.framesPerSecond, 8)
        XCTAssertEqual(policy.maxThumbnailPixelSize, CGSize(width: 440, height: 300))
        XCTAssertEqual(policy.queueDepth, 3)
        XCTAssertTrue(policy.continuesAfterFirstFrame)
    }

    func testReducedPowerPolicyUsesLowerLoadSettings() {
        let policy = PreviewCapturePolicy.adaptive(
            livePreviewsEnabled: true,
            windowCount: 3,
            powerState: PreviewPowerState(isLowPowerModeEnabled: true, isOnBatteryPower: false),
            requestedLiveStreamCount: 6,
            performanceProfile: profile(memoryGB: 16, processorCount: 10)
        )

        XCTAssertEqual(policy.maxVisibleWindows, 24)
        XCTAssertEqual(policy.maxStreamCount, 3)
        XCTAssertEqual(policy.maxStaticSnapshotCount, 0)
        XCTAssertEqual(policy.framesPerSecond, 4)
        XCTAssertEqual(policy.maxThumbnailPixelSize, CGSize(width: 320, height: 220))
        XCTAssertEqual(policy.queueDepth, 3)
        XCTAssertTrue(policy.continuesAfterFirstFrame)
    }

    func testBatteryPolicyUsesLowerLoadSettings() {
        let policy = PreviewCapturePolicy.adaptive(
            livePreviewsEnabled: true,
            windowCount: 8,
            powerState: PreviewPowerState(isLowPowerModeEnabled: false, isOnBatteryPower: true),
            requestedLiveStreamCount: 6,
            performanceProfile: profile(memoryGB: 16, processorCount: 10)
        )

        XCTAssertEqual(policy.maxStreamCount, 3)
        XCTAssertEqual(policy.maxStaticSnapshotCount, 5)
        XCTAssertEqual(policy.framesPerSecond, 4)
        XCTAssertEqual(policy.queueDepth, 3)
    }

    func testStaticPreviewPolicyStopsAfterFirstFrame() {
        let policy = PreviewCapturePolicy.adaptive(
            livePreviewsEnabled: false,
            windowCount: 3,
            powerState: PreviewPowerState(isLowPowerModeEnabled: false, isOnBatteryPower: false),
            requestedLiveStreamCount: 6,
            performanceProfile: profile(memoryGB: 16, processorCount: 10)
        )

        XCTAssertEqual(policy.maxVisibleWindows, 24)
        XCTAssertEqual(policy.maxStreamCount, 0)
        XCTAssertEqual(policy.maxStaticSnapshotCount, 3)
        XCTAssertEqual(policy.queueDepth, 3)
        XCTAssertFalse(policy.continuesAfterFirstFrame)
    }

    func testHiddenSnapshotPolicyCapturesVisiblePreviewCountOnce() {
        let policy = PreviewCapturePolicy.hiddenSnapshot(
            powerState: PreviewPowerState(isLowPowerModeEnabled: false, isOnBatteryPower: false)
        )

        XCTAssertEqual(policy.maxVisibleWindows, 24)
        XCTAssertEqual(policy.maxStreamCount, 6)
        XCTAssertEqual(policy.maxStaticSnapshotCount, 0)
        XCTAssertEqual(policy.framesPerSecond, 4)
        XCTAssertEqual(policy.maxThumbnailPixelSize, CGSize(width: 320, height: 220))
        XCTAssertEqual(policy.queueDepth, 3)
        XCTAssertFalse(policy.continuesAfterFirstFrame)
    }

    func testReducedPowerHiddenSnapshotPolicyKeepsWindowCountButLimitsCapturedFrames() {
        let policy = PreviewCapturePolicy.hiddenSnapshot(
            powerState: PreviewPowerState(isLowPowerModeEnabled: true, isOnBatteryPower: false)
        )

        XCTAssertEqual(policy.maxVisibleWindows, 24)
        XCTAssertEqual(policy.maxStreamCount, 3)
        XCTAssertEqual(policy.maxStaticSnapshotCount, 0)
        XCTAssertEqual(policy.maxThumbnailPixelSize, CGSize(width: 256, height: 180))
        XCTAssertFalse(policy.continuesAfterFirstFrame)
    }

    func testManyWindowsLimitsLiveStreams() {
        let policy = PreviewCapturePolicy.adaptive(
            livePreviewsEnabled: true,
            windowCount: 9,
            powerState: PreviewPowerState(isLowPowerModeEnabled: false, isOnBatteryPower: false),
            requestedLiveStreamCount: 6,
            performanceProfile: profile(memoryGB: 16, processorCount: 10)
        )

        XCTAssertEqual(policy.maxVisibleWindows, 24)
        XCTAssertEqual(policy.maxStreamCount, 6)
        XCTAssertEqual(policy.maxStaticSnapshotCount, 3)
        XCTAssertTrue(policy.continuesAfterFirstFrame)
    }

    func testZeroRequestedLiveStreamsKeepsStaticSnapshots() {
        let policy = PreviewCapturePolicy.adaptive(
            livePreviewsEnabled: true,
            windowCount: 9,
            powerState: PreviewPowerState(isLowPowerModeEnabled: false, isOnBatteryPower: false),
            requestedLiveStreamCount: 0,
            performanceProfile: profile(memoryGB: 16, processorCount: 10)
        )

        XCTAssertEqual(policy.maxStreamCount, 0)
        XCTAssertEqual(policy.maxStaticSnapshotCount, 9)
        XCTAssertFalse(policy.continuesAfterFirstFrame)
    }

    func testDeviceMaximumCapsRequestedLiveStreams() {
        let policy = PreviewCapturePolicy.adaptive(
            livePreviewsEnabled: true,
            windowCount: 12,
            powerState: PreviewPowerState(isLowPowerModeEnabled: false, isOnBatteryPower: false),
            requestedLiveStreamCount: 20,
            performanceProfile: profile(memoryGB: 24, processorCount: 12, chipName: "Apple M4 Pro")
        )

        XCTAssertEqual(policy.maxStreamCount, 8)
        XCTAssertEqual(policy.maxStaticSnapshotCount, 4)
    }

    func testPerformanceProfileUsesSimpleHardwareTiers() {
        XCTAssertEqual(profile(memoryGB: 8, processorCount: 8).recommendedLiveWindowLimit, 3)
        XCTAssertEqual(profile(memoryGB: 16, processorCount: 10).recommendedLiveWindowLimit, 6)
        XCTAssertEqual(profile(memoryGB: 24, processorCount: 12, chipName: "Apple M4 Pro").recommendedLiveWindowLimit, 8)
        XCTAssertEqual(profile(memoryGB: 64, processorCount: 16, chipName: "Apple M4 Max").recommendedLiveWindowLimit, 12)
        XCTAssertEqual(profile(memoryGB: 128, processorCount: 20, chipName: "Apple M3 Ultra").recommendedLiveWindowLimit, 16)
        XCTAssertEqual(profile(memoryGB: 256, processorCount: 32, chipName: "Apple M5 Ultra").recommendedLiveWindowLimit, 24)
    }

    func testFutureHardwareProfileKeepsSafetyMaximum() {
        let profile = profile(memoryGB: 1024, processorCount: 96, chipName: "Apple Future Ultra")

        XCTAssertLessThanOrEqual(profile.recommendedLiveWindowLimit, PreviewPerformanceProfile.safetyMaximumLiveWindowLimit)
        XCTAssertEqual(profile.recommendedLiveWindowLimit, 32)
    }

    func testThumbnailSizeUsesPolicyMaximums() {
        let policy = PreviewCapturePolicy.adaptive(
            livePreviewsEnabled: true,
            windowCount: 1,
            powerState: PreviewPowerState(isLowPowerModeEnabled: true, isOnBatteryPower: false),
            requestedLiveStreamCount: 6,
            performanceProfile: profile(memoryGB: 16, processorCount: 10)
        )

        let size = policy.thumbnailPixelSize(for: CGSize(width: 1600, height: 900))

        XCTAssertLessThanOrEqual(size.width, 320)
        XCTAssertLessThanOrEqual(size.height, 220)
        XCTAssertGreaterThanOrEqual(size.width, 160)
        XCTAssertGreaterThanOrEqual(size.height, 100)
    }

    func testCaptureQueueDepthIsClampedToScreenCaptureKitRange() {
        XCTAssertEqual(PreviewCaptureConfiguration.clampedQueueDepth(0), 3)
        XCTAssertEqual(PreviewCaptureConfiguration.clampedQueueDepth(3), 3)
        XCTAssertEqual(PreviewCaptureConfiguration.clampedQueueDepth(6), 6)
        XCTAssertEqual(PreviewCaptureConfiguration.clampedQueueDepth(20), 8)
    }

    private func profile(
        memoryGB: Int,
        processorCount: Int,
        chipName: String = "Apple M4"
    ) -> PreviewPerformanceProfile {
        PreviewPerformanceProfile(
            physicalMemoryBytes: UInt64(memoryGB) * 1_073_741_824,
            processorCount: processorCount,
            chipName: chipName
        )
    }
}
