import AppKit
import CoreGraphics
import Foundation

struct DockProxyWindowInfo: Equatable {
    let processIdentifier: pid_t
    let title: String?
    let layer: Int
    let isOnScreen: Bool
    let frame: CGRect
}

struct DockProxyApplicationInfo: Equatable {
    let processIdentifier: pid_t
    let bundleIdentifier: String?
    let localizedName: String?
}

struct DockProxyTargetResolution: Equatable {
    let target: DockAppTarget
    let proxyOwnerProcessIdentifier: pid_t?
}

final class DockProxyOwnerStore {
    private let lock = NSLock()
    private var ownerProcessIdentifiers: [String: pid_t] = [:]

    func resolve(
        for target: DockAppTarget,
        using resolver: (pid_t?) -> DockProxyTargetResolution
    ) -> DockProxyTargetResolution {
        lock.lock()
        defer { lock.unlock() }

        let resolution = resolver(ownerProcessIdentifiers[target.dockTileIdentifier])
        ownerProcessIdentifiers[target.dockTileIdentifier] = resolution.proxyOwnerProcessIdentifier
        return resolution
    }

    func rememberedOwnerProcessIdentifier(for target: DockAppTarget) -> pid_t? {
        lock.lock()
        defer { lock.unlock() }
        return ownerProcessIdentifiers[target.dockTileIdentifier]
    }

    func removeOwner(for target: DockAppTarget) {
        lock.lock()
        ownerProcessIdentifiers[target.dockTileIdentifier] = nil
        lock.unlock()
    }

    func removeAll() {
        lock.lock()
        ownerProcessIdentifiers.removeAll()
        lock.unlock()
    }
}

enum DockProxyTargetResolver {
    static func resolvedTarget(
        for target: DockAppTarget,
        rememberedOwnerProcessIdentifier: pid_t? = nil
    ) -> DockProxyTargetResolution {
        resolvedTarget(
            for: target,
            rememberedOwnerProcessIdentifier: rememberedOwnerProcessIdentifier,
            windows: currentWindowInfos(),
            runningApplication: currentRunningApplication
        )
    }

    static func resolvedTarget(
        for target: DockAppTarget,
        rememberedOwnerProcessIdentifier: pid_t? = nil,
        windows: [DockProxyWindowInfo],
        runningApplication: (pid_t) -> DockProxyApplicationInfo?
    ) -> DockProxyTargetResolution {
        let dockTitle = DockTitleMatcher.normalized(target.dockElementTitle)
        guard !dockTitle.isEmpty else {
            return failOpen(target)
        }

        let validWindows = windows.filter(isValidOrdinaryWindow)
        if ownsValidWindow(target.processIdentifier, in: validWindows) {
            return failOpen(target)
        }

        let matchingOwnerIdentifiers = ownerIdentifiersMatching(
            dockTitle: dockTitle,
            excluding: target.processIdentifier,
            in: validWindows
        )
        let ownerProcessIdentifier: pid_t
        switch matchingOwnerIdentifiers.count {
        case 1:
            guard let matchingOwnerProcessIdentifier = matchingOwnerIdentifiers.first else {
                return failOpen(target)
            }
            if let rememberedOwnerProcessIdentifier,
               rememberedOwnerProcessIdentifier != matchingOwnerProcessIdentifier {
                return failOpen(target)
            }
            ownerProcessIdentifier = matchingOwnerProcessIdentifier
        case 0:
            guard let rememberedOwnerProcessIdentifier,
                  rememberedOwnerProcessIdentifier != target.processIdentifier
            else {
                return failOpen(target)
            }
            ownerProcessIdentifier = rememberedOwnerProcessIdentifier
        default:
            return failOpen(target)
        }

        guard let ownerApplication = runningApplication(ownerProcessIdentifier) else {
            return failOpen(target)
        }
        return DockProxyTargetResolution(
            target: target.proxying(
                to: ownerApplication.processIdentifier,
                bundleIdentifier: ownerApplication.bundleIdentifier,
                localizedName: ownerApplication.localizedName
            ),
            proxyOwnerProcessIdentifier: ownerApplication.processIdentifier
        )
    }

    private static func ownsValidWindow(_ processIdentifier: pid_t, in windows: [DockProxyWindowInfo]) -> Bool {
        windows.contains { $0.processIdentifier == processIdentifier }
    }

    private static func ownerIdentifiersMatching(
        dockTitle: String,
        excluding processIdentifier: pid_t,
        in windows: [DockProxyWindowInfo]
    ) -> Set<pid_t> {
        Set(windows.compactMap { window -> pid_t? in
            guard window.processIdentifier != processIdentifier,
                  DockTitleMatcher.normalized(window.title) == dockTitle
            else {
                return nil
            }
            return window.processIdentifier
        })
    }

    static func currentWindowInfos() -> [DockProxyWindowInfo] {
        guard let rawWindows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID),
              let windows = rawWindows as? [[String: Any]]
        else {
            return []
        }

        return windows.compactMap { window in
            guard let processIdentifier = CGWindowDictionary.intValue(kCGWindowOwnerPID, from: window).map(pid_t.init) else {
                return nil
            }
            return DockProxyWindowInfo(
                processIdentifier: processIdentifier,
                title: CGWindowDictionary.stringValue(kCGWindowName, from: window),
                layer: CGWindowDictionary.intValue(kCGWindowLayer, from: window) ?? -1,
                isOnScreen: CGWindowDictionary.boolValue(kCGWindowIsOnscreen, from: window) ?? true,
                frame: CGWindowDictionary.frame(from: window)
            )
        }
    }

    static func currentRunningApplication(_ processIdentifier: pid_t) -> DockProxyApplicationInfo? {
        guard let application = NSRunningApplication(processIdentifier: processIdentifier) else {
            return nil
        }
        return DockProxyApplicationInfo(
            processIdentifier: application.processIdentifier,
            bundleIdentifier: application.bundleIdentifier,
            localizedName: application.localizedName
        )
    }

    private static func failOpen(_ target: DockAppTarget) -> DockProxyTargetResolution {
        DockProxyTargetResolution(target: target, proxyOwnerProcessIdentifier: nil)
    }

    private static func isValidOrdinaryWindow(_ window: DockProxyWindowInfo) -> Bool {
        WindowFiltering.shouldIncludeShareableWindow(
            layer: window.layer,
            isOnScreen: window.isOnScreen,
            frame: window.frame
        )
    }
}

struct DockProxyTargetRouter {
    private let ownerStore: DockProxyOwnerStore

    init(ownerStore: DockProxyOwnerStore = DockProxyOwnerStore()) {
        self.ownerStore = ownerStore
    }

    func resolvedTarget(
        for target: DockAppTarget,
        originalNormalWindowCount: Int
    ) -> DockAppTarget {
        let windows = DockProxyTargetResolver.currentWindowInfos()
        return resolution(
            for: target,
            originalNormalWindowCount: originalNormalWindowCount,
            windows: windows,
            runningApplication: DockProxyTargetResolver.currentRunningApplication
        ).target
    }

    func resolvedTarget(for target: DockAppTarget) -> DockAppTarget {
        let windows = DockProxyTargetResolver.currentWindowInfos()
        return resolution(
            for: target,
            windows: windows,
            runningApplication: DockProxyTargetResolver.currentRunningApplication
        ).target
    }

    func resolvedTarget(
        for target: DockAppTarget,
        originalNormalWindowCount: Int = 0,
        windows: [DockProxyWindowInfo],
        runningApplication: (pid_t) -> DockProxyApplicationInfo?
    ) -> DockAppTarget {
        resolution(
            for: target,
            originalNormalWindowCount: originalNormalWindowCount,
            windows: windows,
            runningApplication: runningApplication
        ).target
    }

    func resolution(
        for target: DockAppTarget,
        originalNormalWindowCount: Int = 0,
        windows: [DockProxyWindowInfo],
        runningApplication: (pid_t) -> DockProxyApplicationInfo?
    ) -> DockProxyTargetResolution {
        ownerStore.resolve(for: target) { rememberedOwnerProcessIdentifier in
            guard originalNormalWindowCount <= 0 else {
                return DockProxyTargetResolution(
                    target: target,
                    proxyOwnerProcessIdentifier: nil
                )
            }
            return DockProxyTargetResolver.resolvedTarget(
                for: target,
                rememberedOwnerProcessIdentifier: rememberedOwnerProcessIdentifier,
                windows: windows,
                runningApplication: runningApplication
            )
        }
    }

    func rememberedOwnerProcessIdentifier(for target: DockAppTarget) -> pid_t? {
        ownerStore.rememberedOwnerProcessIdentifier(for: target)
    }

    func removeRememberedOwner(for target: DockAppTarget) {
        ownerStore.removeOwner(for: target)
    }

    func removeAll() {
        ownerStore.removeAll()
    }
}
