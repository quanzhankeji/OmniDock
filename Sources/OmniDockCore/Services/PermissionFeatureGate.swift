import Foundation

public enum PermissionFeature: String, CaseIterable, Hashable {
    case dockClick
    case dockPreview
    // Preserve pending onboarding requests saved by earlier builds.
    case windowCycle = "independentWindowSwitcher"
    case hotkeys
    case finderExtension

    public var requiredPermissions: [PermissionKind] {
        switch self {
        case .dockClick:
            return [.accessibility, .inputMonitoring]
        case .dockPreview:
            return [.accessibility, .screenRecording]
        case .windowCycle:
            return [.accessibility, .screenRecording, .inputMonitoring]
        case .hotkeys:
            return [.accessibility]
        case .finderExtension:
            return [.finderExtension, .folderAccess]
        }
    }
}

public enum PermissionFeatureGate {
    public static let onboardingPermissions: [PermissionKind] = [
        .accessibility,
        .inputMonitoring,
        .screenRecording,
        .finderExtension,
        .folderAccess
    ]

    public static func missingPermissions(
        for feature: PermissionFeature,
        in snapshot: PermissionSnapshot
    ) -> [PermissionKind] {
        feature.requiredPermissions.filter { !isGranted($0, in: snapshot) }
    }

    public static func isSatisfied(
        for feature: PermissionFeature,
        in snapshot: PermissionSnapshot
    ) -> Bool {
        missingPermissions(for: feature, in: snapshot).isEmpty
    }

    public static func allOnboardingPermissionsGranted(in snapshot: PermissionSnapshot) -> Bool {
        onboardingPermissions.allSatisfy { isGranted($0, in: snapshot) }
    }

    @discardableResult
    public static func disableUnavailableFeatures(
        in settings: SettingsStore,
        snapshot: PermissionSnapshot
    ) -> [PermissionFeature] {
        var disabled: [PermissionFeature] = []

        if settings.toggleAppVisibilityOnDockClick,
           !isSatisfied(for: .dockClick, in: snapshot) {
            settings.toggleAppVisibilityOnDockClick = false
            disabled.append(.dockClick)
        }

        if settings.showDockPreviews,
           !isSatisfied(for: .dockPreview, in: snapshot) {
            settings.showDockPreviews = false
            settings.liveDockPreviewsEnabled = false
            settings.windowCycleEnabled = false
            disabled.append(.dockPreview)
        } else if settings.liveDockPreviewsEnabled,
                  !isSatisfied(for: .dockPreview, in: snapshot) {
            settings.liveDockPreviewsEnabled = false
            disabled.append(.dockPreview)
        }

        if settings.hotkeysEnabled,
           !isSatisfied(for: .hotkeys, in: snapshot) {
            settings.hotkeysEnabled = false
            disabled.append(.hotkeys)
        }

        if settings.windowCycleEnabled,
           !isSatisfied(for: .windowCycle, in: snapshot) {
            settings.windowCycleEnabled = false
            disabled.append(.windowCycle)
        }

        if settings.finderExtensionEnabled,
           !isSatisfied(for: .finderExtension, in: snapshot) {
            settings.finderExtensionEnabled = false
            disabled.append(.finderExtension)
        }

        return disabled
    }

    public static func firstMissingPermission(
        for feature: PermissionFeature,
        in snapshot: PermissionSnapshot
    ) -> PermissionKind? {
        missingPermissions(for: feature, in: snapshot).first
    }

    static func enableSatisfiedFeatures(
        _ features: Set<PermissionFeature>,
        in settings: SettingsStore,
        snapshot: PermissionSnapshot
    ) -> Set<PermissionFeature> {
        let satisfied = Set(features.filter { isSatisfied(for: $0, in: snapshot) })

        for feature in PermissionFeature.allCases where satisfied.contains(feature) {
            switch feature {
            case .dockClick:
                settings.toggleAppVisibilityOnDockClick = true
            case .dockPreview:
                settings.showDockPreviews = true
                settings.liveDockPreviewsEnabled = true
            case .windowCycle:
                settings.showDockPreviews = true
                settings.windowCycleEnabled = true
            case .hotkeys:
                settings.hotkeysEnabled = true
            case .finderExtension:
                settings.finderExtensionEnabled = true
            }
        }

        return satisfied
    }

    private static func isGranted(_ kind: PermissionKind, in snapshot: PermissionSnapshot) -> Bool {
        switch kind {
        case .accessibility:
            return snapshot.accessibility
        case .screenRecording:
            return snapshot.screenRecording
        case .inputMonitoring:
            return snapshot.inputMonitoring
        case .finderExtension:
            return snapshot.finderExtension
        case .folderAccess:
            return snapshot.folderAccess
        }
    }
}

enum PermissionMonitorRecoveryPolicy {
    static let relaunchCooldown: TimeInterval = 3600

    static func shouldRelaunch(
        isDockClickEnabled: Bool,
        snapshot: PermissionSnapshot,
        isMonitoringActive: Bool,
        lastRelaunchAttemptAt: Date?,
        now: Date
    ) -> Bool {
        guard isDockClickEnabled,
              PermissionFeatureGate.isSatisfied(for: .dockClick, in: snapshot),
              !isMonitoringActive
        else {
            return false
        }

        guard let lastRelaunchAttemptAt else {
            return true
        }
        return now.timeIntervalSince(lastRelaunchAttemptAt) >= relaunchCooldown
    }
}

struct PermissionFeatureActivationQueue {
    private(set) var pendingFeatures: Set<PermissionFeature> = []

    init(pendingFeatures: Set<PermissionFeature> = []) {
        self.pendingFeatures = pendingFeatures
    }

    mutating func request(_ feature: PermissionFeature) {
        pendingFeatures.insert(feature)
    }

    mutating func preserveIntent(for features: some Sequence<PermissionFeature>) {
        pendingFeatures.formUnion(features)
    }

    @discardableResult
    mutating func resolve(
        in settings: SettingsStore,
        snapshot: PermissionSnapshot
    ) -> Set<PermissionFeature> {
        let enabled = PermissionFeatureGate.enableSatisfiedFeatures(
            pendingFeatures,
            in: settings,
            snapshot: snapshot
        )
        pendingFeatures.subtract(enabled)
        return enabled
    }
}
