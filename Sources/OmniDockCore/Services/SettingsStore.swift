import Foundation

public enum SettingsChange: String, Equatable {
    case preview
    case commandTabPreview
    case windowCycle
    case finderExtension
    case livePreview
    case livePreviewLimit
    case dockClick
    case minimizeDockClick
    case hotkeys
    case hotkeyBindings
    case language
    case appearance
    case permissionState
    case all

    fileprivate static let notificationUserInfoKey = "OmniDockSettingsChange"

    public var affectsDockInteraction: Bool {
        switch self {
        case .preview, .livePreview, .livePreviewLimit, .dockClick, .all:
            return true
        case .commandTabPreview, .windowCycle, .finderExtension, .minimizeDockClick,
             .hotkeys, .hotkeyBindings, .language, .appearance, .permissionState:
            return false
        }
    }

    public var affectsCommandTabPreview: Bool {
        switch self {
        case .preview, .commandTabPreview, .all:
            return true
        case .windowCycle, .finderExtension, .livePreview, .livePreviewLimit, .dockClick,
             .minimizeDockClick, .hotkeys, .hotkeyBindings, .language, .appearance, .permissionState:
            return false
        }
    }

    public var affectsWindowCycle: Bool {
        switch self {
        case .preview, .windowCycle, .all:
            return true
        case .commandTabPreview, .finderExtension, .livePreview, .livePreviewLimit, .dockClick,
             .minimizeDockClick, .hotkeys, .hotkeyBindings, .language, .appearance, .permissionState:
            return false
        }
    }

    public var affectsAppHotkeys: Bool {
        switch self {
        case .hotkeys, .hotkeyBindings, .all:
            return true
        case .preview, .commandTabPreview, .windowCycle, .finderExtension, .livePreview,
             .livePreviewLimit, .dockClick, .minimizeDockClick, .language, .appearance, .permissionState:
            return false
        }
    }
}

public final class SettingsStore {
    public static let changedNotification = Notification.Name("OmniDockSettingsChanged")

    private enum Key: String, CaseIterable {
        case showDockPreviews = "showDockPreviews"
        case showCommandTabPreviews = "showCommandTabPreviews"
        // Keep the original storage name so existing installations retain their choice.
        case windowCycleEnabled = "independentWindowSwitcherEnabled"
        case finderExtensionEnabled = "finderExtensionEnabled"
        case finderLaunchShortcutsGrouped = "finderLaunchShortcutsGrouped"
        case finderLaunchShortcuts = "finderLaunchShortcuts"
        case finderDocumentPresets = "finderDocumentPresets"
        case liveDockPreviewsEnabled = "liveDockPreviewsEnabled"
        case livePreviewWindowLimit = "livePreviewWindowLimit"
        case toggleAppVisibilityOnDockClick = "toggleAppVisibilityOnDockClick"
        case minimizeWindowsOnDockClickInsteadOfHide = "minimizeWindowsOnDockClickInsteadOfHide"
        case hotkeysEnabled = "hotkeysEnabled"
        case hotkeyAssignments = "hotkeyAssignments"
        case minimizeOnRepeatedDockClick = "minimizeOnRepeatedDockClick"
        case appLanguage = "appLanguage"
        case appAppearance = "appAppearance"
        case permissionOnboardingCompleted = "permissionOnboardingCompleted"
        case permissionOnboardingSkipped = "permissionOnboardingSkipped"
        case pendingPermissionFeatures = "pendingPermissionFeatures"
        case lastPermissionRefreshRelaunchAttemptAt = "lastPermissionRefreshRelaunchAttemptAt"
    }

    private let defaults: UserDefaults
    private let livePreviewLimitProvider: () -> Int
    private let finderMenuPreferencesStore: FinderMenuPreferencesStore?

    public convenience init(defaults: UserDefaults = .standard) {
        let sandboxPreferences = defaults === UserDefaults.standard
            ? Self.loadSandboxPreferences()
            : nil
        self.init(
            defaults: defaults,
            livePreviewLimitProvider: { PreviewPerformanceProfile.current.recommendedLiveWindowLimit },
            finderMenuPreferencesStore: FinderMenuPreferencesStore(),
            sandboxPreferences: sandboxPreferences
        )
    }

    init(
        defaults: UserDefaults,
        livePreviewLimitProvider: @escaping () -> Int,
        finderMenuPreferencesStore: FinderMenuPreferencesStore? = nil,
        sandboxPreferences: [String: Any]? = nil
    ) {
        self.defaults = defaults
        self.livePreviewLimitProvider = livePreviewLimitProvider
        self.finderMenuPreferencesStore = finderMenuPreferencesStore
        migrateSandboxPreferencesIfNeeded(sandboxPreferences)
        migrateLegacyMinimizePreferenceIfNeeded()
        defaults.register(defaults: [
            Key.showDockPreviews.rawValue: true,
            Key.showCommandTabPreviews.rawValue: true,
            Key.windowCycleEnabled.rawValue: false,
            Key.finderExtensionEnabled.rawValue: false,
            Key.finderLaunchShortcutsGrouped.rawValue: true,
            Key.liveDockPreviewsEnabled.rawValue: true,
            Key.livePreviewWindowLimit.rawValue: min(6, max(0, livePreviewLimitProvider())),
            Key.hotkeysEnabled.rawValue: true,
            Key.appLanguage.rawValue: AppLanguage.system.rawValue,
            Key.appAppearance.rawValue: AppAppearance.system.rawValue,
            Key.permissionOnboardingCompleted.rawValue: false,
            Key.permissionOnboardingSkipped.rawValue: false
        ])
        AppLocalization.configure(language: appLanguage)
        OmniDockTheme.configure(appearance: appAppearance)
        syncFinderExtensionSettings()
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

    public var windowCycleEnabled: Bool {
        get { defaults.bool(forKey: Key.windowCycleEnabled.rawValue) }
        set { set(newValue, for: .windowCycleEnabled) }
    }

    public var finderExtensionEnabled: Bool {
        get { defaults.bool(forKey: Key.finderExtensionEnabled.rawValue) }
        set {
            defaults.set(newValue, forKey: Key.finderExtensionEnabled.rawValue)
            syncFinderExtensionSettings()
            postChange(.finderExtension)
        }
    }

    public var finderLaunchShortcutsGrouped: Bool {
        get {
            defaults.object(forKey: Key.finderLaunchShortcutsGrouped.rawValue) as? Bool ?? true
        }
        set {
            defaults.set(newValue, forKey: Key.finderLaunchShortcutsGrouped.rawValue)
            syncFinderExtensionSettings()
            postChange(.finderExtension)
        }
    }

    var finderLaunchShortcuts: [FinderLaunchShortcut] {
        get {
            decoded(
                [FinderLaunchShortcut].self,
                from: defaults.data(forKey: Key.finderLaunchShortcuts.rawValue)
            ) ?? []
        }
        set {
            defaults.set(encoded(newValue), forKey: Key.finderLaunchShortcuts.rawValue)
            syncFinderExtensionSettings()
            postChange(.finderExtension)
        }
    }

    var finderDocumentPresets: [FinderDocumentPreset] {
        get {
            decoded(
                [FinderDocumentPreset].self,
                from: defaults.data(forKey: Key.finderDocumentPresets.rawValue)
            ) ?? FinderDocumentPreset.defaultPresets
        }
        set {
            let normalized = newValue.compactMap {
                FinderDocumentPreset(
                    id: $0.id,
                    displayName: $0.displayName,
                    fileExtension: $0.fileExtension
                )
            }
            defaults.set(encoded(normalized), forKey: Key.finderDocumentPresets.rawValue)
            syncFinderExtensionSettings()
            postChange(.finderExtension)
        }
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
            syncFinderExtensionSettings()
            postChange(.language)
        }
    }

    public var appAppearance: AppAppearance {
        get {
            guard let value = defaults.string(forKey: Key.appAppearance.rawValue),
                  let appearance = AppAppearance(rawValue: value)
            else {
                return .system
            }
            return appearance
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.appAppearance.rawValue)
            OmniDockTheme.configure(appearance: newValue)
            postChange(.appearance)
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
            postChange(.hotkeyBindings)
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
            postChange(.permissionState)
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

    func addFinderLaunchShortcut(_ shortcut: FinderLaunchShortcut) {
        var shortcuts = finderLaunchShortcuts
        let newURL = shortcut.bundleURL?.standardizedFileURL
        guard !shortcuts.contains(where: {
            if let bundleIdentifier = shortcut.bundleIdentifier,
               $0.bundleIdentifier == bundleIdentifier {
                return true
            }
            return $0.bundleURL?.standardizedFileURL == newURL
        }) else {
            return
        }
        shortcuts.append(shortcut)
        finderLaunchShortcuts = shortcuts
    }

    func deleteFinderLaunchShortcut(id: UUID) {
        finderLaunchShortcuts = finderLaunchShortcuts.filter { $0.id != id }
    }

    func addFinderDocumentPreset(_ preset: FinderDocumentPreset) {
        var presets = finderDocumentPresets
        guard !presets.contains(where: {
            $0.fileExtension.caseInsensitiveCompare(preset.fileExtension) == .orderedSame
        }) else {
            return
        }
        presets.append(preset)
        finderDocumentPresets = presets
    }

    func deleteFinderDocumentPreset(id: UUID) {
        finderDocumentPresets = finderDocumentPresets.filter { $0.id != id }
    }

    public func enablePermissionBackedDefaultsAfterOnboarding() {
        defaults.set(true, forKey: Key.showDockPreviews.rawValue)
        defaults.set(true, forKey: Key.showCommandTabPreviews.rawValue)
        defaults.set(true, forKey: Key.liveDockPreviewsEnabled.rawValue)
        defaults.set(true, forKey: Key.toggleAppVisibilityOnDockClick.rawValue)
        defaults.set(true, forKey: Key.hotkeysEnabled.rawValue)
        defaults.set(true, forKey: Key.finderExtensionEnabled.rawValue)
        defaults.set(true, forKey: Key.permissionOnboardingCompleted.rawValue)
        defaults.set(false, forKey: Key.permissionOnboardingSkipped.rawValue)
        syncFinderExtensionSettings()
        postChange(.all)
    }

    private func set(_ value: Bool, for key: Key) {
        defaults.set(value, forKey: key.rawValue)
        postChange(change(for: key))
    }

    private func set(_ value: Int, for key: Key) {
        defaults.set(value, forKey: key.rawValue)
        postChange(change(for: key))
    }

    public static func change(in notification: Notification) -> SettingsChange {
        guard let rawValue = notification.userInfo?[SettingsChange.notificationUserInfoKey] as? String,
              let change = SettingsChange(rawValue: rawValue)
        else {
            return .all
        }
        return change
    }

    private func postChange(_ change: SettingsChange) {
        NotificationCenter.default.post(
            name: Self.changedNotification,
            object: self,
            userInfo: [SettingsChange.notificationUserInfoKey: change.rawValue]
        )
    }

    private func change(for key: Key) -> SettingsChange {
        switch key {
        case .showDockPreviews:
            return .preview
        case .showCommandTabPreviews:
            return .commandTabPreview
        case .windowCycleEnabled:
            return .windowCycle
        case .finderExtensionEnabled:
            return .finderExtension
        case .finderLaunchShortcutsGrouped, .finderLaunchShortcuts, .finderDocumentPresets:
            return .finderExtension
        case .liveDockPreviewsEnabled:
            return .livePreview
        case .livePreviewWindowLimit:
            return .livePreviewLimit
        case .toggleAppVisibilityOnDockClick:
            return .dockClick
        case .minimizeWindowsOnDockClickInsteadOfHide, .minimizeOnRepeatedDockClick:
            return .minimizeDockClick
        case .hotkeysEnabled:
            return .hotkeys
        case .hotkeyAssignments:
            return .hotkeyBindings
        case .appLanguage:
            return .language
        case .appAppearance:
            return .appearance
        case .permissionOnboardingCompleted, .permissionOnboardingSkipped,
             .pendingPermissionFeatures, .lastPermissionRefreshRelaunchAttemptAt:
            return .permissionState
        }
    }

    private func clampLivePreviewWindowLimit(_ value: Int) -> Int {
        min(max(value, 0), livePreviewWindowLimitMaximum)
    }

    private func syncFinderExtensionSettings() {
        finderMenuPreferencesStore?.update(FinderMenuPreferences(
            isEnabled: finderExtensionEnabled,
            languageIdentifier: appLanguage.rawValue,
            groupsLaunchShortcuts: finderLaunchShortcutsGrouped,
            launchShortcuts: finderLaunchShortcuts,
            documentPresets: finderDocumentPresets
        ))
    }

    private func encoded<T: Encodable>(_ value: T) -> Data? {
        try? JSONEncoder().encode(value)
    }

    private func decoded<T: Decodable>(_ type: T.Type, from data: Data?) -> T? {
        guard let data else {
            return nil
        }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func migrateLegacyMinimizePreferenceIfNeeded() {
        guard defaults.object(forKey: Key.toggleAppVisibilityOnDockClick.rawValue) == nil,
              let legacyValue = defaults.object(forKey: Key.minimizeOnRepeatedDockClick.rawValue) as? Bool
        else {
            return
        }
        defaults.set(legacyValue, forKey: Key.toggleAppVisibilityOnDockClick.rawValue)
    }

    private func migrateSandboxPreferencesIfNeeded(_ sandboxPreferences: [String: Any]?) {
        let migrationVersionKey = "sandboxSettingsMigrationVersion"
        guard defaults.integer(forKey: migrationVersionKey) < 1,
              let sandboxPreferences
        else {
            return
        }

        var migratedValue = false
        let excludedKeys: Set<Key> = [
            .pendingPermissionFeatures,
            .lastPermissionRefreshRelaunchAttemptAt
        ]
        for key in Key.allCases where !excludedKeys.contains(key) {
            guard let value = sandboxPreferences[key.rawValue] else {
                continue
            }
            defaults.set(value, forKey: key.rawValue)
            migratedValue = true
        }

        let directoryBookmarksKey = "finderExtensionDirectoryBookmarks"
        if let bookmarks = sandboxPreferences[directoryBookmarksKey] {
            defaults.set(bookmarks, forKey: directoryBookmarksKey)
            migratedValue = true
        }

        if migratedValue {
            defaults.set(1, forKey: migrationVersionKey)
        }
    }

    private static func loadSandboxPreferences() -> [String: Any]? {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
            return nil
        }
        let preferencesURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Containers", isDirectory: true)
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("Data/Library/Preferences", isDirectory: true)
            .appendingPathComponent("\(bundleIdentifier).plist", isDirectory: false)
        guard let data = try? Data(contentsOf: preferencesURL),
              let propertyList = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              )
        else {
            return nil
        }
        return propertyList as? [String: Any]
    }
}
