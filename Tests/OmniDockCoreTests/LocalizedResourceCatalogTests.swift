import XCTest
@testable import OmniDockCore

final class LocalizedResourceCatalogTests: XCTestCase {
    override func tearDown() {
        LocalizedResourceCatalog.configure(language: .system)
        super.tearDown()
    }

    func testSystemLanguageResolvesChinesePreferredLanguageToSimplifiedChinese() {
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: ["zh-Hans-US"]), .zhHans)
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: ["zh-Hant-TW"]), .zhHans)
    }

    func testSystemLanguageFallsBackToEnglishForUnsupportedLanguages() {
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: ["fr-FR"]), .en)
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: []), .en)
    }

    func testLocalizedStringTablesContainAllKeys() {
        for language in AppLanguage.Resolved.allCases {
            let values = LocalizedResourceCatalog.values(language: language)
            for key in AppStringKey.allCases {
                XCTAssertNotNil(values[key.rawValue], "Missing \(key.rawValue) for \(language.rawValue)")
            }
        }
    }

    func testLocalizedShortcutMessagesFollowSelectedLanguage() {
        LocalizedResourceCatalog.configure(language: .zhHans)
        XCTAssertEqual(
            ShortcutRecorderValidation.regularKeyMinimumModifierMessage,
            LocalizedResourceCatalog.text(.hotkeyGuidance, language: .zhHans)
        )

        LocalizedResourceCatalog.configure(language: .en)
        XCTAssertEqual(
            ShortcutRecorderValidation.regularKeyMinimumModifierMessage,
            LocalizedResourceCatalog.text(.hotkeyGuidance, language: .en)
        )
    }

    func testHotkeyGuidancePresentationReadsCurrentLanguageEachTime() {
        LocalizedResourceCatalog.configure(language: .en)
        XCTAssertEqual(
            HotkeyGuidancePresentation.message,
            LocalizedResourceCatalog.text(.hotkeyGuidance, language: .en)
        )

        LocalizedResourceCatalog.configure(language: .zhHans)
        XCTAssertEqual(
            HotkeyGuidancePresentation.message,
            LocalizedResourceCatalog.text(.hotkeyGuidance, language: .zhHans)
        )
    }

    func testHotkeyBindingCountUsesLocalizedCompactLabel() {
        XCTAssertEqual(
            LocalizedResourceCatalog.format(
                .hotkeysBoundCount,
                arguments: [3],
                language: .en
            ),
            "Bound apps: 3"
        )
        XCTAssertEqual(
            LocalizedResourceCatalog.format(
                .hotkeysBoundCount,
                arguments: [3],
                language: .zhHans
            ),
            "已绑定应用：3"
        )
    }

    func testLocalizationStateSupportsConcurrentReadsAndLanguageChanges() {
        let group = DispatchGroup()
        let queue = DispatchQueue(
            label: "LocalizedResourceCatalogTests.concurrent",
            attributes: .concurrent
        )

        for index in 0..<1_000 {
            group.enter()
            queue.async {
                LocalizedResourceCatalog.configure(language: index.isMultiple(of: 2) ? .en : .zhHans)
                _ = LocalizedResourceCatalog.text(.previewStaticFailure)
                _ = LocalizedResourceCatalog.format(.permissionStatusFormat, arguments: ["A", "B"])
                group.leave()
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
    }

    func testPermissionStatusFormatUsesLocalizedPunctuation() {
        XCTAssertEqual(
            LocalizedResourceCatalog.format(
                .permissionStatusFormat,
                arguments: ["Accessibility", "Granted"],
                language: .en
            ),
            "Accessibility: Granted"
        )
        XCTAssertEqual(
            LocalizedResourceCatalog.format(
                .permissionStatusFormat,
                arguments: ["辅助功能", "已授权"],
                language: .zhHans
            ),
            "辅助功能：已授权"
        )
    }

    func testApplicationPickerLoadingMessagesAreLocalized() {
        let expectations: [(AppLanguage, [AppStringKey: String])] = [
            (
                .en,
                [
                    .pickerLoading: "Loading apps...",
                    .pickerLoadFailure: "Could not load apps.",
                    .pickerRetry: "Retry"
                ]
            ),
            (
                .zhHans,
                [
                    .pickerLoading: "正在加载应用…",
                    .pickerLoadFailure: "无法加载应用。",
                    .pickerRetry: "重试"
                ]
            )
        ]

        for (language, values) in expectations {
            for (key, expectedValue) in values {
                XCTAssertEqual(LocalizedResourceCatalog.text(key, language: language), expectedValue)
            }
        }
    }

    func testAppearanceLabelsAreLocalized() {
        XCTAssertEqual(LocalizedResourceCatalog.text(.appearanceTitle, language: .en), "Appearance")
        XCTAssertEqual(LocalizedResourceCatalog.text(.appearanceDark, language: .en), "Dark")
        XCTAssertEqual(LocalizedResourceCatalog.text(.appearanceTitle, language: .zhHans), "外观")
        XCTAssertEqual(LocalizedResourceCatalog.text(.appearanceDark, language: .zhHans), "深色")
    }

    func testFinderExtensionLabelsAreLocalized() {
        XCTAssertEqual(LocalizedResourceCatalog.text(.tabSettings, language: .en), "Settings")
        XCTAssertEqual(LocalizedResourceCatalog.text(.tabFinderExtension, language: .en), "Finder Extension")
        XCTAssertEqual(LocalizedResourceCatalog.text(.finderExtensionEnableTitle, language: .en), "Enable")
        XCTAssertEqual(LocalizedResourceCatalog.text(.finderExtensionOpenSettings, language: .en), "Open Finder Extensions")
        XCTAssertEqual(LocalizedResourceCatalog.text(.finderQuickOpenTitle, language: .en), "Quick Actions")
        XCTAssertEqual(LocalizedResourceCatalog.text(.finderQuickOpenLoading, language: .en), "Checking…")
        XCTAssertEqual(LocalizedResourceCatalog.text(.finderQuickOpenInstalled, language: .en), "Installed")
        XCTAssertEqual(LocalizedResourceCatalog.text(.finderQuickOpenNotInstalled, language: .en), "Not Installed")
        XCTAssertEqual(LocalizedResourceCatalog.text(.tabSettings, language: .zhHans), "设置")
        XCTAssertEqual(LocalizedResourceCatalog.text(.tabFinderExtension, language: .zhHans), "右键扩展")
        XCTAssertEqual(LocalizedResourceCatalog.text(.finderExtensionEnableTitle, language: .zhHans), "启用")
        XCTAssertEqual(LocalizedResourceCatalog.text(.finderExtensionOpenSettings, language: .zhHans), "打开 Finder 扩展设置")
        XCTAssertEqual(LocalizedResourceCatalog.text(.finderQuickOpenTitle, language: .zhHans), "快捷操作")
        XCTAssertEqual(LocalizedResourceCatalog.text(.finderQuickOpenLoading, language: .zhHans), "正在检测…")
        XCTAssertEqual(LocalizedResourceCatalog.text(.finderQuickOpenInstalled, language: .zhHans), "已安装")
        XCTAssertEqual(LocalizedResourceCatalog.text(.finderQuickOpenNotInstalled, language: .zhHans), "未安装")
    }

    func testEverySettingsTabHasAStatusMenuTitle() {
        XCTAssertEqual(
            SettingsTab.allCases.map(\.titleKey),
            [
                .tabSettings,
                .tabPreview,
                .tabHotkeys,
                .tabFinderExtension,
                .tabClipboardHistory,
                .tabWindowPlacement
            ]
        )
    }

    func testScreenRecordingDisclosuresMentionLiveAndStaticThumbnails() {
        let expectations: [(AppLanguage.Resolved, [String])] = [
            (.en, ["live images", "one-time static snapshots"]),
            (.zhHans, ["实时画面", "一次性静态截图"])
        ]

        for (language, requiredFragments) in expectations {
            let appValues = LocalizedResourceCatalog.values(language: language)
            let infoPlistValues = LocalizedResourceCatalog.infoPlistValues(language: language)
            let disclosures = [
                appValues[AppStringKey.onboardingScreenRecordingPurpose.rawValue, default: ""],
                appValues[AppStringKey.previewNeedsScreenRecording.rawValue, default: ""],
                infoPlistValues["NSScreenCaptureUsageDescription", default: ""]
            ]

            for disclosure in disclosures {
                for fragment in requiredFragments {
                    XCTAssertTrue(
                        disclosure.contains(fragment),
                        "Missing \(fragment) from \(language.rawValue) screen recording disclosure: \(disclosure)"
                    )
                }
            }
        }
    }

    func testInfoPlistPermissionStringsExistForSupportedLanguages() throws {
        let keys = [
            "NSScreenCaptureUsageDescription",
            "NSInputMonitoringUsageDescription"
        ]

        for language in AppLanguage.Resolved.allCases {
            let values = LocalizedResourceCatalog.infoPlistValues(language: language)
            for key in keys {
                XCTAssertFalse(values[key, default: ""].isEmpty, "Missing \(key) for \(language.rawValue)")
            }
        }
    }
}
