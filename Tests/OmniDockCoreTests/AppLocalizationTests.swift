import XCTest
@testable import OmniDockCore

final class AppLocalizationTests: XCTestCase {
    override func tearDown() {
        AppLocalization.configure(language: .system)
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
            let values = AppLocalization.values(language: language)
            for key in AppStringKey.allCases {
                XCTAssertNotNil(values[key.rawValue], "Missing \(key.rawValue) for \(language.rawValue)")
            }
        }
    }

    func testLocalizedShortcutMessagesFollowSelectedLanguage() {
        AppLocalization.configure(language: .zhHans)
        XCTAssertEqual(
            ShortcutRecorderValidation.regularKeyMinimumModifierMessage,
            AppLocalization.text(.hotkeyGuidance, language: .zhHans)
        )

        AppLocalization.configure(language: .en)
        XCTAssertEqual(
            ShortcutRecorderValidation.regularKeyMinimumModifierMessage,
            AppLocalization.text(.hotkeyGuidance, language: .en)
        )
    }

    func testHotkeyGuidancePresentationReadsCurrentLanguageEachTime() {
        AppLocalization.configure(language: .en)
        XCTAssertEqual(
            HotkeyGuidancePresentation.message,
            AppLocalization.text(.hotkeyGuidance, language: .en)
        )

        AppLocalization.configure(language: .zhHans)
        XCTAssertEqual(
            HotkeyGuidancePresentation.message,
            AppLocalization.text(.hotkeyGuidance, language: .zhHans)
        )
    }

    func testLocalizationStateSupportsConcurrentReadsAndLanguageChanges() {
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "AppLocalizationTests.concurrent", attributes: .concurrent)

        for index in 0..<1_000 {
            group.enter()
            queue.async {
                AppLocalization.configure(language: index.isMultiple(of: 2) ? .en : .zhHans)
                _ = AppLocalization.text(.previewStaticFailure)
                _ = AppLocalization.format(.permissionStatusFormat, arguments: ["A", "B"])
                group.leave()
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
    }

    func testPermissionStatusFormatUsesLocalizedPunctuation() {
        XCTAssertEqual(
            AppLocalization.format(
                .permissionStatusFormat,
                arguments: ["Accessibility", "Granted"],
                language: .en
            ),
            "Accessibility: Granted"
        )
        XCTAssertEqual(
            AppLocalization.format(
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
                XCTAssertEqual(AppLocalization.text(key, language: language), expectedValue)
            }
        }
    }

    func testAppearanceLabelsAreLocalized() {
        XCTAssertEqual(AppLocalization.text(.appearanceTitle, language: .en), "Appearance")
        XCTAssertEqual(AppLocalization.text(.appearanceDark, language: .en), "Dark")
        XCTAssertEqual(AppLocalization.text(.appearanceTitle, language: .zhHans), "外观")
        XCTAssertEqual(AppLocalization.text(.appearanceDark, language: .zhHans), "深色")
    }

    func testFinderExtensionLabelsAreLocalized() {
        XCTAssertEqual(AppLocalization.text(.tabSettings, language: .en), "Setting")
        XCTAssertEqual(AppLocalization.text(.tabFinderExtension, language: .en), "Finder Extension")
        XCTAssertEqual(AppLocalization.text(.finderExtensionEnableTitle, language: .en), "Enable")
        XCTAssertEqual(AppLocalization.text(.finderExtensionOpenSettings, language: .en), "Open Finder Extensions")
        XCTAssertEqual(AppLocalization.text(.tabSettings, language: .zhHans), "设置")
        XCTAssertEqual(AppLocalization.text(.tabFinderExtension, language: .zhHans), "右键扩展")
        XCTAssertEqual(AppLocalization.text(.finderExtensionEnableTitle, language: .zhHans), "启用")
        XCTAssertEqual(AppLocalization.text(.finderExtensionOpenSettings, language: .zhHans), "打开 Finder 扩展设置")
    }

    func testScreenRecordingDisclosuresMentionLiveAndStaticThumbnails() {
        let expectations: [(AppLanguage.Resolved, [String])] = [
            (.en, ["live images", "one-time static snapshots"]),
            (.zhHans, ["实时画面", "一次性静态截图"])
        ]

        for (language, requiredFragments) in expectations {
            let appValues = AppLocalization.values(language: language)
            let infoPlistValues = AppLocalization.infoPlistValues(language: language)
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
            let values = AppLocalization.infoPlistValues(language: language)
            for key in keys {
                XCTAssertFalse(values[key, default: ""].isEmpty, "Missing \(key) for \(language.rawValue)")
            }
        }
    }
}
