import Foundation

public enum PermissionFeature: String, CaseIterable, Hashable {
    case dockClick
    case dockPreview
    // Preserve pending onboarding requests saved by earlier builds.
    case windowCycle = "independentWindowSwitcher"
    case hotkeys
    case finderExtension
    case windowPlacement

    public var requiredPermissions: [PermissionKind] {
        switch self {
        case .dockClick:
            return [.accessibility, .inputMonitoring]
        case .dockPreview:
            return [.accessibility]
        case .windowCycle:
            return [.accessibility, .inputMonitoring]
        case .hotkeys:
            return [.accessibility]
        case .finderExtension:
            return [.finderExtension, .folderAccess]
        case .windowPlacement:
            return [.accessibility, .inputMonitoring]
        }
    }
}

enum PermissionFeatureAvailability: Equatable {
    case disabled
    case unavailable([PermissionKind])
    case metadataOnly
    case available

    var canRun: Bool {
        switch self {
        case .available, .metadataOnly: return true
        case .disabled, .unavailable: return false
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

    static func availability(
        for feature: PermissionFeature,
        settings: SettingsStore,
        snapshot: PermissionSnapshot
    ) -> PermissionFeatureAvailability {
        let isEnabled: Bool
        switch feature {
        case .dockClick: isEnabled = settings.toggleAppVisibilityOnDockClick
        case .dockPreview: isEnabled = settings.showDockPreviews
        case .windowCycle: isEnabled = settings.showDockPreviews && settings.windowCycleEnabled
        case .hotkeys: isEnabled = settings.hotkeysEnabled
        case .finderExtension: isEnabled = settings.finderExtensionEnabled
        case .windowPlacement: isEnabled = settings.windowPlacementEnabled
        }
        guard isEnabled else { return .disabled }
        let missing = missingPermissions(for: feature, in: snapshot)
        guard missing.isEmpty else { return .unavailable(missing) }
        if (feature == .dockPreview || feature == .windowCycle), !snapshot.screenRecording {
            return .metadataOnly
        }
        return .available
    }

    public static func firstMissingPermission(
        for feature: PermissionFeature,
        in snapshot: PermissionSnapshot
    ) -> PermissionKind? {
        missingPermissions(for: feature, in: snapshot).first
    }

    // Older builds switched preferences off and saved their original intent here.
    // Consume that intent once; permission refreshes must never write preferences.
    static func restorePendingPreferences(in settings: SettingsStore) {
        let pending = settings.pendingPermissionFeatures
        guard !pending.isEmpty else { return }
        settings.pendingPermissionFeatures = []
        for feature in PermissionFeature.allCases where pending.contains(feature) {
            switch feature {
            case .dockClick:
                settings.toggleAppVisibilityOnDockClick = true
            case .dockPreview:
                settings.showDockPreviews = true
            case .windowCycle:
                settings.windowCycleEnabled = true
            case .hotkeys:
                settings.hotkeysEnabled = true
            case .finderExtension:
                settings.finderExtensionEnabled = true
            case .windowPlacement:
                settings.windowPlacementEnabled = true
            }
        }

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
