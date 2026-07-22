import Foundation

enum AppStringKey: String, CaseIterable {
    case languageTitle
    case languageDetail
    case languageSystem
    case languageChinese
    case languageEnglish

    case tabSettings
    case tabHotkeys
    case menuSettings
    case menuHotkeys
    case menuQuit
    case mainMenuSettings
    case mainMenuHide
    case mainMenuQuit
    case mainMenuEdit
    case mainMenuUndo
    case mainMenuRedo
    case mainMenuCut
    case mainMenuCopy
    case mainMenuPaste
    case mainMenuSelectAll
    case mainMenuWindow
    case mainMenuClose
    case mainMenuBringAllToFront

    case settingsDockPreviewTitle
    case settingsDockPreviewDetail
    case settingsCommandTabPreviewTitle
    case settingsCommandTabPreviewDetail
    case settingsLivePreviewTitle
    case settingsLivePreviewDetail
    case settingsDockClickTitle
    case settingsDockClickDetail
    case settingsMinimizeTitle
    case settingsMinimizeDetail
    case settingsPermissionStatus
    case settingsPermissionGuide
    case settingsLiveWindowCount
    case settingsPrivacyPolicy
    case settingsSupport

    case permissionAccessibility
    case permissionScreenRecording
    case permissionInputMonitoring
    case permissionGranted
    case permissionNotGranted
    case permissionStatusFormat
    case permissionOpenTooltip

    case onboardingTitle
    case onboardingSubtitle
    case onboardingPrivacyNote
    case onboardingAccessibilityPurpose
    case onboardingInputMonitoringPurpose
    case onboardingScreenRecordingPurpose
    case onboardingStatusReady
    case onboardingStatusNeedsPermissions
    case onboardingStatusRefreshing
    case onboardingGoEnable
    case onboardingEnabled
    case onboardingContinue
    case onboardingFinish
    case onboardingLater

    case hotkeysEnableTitle
    case hotkeysEnableDetail
    case hotkeysChooseApp
    case hotkeysEmpty
    case hotkeyRemove
    case hotkeyAppUnavailable
    case hotkeyUnavailable
    case hotkeyRecording
    case hotkeyRecord
    case hotkeyGuidance
    case hotkeyNeedsRegularKey
    case hotkeyCapsLock
    case hotkeyFnUnsupported
    case hotkeyDuplicate
    case hotkeyCommonMenu
    case hotkeyBrowserTab
    case hotkeySystemConflict
    case hotkeyRegistrationOccupied
    case hotkeyRegistrationFailed

    case pickerTitle
    case pickerSearchPlaceholder
    case pickerSelect
    case pickerCancel
    case pickerBrowseOther
    case pickerLoading
    case pickerEmpty
    case pickerLoadFailure
    case pickerRetry
    case pickerSelectedName
    case pickerSystemBadge
    case pickerApplicationBadge
    case genericApplication

    case previewNeedsScreenRecording
    case previewNoWindows
    case previewCloseFailed
    case previewHiddenNoStatic
    case previewMinimizedClickRestore
    case previewCloseWindow
    case previewQuitApplication
    case previewQuitFailed
    case previewReadFailure
    case previewNoContent
    case previewNoNormalWindow
    case previewStreamCreateFailure
    case previewStreamStartFailure
    case previewStreamStop
    case previewStaticFailureWithReason
    case previewStaticFailure
}

enum AppLocalization {
    static let tableName = "AppStrings"

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var selectedLanguage: AppLanguage = .system
        var cache: [AppLanguage.Resolved: [String: String]] = [:]
    }

    private static let state = State()

    static func configure(language: AppLanguage) {
        state.lock.lock()
        state.selectedLanguage = language
        state.lock.unlock()
    }

    static var currentLanguage: AppLanguage {
        state.lock.lock()
        defer { state.lock.unlock() }
        return state.selectedLanguage
    }

    static var currentResolvedLanguage: AppLanguage.Resolved {
        currentLanguage.resolved()
    }

    static func text(_ key: AppStringKey, language: AppLanguage? = nil) -> String {
        let resolvedLanguage = (language ?? currentLanguage).resolved()
        return localizedValue(for: key, language: resolvedLanguage)
    }

    static func text(_ key: AppStringKey, _ arguments: CVarArg..., language: AppLanguage? = nil) -> String {
        format(key, arguments: arguments, language: language)
    }

    static func format(_ key: AppStringKey, arguments: [CVarArg], language: AppLanguage? = nil) -> String {
        let resolvedLanguage = (language ?? currentLanguage).resolved()
        let format = localizedValue(for: key, language: resolvedLanguage)
        return String(
            format: format,
            locale: Locale(identifier: resolvedLanguage.rawValue),
            arguments: arguments
        )
    }

    static func values(language: AppLanguage.Resolved) -> [String: String] {
        state.lock.lock()
        if let cached = state.cache[language] {
            state.lock.unlock()
            return cached
        }
        state.lock.unlock()

        let loaded = loadValues(tableName: tableName, language: language)
        state.lock.lock()
        if let cached = state.cache[language] {
            state.lock.unlock()
            return cached
        }
        state.cache[language] = loaded
        state.lock.unlock()
        return loaded
    }

    static func infoPlistValues(language: AppLanguage.Resolved) -> [String: String] {
        loadValues(tableName: "InfoPlist", language: language)
    }

    private static func localizedValue(for key: AppStringKey, language: AppLanguage.Resolved) -> String {
        if let value = values(language: language)[key.rawValue] {
            return value
        }
        if language != .en,
           let fallback = values(language: .en)[key.rawValue] {
            return fallback
        }
        return key.rawValue
    }

    private static func loadValues(tableName: String, language: AppLanguage.Resolved) -> [String: String] {
        if let dictionary = loadValues(tableName: tableName, language: language, bundle: .main) {
            return dictionary
        }

        #if SWIFT_PACKAGE && !OMNIDOCK_APP_BUNDLE_BUILD
        if let dictionary = loadValues(tableName: tableName, language: language, bundle: .module) {
            return dictionary
        }
        #endif

        return [:]
    }

    private static func loadValues(
        tableName: String,
        language: AppLanguage.Resolved,
        bundle: Bundle
    ) -> [String: String]? {
        guard let url = bundle.url(
            forResource: tableName,
            withExtension: "strings",
            subdirectory: nil,
            localization: language.rawValue
        ) else {
            return nil
        }
        return NSDictionary(contentsOf: url) as? [String: String]
    }
}

enum AppStrings {
    static func text(_ key: AppStringKey) -> String {
        AppLocalization.text(key)
    }

    static func format(_ key: AppStringKey, _ arguments: CVarArg...) -> String {
        AppLocalization.format(key, arguments: arguments)
    }

    static func permissionTitle(_ kind: PermissionKind) -> String {
        switch kind {
        case .accessibility:
            return text(.permissionAccessibility)
        case .screenRecording:
            return text(.permissionScreenRecording)
        case .inputMonitoring:
            return text(.permissionInputMonitoring)
        }
    }

    static func onboardingPurpose(_ kind: PermissionKind) -> String {
        switch kind {
        case .accessibility:
            return text(.onboardingAccessibilityPurpose)
        case .screenRecording:
            return text(.onboardingScreenRecordingPurpose)
        case .inputMonitoring:
            return text(.onboardingInputMonitoringPurpose)
        }
    }
}
