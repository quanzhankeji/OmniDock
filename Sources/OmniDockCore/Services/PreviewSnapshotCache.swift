import AppKit
import CoreGraphics
import Foundation

struct PreviewSnapshotCacheLimits: Equatable {
    let timeToLive: TimeInterval
    let maxWindowsPerApplication: Int
    let maxTotalWindows: Int
    let maxTotalBytes: Int

    init(
        timeToLive: TimeInterval,
        maxWindowsPerApplication: Int,
        maxTotalWindows: Int,
        maxTotalBytes: Int = 20 * 1_024 * 1_024
    ) {
        self.timeToLive = timeToLive
        self.maxWindowsPerApplication = maxWindowsPerApplication
        self.maxTotalWindows = maxTotalWindows
        self.maxTotalBytes = maxTotalBytes
    }

    static let balanced = PreviewSnapshotCacheLimits(
        timeToLive: 45,
        maxWindowsPerApplication: PreviewCapturePolicy.normalVisibleWindowLimit,
        maxTotalWindows: 24,
        maxTotalBytes: 20 * 1_024 * 1_024
    )
}

final class PreviewSnapshotCache {
    private struct CachedApplication {
        let capturedAt: Date
        let windows: [PreviewWindowInfo]
    }

    private let limits: PreviewSnapshotCacheLimits
    private var applications: [pid_t: CachedApplication] = [:]

    init(limits: PreviewSnapshotCacheLimits = .balanced) {
        self.limits = limits
    }

    func store(processIdentifier: pid_t, windows: [PreviewWindowInfo], capturedAt: Date = Date()) {
        let cacheableWindows = windows.prefix(limits.maxWindowsPerApplication)

        guard cacheableWindows.contains(where: { $0.staticPreviewImage != nil }) else {
            return
        }

        applications[processIdentifier] = CachedApplication(
            capturedAt: capturedAt,
            windows: Array(cacheableWindows)
        )
        trim(now: capturedAt)
    }

    func windows(for processIdentifier: pid_t, now: Date = Date()) -> [PreviewWindowInfo] {
        trim(now: now)
        return applications[processIdentifier]?.windows ?? []
    }

    func clear(processIdentifier: pid_t) {
        applications[processIdentifier] = nil
    }

    func removeWindow(processIdentifier: pid_t, matching window: PreviewWindowInfo) {
        guard let cached = applications[processIdentifier] else {
            return
        }

        let remainingWindows = cached.windows.filter { candidate in
            if candidate.id == window.id {
                return false
            }
            if let windowID = window.windowID, candidate.windowID == windowID {
                return false
            }
            return true
        }
        guard remainingWindows.count != cached.windows.count else {
            return
        }
        guard remainingWindows.contains(where: { $0.staticPreviewImage != nil }) else {
            applications[processIdentifier] = nil
            return
        }

        applications[processIdentifier] = CachedApplication(
            capturedAt: cached.capturedAt,
            windows: remainingWindows
        )
    }

    func clearAll() {
        applications.removeAll()
    }

    func removeExpired(now: Date = Date()) {
        trim(now: now)
    }

    func nextCleanupDelay(now: Date = Date()) -> TimeInterval? {
        trim(now: now)
        guard let oldestCaptureDate = applications.values.map(\.capturedAt).min() else {
            return nil
        }
        let age = now.timeIntervalSince(oldestCaptureDate)
        return max(0, limits.timeToLive - age)
    }

    private func trim(now: Date) {
        applications = applications.filter { _, cached in
            let age = now.timeIntervalSince(cached.capturedAt)
            return age >= 0 && age <= limits.timeToLive
        }

        var totalWindows = applications.values.reduce(0) { $0 + $1.windows.count }
        var totalBytes = applications.values.reduce(0) {
            $0 + estimatedByteCount(for: $1.windows)
        }
        guard totalWindows > limits.maxTotalWindows
                || totalBytes > limits.maxTotalBytes else {
            return
        }

        let oldestProcessIdentifiers = applications
            .sorted { $0.value.capturedAt < $1.value.capturedAt }
            .map(\.key)

        for processIdentifier in oldestProcessIdentifiers {
            guard totalWindows > limits.maxTotalWindows
                    || totalBytes > limits.maxTotalBytes,
                  let cached = applications.removeValue(forKey: processIdentifier)
            else {
                break
            }
            totalWindows -= cached.windows.count
            totalBytes -= estimatedByteCount(for: cached.windows)
        }
    }

    private func estimatedByteCount(for windows: [PreviewWindowInfo]) -> Int {
        windows.reduce(0) { total, window in
            guard let image = window.staticPreviewImage else {
                return total
            }
            let representationBytes = image.representations.reduce(0) { subtotal, representation in
                let width = max(representation.pixelsWide, Int(image.size.width))
                let height = max(representation.pixelsHigh, Int(image.size.height))
                return subtotal + max(0, width * height * 4)
            }
            let fallbackBytes = max(0, Int(image.size.width * image.size.height * 4))
            return total + max(representationBytes, fallbackBytes)
        }
    }
}
