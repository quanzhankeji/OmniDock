import Foundation

public final class SettingsStore {
    public static let changedNotification = Notification.Name("OmniDockSettingsChanged")

    private enum Key: String {
        case showDockPreviews = "showDockPreviews"
        case showCommandTabPreviews = "showCommandTabPreviews"
        case liveDockPreviewsEnabled = "liveDockPreviewsEnabled"
        case livePreviewWindowLimit = "livePreviewWindowLimit"
        case toggleAppVisibilityOnDockClick = "toggleAppVisibilityOnDockClick"
        case minimizeWindowsOnDockClickInsteadOfHide = "minimizeWindowsOnDockClickInsteadOfHide"
        case hotkeysEnabled = "hotkeysEnabled"
        case hotkeyAssignments = "hotkeyAssignments"
        case minimizeOnRepeatedDockClick = "minimizeOnRepeatedDockClick"
        case appLanguage = "appLanguage"
        case permissionOnboardingCompleted = "permissionOnboardingCompleted"
        case permissionOnboardingSkipped = "permissionOnboardingSkipped"
        case pendingPermissionFeatures = "pendingPermissionFeatures"
        case lastPermissionRefreshRelaunchAttemptAt = "lastPermissionRefreshRelaunchAttemptAt"
    }

    private let defaults: UserDefaults
    private let livePreviewLimitProvider: () -> Int

    public convenience init(defaults: UserDefaults = .standard) {
        self.init(
            defaults: defaults,
            livePreviewLimitProvider: { PreviewPerformanceProfile.current.recommendedLiveWindowLimit }
        )
    }

    init(defaults: UserDefaults, livePreviewLimitProvider: @escaping () -> Int) {
        self.defaults = defaults
        self.livePreviewLimitProvider = livePreviewLimitProvider
        migrateLegacyMinimizePreferenceIfNeeded()
        defaults.register(defaults: [
            Key.showDockPreviews.rawValue: true,
            Key.showCommandTabPreviews.rawValue: true,
            Key.liveDockPreviewsEnabled.rawValue: true,
            Key.livePreviewWindowLimit.rawValue: min(6, max(0, livePreviewLimitProvider())),
            Key.hotkeysEnabled.rawValue: true,
            Key.appLanguage.rawValue: AppLanguage.system.rawValue,
            Key.permissionOnboardingCompleted.rawValue: false,
            Key.permissionOnboardingSkipped.rawValue: false
        ])
        AppLocalization.configure(language: appLanguage)
    }

    public var showDockPreviews: Bool {
        get { defaults.bool(forKey: Key.showDockPreviews.rawValue) }
        set { set(newValue, for: .showDockPreviews) }
    }

    public var showCommandTabPreviews: Bool {
        get {
            guard let value = defaults.object(forKey: Key.showCommandTabPreviews.rawValue) as? Bool else {
                return true
            }
            return value
        }
        set { set(newValue, for: .showCommandTabPreviews) }
    }

    public var liveDockPreviewsEnabled: Bool {
        get {
            guard let value = defaults.object(forKey: Key.liveDockPreviewsEnabled.rawValue) as? Bool else {
                return true
            }
            return value
        }
        set { set(newValue, for: .liveDockPreviewsEnabled) }
    }

    public var livePreviewWindowLimitMaximum: Int {
        max(0, livePreviewLimitProvider())
    }

    public var livePreviewWindowLimit: Int {
        get {
            clampLivePreviewWindowLimit(defaults.integer(forKey: Key.livePreviewWindowLimit.rawValue))
        }
        set {
            set(clampLivePreviewWindowLimit(newValue), for: .livePreviewWindowLimit)
        }
    }

    public var toggleAppVisibilityOnDockClick: Bool {
        get {
            guard let value = defaults.object(forKey: Key.toggleAppVisibilityOnDockClick.rawValue) as? Bool else {
                return true
            }
            return value
        }
        set { set(newValue, for: .toggleAppVisibilityOnDockClick) }
    }

    public var minimizeWindowsOnDockClickInsteadOfHide: Bool {
        get {
            guard let value = defaults.object(forKey: Key.minimizeWindowsOnDockClickInsteadOfHide.rawValue) as? Bool else {
                return false
            }
            return value
        }
        set { set(newValue, for: .minimizeWindowsOnDockClickInsteadOfHide) }
    }

    public var hotkeysEnabled: Bool {
        get {
            guard let value = defaults.object(forKey: Key.hotkeysEnabled.rawValue) as? Bool else {
                return true
            }
            return value
        }
        set { set(newValue, for: .hotkeysEnabled) }
    }

    public var appLanguage: AppLanguage {
        get {
            guard let value = defaults.string(forKey: Key.appLanguage.rawValue),
                  let language = AppLanguage(rawValue: value)
            else {
                return .system
            }
            return language
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.appLanguage.rawValue)
            AppLocalization.configure(language: newValue)
            NotificationCenter.default.post(name: Self.changedNotification, object: self)
        }
    }

    public var appHotkeyBindings: [AppHotkeyBinding] {
        get {
            guard let data = defaults.data(forKey: Key.hotkeyAssignments.rawValue),
                  let bindings = try? JSONDecoder().decode([AppHotkeyBinding].self, from: data)
            else {
                return []
            }
            return bindings
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Key.hotkeyAssignments.rawValue)
            } else {
                defaults.removeObject(forKey: Key.hotkeyAssignments.rawValue)
            }
            NotificationCenter.default.post(name: Self.changedNotification, object: self)
        }
    }

    public var permissionOnboardingCompleted: Bool {
        get { defaults.bool(forKey: Key.permissionOnboardingCompleted.rawValue) }
        set { set(newValue, for: .permissionOnboardingCompleted) }
    }

    public var permissionOnboardingSkipped: Bool {
        get { defaults.bool(forKey: Key.permissionOnboardingSkipped.rawValue) }
        set { set(newValue, for: .permissionOnboardingSkipped) }
    }

    var pendingPermissionFeatures: Set<PermissionFeature> {
        get {
            let identifiers = defaults.stringArray(forKey: Key.pendingPermissionFeatures.rawValue) ?? []
            return Set(identifiers.compactMap(PermissionFeature.init(rawValue:)))
        }
        set {
            defaults.set(
                newValue.map(\.rawValue).sorted(),
                forKey: Key.pendingPermissionFeatures.rawValue
            )
        }
    }

    public var lastPermissionRefreshRelaunchAttemptAt: Date? {
        get {
            guard let value = defaults.object(forKey: Key.lastPermissionRefreshRelaunchAttemptAt.rawValue) as? TimeInterval else {
                return nil
            }
            return Date(timeIntervalSince1970: value)
        }
        set {
            if let newValue {
                defaults.set(newValue.timeIntervalSince1970, forKey: Key.lastPermissionRefreshRelaunchAttemptAt.rawValue)
            } else {
                defaults.removeObject(forKey: Key.lastPermissionRefreshRelaunchAttemptAt.rawValue)
            }
            NotificationCenter.default.post(name: Self.changedNotification, object: self)
        }
    }

    public func upsertAppHotkeyBinding(_ binding: AppHotkeyBinding) {
        var bindings = appHotkeyBindings
        if let index = bindings.firstIndex(where: { $0.id == binding.id }) {
            bindings[index] = binding
        } else {
            bindings.append(binding)
        }
        appHotkeyBindings = bindings
    }

    public func deleteAppHotkeyBinding(id: UUID) {
        appHotkeyBindings = appHotkeyBindings.filter { $0.id != id }
    }

    public func enablePermissionBackedDefaultsAfterOnboarding() {
        defaults.set(true, forKey: Key.showDockPreviews.rawValue)
        defaults.set(true, forKey: Key.showCommandTabPreviews.rawValue)
        defaults.set(true, forKey: Key.liveDockPreviewsEnabled.rawValue)
        defaults.set(true, forKey: Key.toggleAppVisibilityOnDockClick.rawValue)
        defaults.set(true, forKey: Key.hotkeysEnabled.rawValue)
        defaults.set(true, forKey: Key.permissionOnboardingCompleted.rawValue)
        defaults.set(false, forKey: Key.permissionOnboardingSkipped.rawValue)
        NotificationCenter.default.post(name: Self.changedNotification, object: self)
    }

    private func set(_ value: Bool, for key: Key) {
        defaults.set(value, forKey: key.rawValue)
        NotificationCenter.default.post(name: Self.changedNotification, object: self)
    }

    private func set(_ value: Int, for key: Key) {
        defaults.set(value, forKey: key.rawValue)
        NotificationCenter.default.post(name: Self.changedNotification, object: self)
    }

    private func clampLivePreviewWindowLimit(_ value: Int) -> Int {
        min(max(value, 0), livePreviewWindowLimitMaximum)
    }

    private func migrateLegacyMinimizePreferenceIfNeeded() {
        guard defaults.object(forKey: Key.toggleAppVisibilityOnDockClick.rawValue) == nil,
              let legacyValue = defaults.object(forKey: Key.minimizeOnRepeatedDockClick.rawValue) as? Bool
        else {
            return
        }
        defaults.set(legacyValue, forKey: Key.toggleAppVisibilityOnDockClick.rawValue)
    }
}
