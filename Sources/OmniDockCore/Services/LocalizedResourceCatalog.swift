import Foundation

enum AppStringKey: String, CaseIterable {
    case languageTitle
    case languageDetail
    case languageSystem
    case languageChinese
    case languageEnglish
    case appearanceTitle
    case appearanceDetail
    case appearanceSystem
    case appearanceLight
    case appearanceDark
    case updateVersionTitle
    case updateVersionDetail
    case updateCurrentVersion
    case updateNeverChecked
    case updateChecking
    case updateCurrentStatus
    case updateAvailableStatus
    case updateFailedStatus
    case updateCheckButton
    case updateWindowTitle
    case updatePreparingDownload
    case updateDownloadProgress
    case updateInstalling
    case updateCancel
    case updateAvailableTitle
    case updateAvailableDetail
    case updateReleaseOnlyDetail
    case updateDownloadAndInstall
    case updateLater
    case updateViewRelease
    case updateCurrentTitle
    case updateCurrentDetail
    case updateCheckFailedTitle
    case updateCheckFailedDetail
    case updateManualInstallTitle
    case updateManualInstallDetail
    case updateInstallFailedTitle
    case updateDownloadValidationFailed
    case updateSignatureValidationFailed
    case updateCompatibilityFailed
    case updateReplacementFailed
    case updateOK

    case tabSettings
    case tabPreview
    case tabHotkeys
    case tabFinderExtension
    case tabClipboardHistory
    case tabWindowPlacement
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
    case settingsWindowCycleTitle
    case settingsWindowCycleDetail
    case settingsWindowCycleUnavailable
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

    case finderExtensionEnableTitle
    case finderExtensionEnableDetail
    case finderExtensionSetupRequired
    case finderExtensionOpenSettings
    case finderExtensionCreateFailedTitle
    case finderExtensionCreateFailedDetail
    case finderExtensionFailureDismiss
    case finderExtensionAccessDetail
    case finderExtensionAccessButton
    case finderQuickOpenTitle
    case finderQuickOpenDetail
    case finderQuickOpenGroupedTitle
    case finderQuickOpenGroupedDetail
    case finderQuickOpenAdd
    case finderQuickOpenEmpty
    case finderQuickOpenEnabled
    case finderQuickOpenApplication
    case finderQuickOpenStatus
    case finderQuickOpenLoading
    case finderQuickOpenInstalled
    case finderQuickOpenNotInstalled
    case finderQuickOpenFailedTitle
    case finderQuickOpenFailedDetail
    case finderQuickOpenApplicationMissing
    case finderDocumentTypesTitle
    case finderDocumentTypesDetail
    case finderDocumentTypeAdd
    case finderDocumentTypeName
    case finderDocumentTypeExtension
    case finderDocumentTypeEnabled
    case finderDocumentTypeInvalid
    case finderDocumentTypeDuplicate
    case finderRemove
    case finderPermissionStatus
    case folderAccessPanelTitle
    case folderAccessPanelDetail
    case folderAccessPanelChoose

    case permissionAccessibility
    case permissionScreenRecording
    case permissionInputMonitoring
    case permissionFinderExtension
    case permissionFolderAccess
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
    case onboardingFinderExtensionPurpose
    case onboardingFolderAccessPurpose
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
    case hotkeysBoundCount
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
    case hotkeyReservedForClipboardHistory

    case clipboardEnableTitle
    case clipboardEnableDetail
    case clipboardShortcutTitle
    case clipboardShortcutDetail
    case clipboardShortcutConflict
    case clipboardLimitTitle
    case clipboardLimitDetail
    case clipboardPrivacyNote
    case clipboardSearchPlaceholder
    case clipboardEmpty
    case clipboardClearAll
    case clipboardClearTitle
    case clipboardClearDetail
    case clipboardCopy
    case clipboardDelete
    case clipboardImage
    case clipboardImageCount
    case clipboardUnknownContent
    case clipboardStorageUnavailable
    case clipboardCopyFailed
    case clipboardPasteNeedsAccessibility
    case clipboardPreviewFirstCopied
    case clipboardPreviewLastCopied
    case clipboardPreviewCopyCount
    case clipboardPreviewFiles

    case windowPlacementEnableTitle
    case windowPlacementEnableDetail
    case windowPlacementGreenButtonTitle
    case windowPlacementGreenButtonDetail
    case windowPlacementDragTitle
    case windowPlacementDragDetail
    case windowPlacementCommands
    case windowPlacementAdd
    case windowPlacementRemove
    case windowPlacementMoveUp
    case windowPlacementMoveDown
    case windowPlacementCustomDefaultName
    case windowPlacementTargetRegion
    case windowPlacementShortcut
    case windowPlacementActivationRegion
    case windowPlacementNoActivationRegion
    case windowPlacementActivationConflict
    case windowPlacementShortcutConflict
    case windowPlacementRegistrationWarning
    case windowPlacementOpenSettings
    case windowPlacementLeftHalf
    case windowPlacementRightHalf
    case windowPlacementTopHalf
    case windowPlacementBottomHalf
    case windowPlacementTopLeft
    case windowPlacementTopRight
    case windowPlacementBottomLeft
    case windowPlacementBottomRight
    case windowPlacementLeftThird
    case windowPlacementCenterThird
    case windowPlacementRightThird
    case windowPlacementLeftTwoThirds
    case windowPlacementCenterTwoThirds
    case windowPlacementRightTwoThirds
    case windowPlacementNextDisplay
    case windowPlacementPreviousDisplay
    case windowPlacementMaximize
    case windowPlacementCenter
    case windowPlacementRestore

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
    case previewWindowContentUnavailable
}

enum LocalizedResourceCatalog {
    static let tableName = "AppStrings"

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var selectedLanguage: AppLanguage = .system
        // Resolving `.system` reads Locale.preferredLanguages, which is a
        // CFPreferences round trip. Strings are fetched constantly (including
        // from background queues), so the resolved language is cached and
        // invalidated when the selection or the system locale changes. The
        // cache stores the selection it was resolved for so a concurrent
        // configure() can never be clobbered by a stale write-back.
        var cachedResolution: (selected: AppLanguage, resolved: AppLanguage.Resolved)?
        var cache: [AppLanguage.Resolved: [String: String]] = [:]
        private var localeObserver: NSObjectProtocol?

        init() {
            localeObserver = NotificationCenter.default.addObserver(
                forName: NSLocale.currentLocaleDidChangeNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                guard let self else {
                    return
                }
                self.lock.lock()
                self.cachedResolution = nil
                self.lock.unlock()
            }
        }
    }

    private static let state = State()

    static func configure(language: AppLanguage) {
        state.lock.lock()
        state.selectedLanguage = language
        state.cachedResolution = nil
        state.lock.unlock()
    }

    static var currentLanguage: AppLanguage {
        state.lock.lock()
        defer { state.lock.unlock() }
        return state.selectedLanguage
    }

    static var currentResolvedLanguage: AppLanguage.Resolved {
        state.lock.lock()
        let selected = state.selectedLanguage
        if let cached = state.cachedResolution, cached.selected == selected {
            state.lock.unlock()
            return cached.resolved
        }
        state.lock.unlock()

        let resolved = selected.resolved()
        state.lock.lock()
        // Only publish the result if the selection has not changed while the
        // lock was released; otherwise return the fresh value without caching
        // so a concurrent configure() is never overwritten with stale data.
        if state.selectedLanguage == selected {
            state.cachedResolution = (selected, resolved)
        }
        state.lock.unlock()
        return resolved
    }

    static func text(_ key: AppStringKey, language: AppLanguage? = nil) -> String {
        let resolvedLanguage = language?.resolved() ?? currentResolvedLanguage
        return localizedValue(for: key, language: resolvedLanguage)
    }

    static func text(_ key: AppStringKey, _ arguments: CVarArg..., language: AppLanguage? = nil) -> String {
        format(key, arguments: arguments, language: language)
    }

    static func format(_ key: AppStringKey, arguments: [CVarArg], language: AppLanguage? = nil) -> String {
        let resolvedLanguage = language?.resolved() ?? currentResolvedLanguage
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
        LocalizedResourceCatalog.text(key)
    }

    static func format(_ key: AppStringKey, _ arguments: CVarArg...) -> String {
        LocalizedResourceCatalog.format(key, arguments: arguments)
    }

    static func permissionTitle(_ kind: PermissionKind) -> String {
        switch kind {
        case .accessibility:
            return text(.permissionAccessibility)
        case .screenRecording:
            return text(.permissionScreenRecording)
        case .inputMonitoring:
            return text(.permissionInputMonitoring)
        case .finderExtension:
            return text(.permissionFinderExtension)
        case .folderAccess:
            return text(.permissionFolderAccess)
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
        case .finderExtension:
            return text(.onboardingFinderExtensionPurpose)
        case .folderAccess:
            return text(.onboardingFolderAccessPurpose)
        }
    }
}
