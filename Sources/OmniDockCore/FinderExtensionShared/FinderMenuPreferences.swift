import Foundation

struct FinderLaunchShortcut: Codable, Equatable, Hashable, Identifiable {
    private static let terminalIdentifier = UUID(uuidString: "E7DA8E94-B549-4B5A-B839-531212685D2A")!
    private static let iTermIdentifier = UUID(uuidString: "06FDDE36-9A9E-4492-AFEA-6E6A83D64E03")!
    private static let visualStudioCodeIdentifier = UUID(uuidString: "7EC4217C-070F-40DB-B9EA-18092E106EA7")!
    private static let sublimeTextIdentifier = UUID(uuidString: "2CE802B5-10D6-480E-902B-7780D4B262E2")!
    private static let sublimeMergeIdentifier = UUID(uuidString: "FE3F27A5-6A7B-44D3-99F5-6486F3074ADB")!
    private static let warpIdentifier = UUID(uuidString: "C3E530B1-12EE-43AB-8EE6-728D0D458189")!
    private static let markTextIdentifier = UUID(uuidString: "EC18C7B6-CFB2-47D2-AF3B-3F3AA4A25E66")!
    private static let obsidianIdentifier = UUID(uuidString: "01A6930B-6829-4788-B5C5-E656EB17EF51")!
    private static let tabbyIdentifier = UUID(uuidString: "390C7E40-685E-415E-8FAF-8E8880AA77CC")!
    private static let visualStudioIdentifier = UUID(uuidString: "AF642333-5101-4C4B-8E5C-FC6AB2BBFF77")!
    private static let hyperIdentifier = UUID(uuidString: "B264A03A-221C-4D68-B8A7-1F4245D41AD7")!
    private static let emacsIdentifier = UUID(uuidString: "9DF4D768-E4C2-4670-A078-CDB383C1C48B")!
    private static let clionIdentifier = UUID(uuidString: "EF13ED00-2EEA-4550-A80C-60320BC11E0A")!
    private static let cotEditorIdentifier = UUID(uuidString: "05FB89B0-C4A8-4FA8-92B8-CAFEA48DF5E0")!
    private static let hBuilderIdentifier = UUID(uuidString: "1EFC3A7B-5C3D-44F4-834F-4839D34874EC")!
    private static let phpStormIdentifier = UUID(uuidString: "8394451A-A44D-4901-9136-9C8D30562A87")!
    private static let pyCharmIdentifier = UUID(uuidString: "3807FB6D-EEED-42FF-A1F0-63FAD1D0991A")!
    private static let typoraIdentifier = UUID(uuidString: "824D5855-7DA7-4555-AF5B-7E8D47DD0E9B")!
    private static let webStormIdentifier = UUID(uuidString: "C5661FCB-6475-4B4C-BD18-EC176353427F")!
    private static let intelliJIdentifier = UUID(uuidString: "1530A9FC-BCD9-468B-83E9-461012CA101A")!
    private static let androidStudioIdentifier = UUID(uuidString: "4047AFC3-2A5E-4373-AF7D-85FB35221A0B")!
    private static let appCodeIdentifier = UUID(uuidString: "44B072CA-6914-4AAA-9AEB-090B671CAB27")!
    private static let dataGripIdentifier = UUID(uuidString: "A2DED71C-81D1-44E4-A527-2153CC83B641")!
    private static let goLandIdentifier = UUID(uuidString: "1432BC6F-185C-4276-9EEE-67F1BE83040D")!
    private static let riderIdentifier = UUID(uuidString: "D8D8B6E7-81A3-4AA4-B49B-B3008A3440B6")!
    private static let rubyMineIdentifier = UUID(uuidString: "857339ED-9ECA-4A70-89C8-16A701F359BB")!

    let id: UUID
    var displayName: String
    var bundleURLString: String
    var bundleIdentifier: String?
    var isEnabled: Bool

    init(
        id: UUID = UUID(),
        displayName: String,
        bundleURLString: String,
        bundleIdentifier: String?,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.displayName = displayName
        self.bundleURLString = bundleURLString
        self.bundleIdentifier = bundleIdentifier
        self.isEnabled = isEnabled
    }

    var bundleURL: URL? {
        URL(string: bundleURLString)
    }

    var isBuiltIn: Bool {
        Self.defaultShortcuts.contains { $0.id == id }
    }

    static let defaultShortcuts: [FinderLaunchShortcut] = [
        builtIn(
            id: terminalIdentifier,
            name: "Terminal",
            path: "/System/Applications/Utilities/Terminal.app",
            bundleIdentifier: "com.apple.Terminal"
        ),
        builtIn(
            id: iTermIdentifier,
            name: "iTerm2",
            path: "/Applications/iTerm.app",
            bundleIdentifier: "com.googlecode.iterm2"
        ),
        builtIn(
            id: visualStudioCodeIdentifier,
            name: "Visual Studio Code",
            path: "/Applications/Visual Studio Code.app",
            bundleIdentifier: "com.microsoft.VSCode"
        ),
        builtIn(
            id: sublimeTextIdentifier,
            name: "Sublime Text",
            path: "/Applications/Sublime Text.app",
            bundleIdentifier: "com.sublimetext.4"
        ),
        builtIn(
            id: sublimeMergeIdentifier,
            name: "Sublime Merge",
            path: "/Applications/Sublime Merge.app",
            bundleIdentifier: "com.sublimemerge"
        ),
        builtIn(
            id: warpIdentifier,
            name: "Warp",
            path: "/Applications/Warp.app",
            bundleIdentifier: "dev.warp.Warp-Stable"
        ),
        builtIn(
            id: markTextIdentifier,
            name: "MarkText",
            path: "/Applications/MarkText.app",
            bundleIdentifier: "com.github.marktext.marktext"
        ),
        builtIn(
            id: obsidianIdentifier,
            name: "Obsidian",
            path: "/Applications/Obsidian.app",
            bundleIdentifier: "md.obsidian"
        ),
        builtIn(
            id: tabbyIdentifier,
            name: "Tabby",
            path: "/Applications/Tabby.app",
            bundleIdentifier: "org.tabby"
        ),
        builtIn(
            id: visualStudioIdentifier,
            name: "Visual Studio",
            path: "/Applications/Visual Studio.app",
            bundleIdentifier: "com.microsoft.visual-studio"
        ),
        builtIn(
            id: hyperIdentifier,
            name: "Hyper",
            path: "/Applications/Hyper.app",
            bundleIdentifier: "co.zeit.hyper"
        ),
        builtIn(
            id: emacsIdentifier,
            name: "Emacs",
            path: "/Applications/Emacs.app",
            bundleIdentifier: "org.gnu.Emacs"
        ),
        builtIn(
            id: clionIdentifier,
            name: "CLion",
            path: "/Applications/CLion.app",
            bundleIdentifier: "com.jetbrains.CLion"
        ),
        builtIn(
            id: cotEditorIdentifier,
            name: "CotEditor",
            path: "/Applications/CotEditor.app",
            bundleIdentifier: "com.coteditor.CotEditor"
        ),
        builtIn(
            id: hBuilderIdentifier,
            name: "HBuilderX",
            path: "/Applications/HBuilderX.app",
            bundleIdentifier: "io.dcloud.HBuilder"
        ),
        builtIn(
            id: phpStormIdentifier,
            name: "PhpStorm",
            path: "/Applications/PhpStorm.app",
            bundleIdentifier: "com.jetbrains.PhpStorm"
        ),
        builtIn(
            id: pyCharmIdentifier,
            name: "PyCharm",
            path: "/Applications/PyCharm.app",
            bundleIdentifier: "com.jetbrains.pycharm"
        ),
        builtIn(
            id: typoraIdentifier,
            name: "Typora",
            path: "/Applications/Typora.app",
            bundleIdentifier: "abnerworks.Typora"
        ),
        builtIn(
            id: webStormIdentifier,
            name: "WebStorm",
            path: "/Applications/WebStorm.app",
            bundleIdentifier: "com.jetbrains.WebStorm"
        ),
        builtIn(
            id: intelliJIdentifier,
            name: "IntelliJ IDEA",
            path: "/Applications/IntelliJ IDEA.app",
            bundleIdentifier: "com.jetbrains.intellij"
        ),
        builtIn(
            id: androidStudioIdentifier,
            name: "Android Studio",
            path: "/Applications/Android Studio.app",
            bundleIdentifier: "com.google.android.studio"
        ),
        builtIn(
            id: appCodeIdentifier,
            name: "AppCode",
            path: "/Applications/AppCode.app",
            bundleIdentifier: "com.jetbrains.AppCode"
        ),
        builtIn(
            id: dataGripIdentifier,
            name: "DataGrip",
            path: "/Applications/DataGrip.app",
            bundleIdentifier: "com.jetbrains.datagrip"
        ),
        builtIn(
            id: goLandIdentifier,
            name: "GoLand",
            path: "/Applications/GoLand.app",
            bundleIdentifier: "com.jetbrains.goland"
        ),
        builtIn(
            id: riderIdentifier,
            name: "Rider",
            path: "/Applications/Rider.app",
            bundleIdentifier: "com.jetbrains.rider"
        ),
        builtIn(
            id: rubyMineIdentifier,
            name: "RubyMine",
            path: "/Applications/RubyMine.app",
            bundleIdentifier: "com.jetbrains.rubymine"
        )
    ]

    static func catalog(
        merging savedShortcuts: [FinderLaunchShortcut],
        missingBuiltInsUseDefaults: Bool
    ) -> [FinderLaunchShortcut] {
        var remaining = savedShortcuts
        var result: [FinderLaunchShortcut] = []

        for builtIn in defaultShortcuts {
            let index = remaining.firstIndex {
                $0.id == builtIn.id
                    || identifiersMatch($0.bundleIdentifier, builtIn.bundleIdentifier)
                    || urlsMatch($0.bundleURL, builtIn.bundleURL)
            }
            if let index {
                let saved = remaining.remove(at: index)
                result.append(FinderLaunchShortcut(
                    id: builtIn.id,
                    displayName: builtIn.displayName,
                    bundleURLString: saved.bundleURLString.isEmpty
                        ? builtIn.bundleURLString
                        : saved.bundleURLString,
                    bundleIdentifier: saved.bundleIdentifier ?? builtIn.bundleIdentifier,
                    isEnabled: saved.isEnabled
                ))
            } else {
                result.append(FinderLaunchShortcut(
                    id: builtIn.id,
                    displayName: builtIn.displayName,
                    bundleURLString: builtIn.bundleURLString,
                    bundleIdentifier: builtIn.bundleIdentifier,
                    isEnabled: missingBuiltInsUseDefaults ? builtIn.isEnabled : false
                ))
            }
        }

        for shortcut in remaining where !result.contains(where: {
            identifiersMatch($0.bundleIdentifier, shortcut.bundleIdentifier)
                || urlsMatch($0.bundleURL, shortcut.bundleURL)
        }) {
            result.append(shortcut)
        }
        return result
    }

    private static func builtIn(
        id: UUID,
        name: String,
        path: String,
        bundleIdentifier: String
    ) -> FinderLaunchShortcut {
        FinderLaunchShortcut(
            id: id,
            displayName: name,
            bundleURLString: URL(fileURLWithPath: path).absoluteString,
            bundleIdentifier: bundleIdentifier,
            isEnabled: false
        )
    }

    private static func identifiersMatch(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs else {
            return false
        }
        return lhs.caseInsensitiveCompare(rhs) == .orderedSame
    }

    private static func urlsMatch(_ lhs: URL?, _ rhs: URL?) -> Bool {
        guard let lhs, let rhs else {
            return false
        }
        return lhs.standardizedFileURL == rhs.standardizedFileURL
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case bundleURLString
        case bundleIdentifier
        case isEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        bundleURLString = try container.decode(String.self, forKey: .bundleURLString)
        bundleIdentifier = try container.decodeIfPresent(
            String.self,
            forKey: .bundleIdentifier
        )
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }
}

struct FinderDocumentPreset: Codable, Equatable, Hashable, Identifiable {
    private static let textIdentifier = UUID(uuidString: "1A7E2BF4-791D-4D68-9A93-7517A5B11B5E")!
    private static let markdownIdentifier = UUID(uuidString: "A6B58F49-0D91-42A8-B3B8-5AC74DC297C1")!
    private static let richTextIdentifier = UUID(uuidString: "4D566157-0BE0-404D-936E-EAB89DE2F4F7")!
    private static let xmlIdentifier = UUID(uuidString: "1723D75D-D67C-41A7-82A5-2172C1EB124A")!
    private static let wordIdentifier = UUID(uuidString: "2F509B00-7188-4F32-96B2-DBA037DB2B09")!
    private static let excelIdentifier = UUID(uuidString: "32BC7537-511A-4C87-A9DE-5EC92DCDB70E")!
    private static let powerPointIdentifier = UUID(uuidString: "20F9B8A5-9E83-4444-83D2-A06DE1AA61D5")!
    private static let wpsWriterIdentifier = UUID(uuidString: "8C39C4C2-9577-47D3-92DE-78449FCD9F7D")!
    private static let wpsSpreadsheetIdentifier = UUID(uuidString: "DF1FFB25-5280-4431-B12F-1E4C86DDD8C7")!
    private static let wpsPresentationIdentifier = UUID(uuidString: "ED32FAE4-2B7F-46D3-9032-87B41D41770C")!
    private static let pagesIdentifier = UUID(uuidString: "9F40975F-475B-4736-A9C4-9462339315B8")!
    private static let numbersIdentifier = UUID(uuidString: "C117C187-2B10-497F-A778-B2DE55334175")!
    private static let keynoteIdentifier = UUID(uuidString: "9D567225-D109-477B-B70E-1966043C557E")!
    private static let illustratorIdentifier = UUID(uuidString: "483BEADE-E660-4093-8A6A-9F660F049787")!
    private static let photoshopIdentifier = UUID(uuidString: "E033E937-3121-4AC5-B1DF-DFC4622E7EEE")!

    let id: UUID
    var displayName: String
    var fileExtension: String
    var isEnabled: Bool

    init?(
        id: UUID = UUID(),
        displayName: String,
        fileExtension: String,
        isEnabled: Bool = true
    ) {
        let normalizedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalizedExtension = Self.normalizedFileExtension(fileExtension),
              !normalizedName.isEmpty
        else {
            return nil
        }

        self.id = id
        self.displayName = normalizedName
        self.fileExtension = normalizedExtension
        self.isEnabled = isEnabled
    }

    static let defaultPresets: [FinderDocumentPreset] = [
        FinderDocumentPreset(
            id: textIdentifier,
            displayName: "Text",
            fileExtension: "txt",
            isEnabled: true
        )!,
        FinderDocumentPreset(
            id: markdownIdentifier,
            displayName: "Markdown",
            fileExtension: "md",
            isEnabled: true
        )!,
        FinderDocumentPreset(
            id: richTextIdentifier,
            displayName: "Rich Text",
            fileExtension: "rtf",
            isEnabled: false
        )!,
        FinderDocumentPreset(
            id: xmlIdentifier,
            displayName: "XML",
            fileExtension: "xml",
            isEnabled: false
        )!,
        FinderDocumentPreset(
            id: wordIdentifier,
            displayName: "Word",
            fileExtension: "docx",
            isEnabled: false
        )!,
        FinderDocumentPreset(
            id: excelIdentifier,
            displayName: "Excel",
            fileExtension: "xlsx",
            isEnabled: false
        )!,
        FinderDocumentPreset(
            id: powerPointIdentifier,
            displayName: "PowerPoint",
            fileExtension: "pptx",
            isEnabled: false
        )!,
        FinderDocumentPreset(
            id: wpsWriterIdentifier,
            displayName: "WPS Writer",
            fileExtension: "wps",
            isEnabled: false
        )!,
        FinderDocumentPreset(
            id: wpsSpreadsheetIdentifier,
            displayName: "WPS Spreadsheet",
            fileExtension: "et",
            isEnabled: false
        )!,
        FinderDocumentPreset(
            id: wpsPresentationIdentifier,
            displayName: "WPS Presentation",
            fileExtension: "dps",
            isEnabled: false
        )!,
        FinderDocumentPreset(
            id: pagesIdentifier,
            displayName: "Pages",
            fileExtension: "pages",
            isEnabled: false
        )!,
        FinderDocumentPreset(
            id: numbersIdentifier,
            displayName: "Numbers",
            fileExtension: "numbers",
            isEnabled: false
        )!,
        FinderDocumentPreset(
            id: keynoteIdentifier,
            displayName: "Keynote",
            fileExtension: "key",
            isEnabled: false
        )!,
        FinderDocumentPreset(
            id: illustratorIdentifier,
            displayName: "Illustrator",
            fileExtension: "ai",
            isEnabled: false
        )!,
        FinderDocumentPreset(
            id: photoshopIdentifier,
            displayName: "Photoshop",
            fileExtension: "psd",
            isEnabled: false
        )!
    ]

    var isBuiltIn: Bool {
        Self.defaultPresets.contains { $0.id == id }
    }

    static func catalog(
        merging savedPresets: [FinderDocumentPreset],
        missingBuiltInsUseDefaults: Bool
    ) -> [FinderDocumentPreset] {
        var remaining = savedPresets
        var result: [FinderDocumentPreset] = []

        for builtIn in defaultPresets {
            let index = remaining.firstIndex {
                $0.id == builtIn.id
                    || $0.fileExtension.caseInsensitiveCompare(builtIn.fileExtension) == .orderedSame
            }
            if let index {
                let saved = remaining.remove(at: index)
                result.append(FinderDocumentPreset(
                    id: builtIn.id,
                    displayName: builtIn.displayName,
                    fileExtension: builtIn.fileExtension,
                    isEnabled: saved.isEnabled
                )!)
            } else {
                result.append(FinderDocumentPreset(
                    id: builtIn.id,
                    displayName: builtIn.displayName,
                    fileExtension: builtIn.fileExtension,
                    isEnabled: missingBuiltInsUseDefaults ? builtIn.isEnabled : false
                )!)
            }
        }

        for preset in remaining {
            guard let normalized = FinderDocumentPreset(
                id: preset.id,
                displayName: preset.displayName,
                fileExtension: preset.fileExtension,
                isEnabled: preset.isEnabled
            ), !result.contains(where: {
                $0.fileExtension.caseInsensitiveCompare(normalized.fileExtension) == .orderedSame
            }) else {
                continue
            }
            result.append(normalized)
        }

        return result
    }

    static func normalizedFileExtension(_ value: String) -> String? {
        var candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while candidate.hasPrefix(".") {
            candidate.removeFirst()
        }
        candidate = candidate.lowercased()

        guard !candidate.isEmpty,
              candidate.count <= 24,
              candidate.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.contains($0)
                      || $0 == UnicodeScalar("-")
                      || $0 == UnicodeScalar("_")
              })
        else {
            return nil
        }
        return candidate
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case fileExtension
        case isEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(UUID.self, forKey: .id)
        let displayName = try container.decode(String.self, forKey: .displayName)
        let fileExtension = try container.decode(String.self, forKey: .fileExtension)
        let isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true

        guard let preset = FinderDocumentPreset(
            id: id,
            displayName: displayName,
            fileExtension: fileExtension,
            isEnabled: isEnabled
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .fileExtension,
                in: container,
                debugDescription: "Invalid Finder document preset"
            )
        }
        self = preset
    }
}

struct FinderMenuPreferences: Codable, Equatable {
    var isEnabled: Bool
    var languageIdentifier: String
    var groupsLaunchShortcuts: Bool
    var launchShortcuts: [FinderLaunchShortcut]
    var documentPresets: [FinderDocumentPreset]
    var observationRootPaths: [String]

    init(
        isEnabled: Bool = false,
        languageIdentifier: String = "system",
        groupsLaunchShortcuts: Bool = true,
        launchShortcuts: [FinderLaunchShortcut] = FinderLaunchShortcut.defaultShortcuts,
        documentPresets: [FinderDocumentPreset] = FinderDocumentPreset.defaultPresets,
        observationRootPaths: [String] = []
    ) {
        self.isEnabled = isEnabled
        self.languageIdentifier = languageIdentifier
        self.groupsLaunchShortcuts = groupsLaunchShortcuts
        self.launchShortcuts = FinderLaunchShortcut.catalog(
            merging: launchShortcuts,
            missingBuiltInsUseDefaults: true
        )
        self.documentPresets = documentPresets
        self.observationRootPaths = observationRootPaths
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled
        case languageIdentifier
        case groupsLaunchShortcuts
        case launchShortcuts
        case documentPresets
        case observationRootPaths
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        languageIdentifier = try container.decodeIfPresent(
            String.self,
            forKey: .languageIdentifier
        ) ?? "system"
        groupsLaunchShortcuts = try container.decodeIfPresent(
            Bool.self,
            forKey: .groupsLaunchShortcuts
        ) ?? true
        if let savedShortcuts = try container.decodeIfPresent(
            [FinderLaunchShortcut].self,
            forKey: .launchShortcuts
        ) {
            launchShortcuts = FinderLaunchShortcut.catalog(
                merging: savedShortcuts,
                missingBuiltInsUseDefaults: false
            )
        } else {
            launchShortcuts = FinderLaunchShortcut.defaultShortcuts
        }
        if let savedPresets = try container.decodeIfPresent(
            [FinderDocumentPreset].self,
            forKey: .documentPresets
        ) {
            documentPresets = FinderDocumentPreset.catalog(
                merging: savedPresets,
                missingBuiltInsUseDefaults: false
            )
        } else {
            documentPresets = FinderDocumentPreset.defaultPresets
        }
        observationRootPaths = try container.decodeIfPresent(
            [String].self,
            forKey: .observationRootPaths
        ) ?? []
    }
}

enum FinderObservationRoots {
    static func registeredURLs(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        authorizedDirectoryPaths: [String] = []
    ) -> Set<URL> {
        // Finder routes the desktop layer through the filesystem root on some systems.
        // Monitoring it does not grant the sandbox additional file access.
        let standardDirectories = [
            URL(fileURLWithPath: "/", isDirectory: true),
            desktopURL(homeDirectory: homeDirectory),
            homeDirectory.appendingPathComponent("Documents", isDirectory: true),
            homeDirectory.appendingPathComponent("Downloads", isDirectory: true),
            cloudDriveURL(
                homeDirectory: homeDirectory,
                childName: "Desktop"
            ),
            cloudDriveURL(
                homeDirectory: homeDirectory,
                childName: "Documents"
            )
        ]
        let authorizedDirectories = authorizedDirectoryPaths.map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }

        return Set((standardDirectories + authorizedDirectories).flatMap(canonicalURLs(for:)))
    }

    static func folderURL(
        targetedURL: URL?,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        targetedURL ?? desktopURL(homeDirectory: homeDirectory)
    }

    static func desktopURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory.appendingPathComponent("Desktop", isDirectory: true)
    }

    private static func cloudDriveURL(
        homeDirectory: URL,
        childName: String
    ) -> URL {
        homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Mobile Documents", isDirectory: true)
            .appendingPathComponent("com~apple~CloudDocs", isDirectory: true)
            .appendingPathComponent(childName, isDirectory: true)
    }

    private static func canonicalURLs(for url: URL) -> [URL] {
        let standardized = url.standardizedFileURL
        guard FileManager.default.fileExists(atPath: standardized.path) else {
            return [standardized]
        }
        let resolved = standardized.resolvingSymlinksInPath()
        return standardized == resolved ? [standardized] : [standardized, resolved]
    }
}

final class FinderMenuPreferencesStore {
    static let didChangeNotification = Notification.Name(
        "com.quanzhankeji.OmniDock.finder-menu-preferences-changed"
    )

    static var appGroupIdentifier: String? {
        Bundle.main.object(forInfoDictionaryKey: "OmniDockAppGroupIdentifier") as? String
    }

    private enum Key {
        static let isEnabled = "finderExtensionEnabled"
        static let languageIdentifier = "finderExtensionLanguage"
        static let groupsLaunchShortcuts = "finderExtensionGroupsLaunchShortcuts"
        static let launchShortcuts = "finderExtensionLaunchShortcuts"
        static let documentPresets = "finderExtensionDocumentPresets"
        static let observationRootPaths = "finderExtensionObservationRootPaths"
        static let fileName = "FinderExtensionSettings.json"
    }

    private let defaultsProvider: () -> UserDefaults?
    private let containerProvider: () -> URL?

    convenience init() {
        self.init(
            containerProvider: {
                guard let identifier = Self.appGroupIdentifier else {
                    return nil
                }
                return FileManager.default.containerURL(
                    forSecurityApplicationGroupIdentifier: identifier
                )
            }
        )
    }

    init(
        suiteName: String? = FinderMenuPreferencesStore.appGroupIdentifier,
        defaultsProvider: @escaping () -> UserDefaults? = { nil },
        containerProvider: (() -> URL?)? = nil
    ) {
        self.defaultsProvider = defaultsProvider
        self.containerProvider = containerProvider ?? {
            guard let suiteName else {
                return nil
            }
            return FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: suiteName
            )
        }
    }

    func snapshot() -> FinderMenuPreferences {
        if let defaults = defaultsProvider() {
            return FinderMenuPreferences(
                isEnabled: defaults.bool(forKey: Key.isEnabled),
                languageIdentifier: defaults.string(forKey: Key.languageIdentifier) ?? "system",
                groupsLaunchShortcuts: defaults.object(
                    forKey: Key.groupsLaunchShortcuts
                ) as? Bool ?? true,
                launchShortcuts: decoded(
                    [FinderLaunchShortcut].self,
                    from: defaults.data(forKey: Key.launchShortcuts)
                ) ?? [],
                documentPresets: decoded(
                    [FinderDocumentPreset].self,
                    from: defaults.data(forKey: Key.documentPresets)
                ) ?? FinderDocumentPreset.defaultPresets,
                observationRootPaths: decoded(
                    [String].self,
                    from: defaults.data(forKey: Key.observationRootPaths)
                ) ?? []
            )
        }

        guard let url = preferencesFileURL(),
              let data = try? Data(contentsOf: url),
              let preferences = try? JSONDecoder().decode(FinderMenuPreferences.self, from: data)
        else {
            return FinderMenuPreferences()
        }
        return preferences
    }

    @discardableResult
    func update(_ preferences: FinderMenuPreferences) -> Bool {
        guard snapshot() != preferences else {
            return false
        }

        if let defaults = defaultsProvider() {
            defaults.set(preferences.isEnabled, forKey: Key.isEnabled)
            defaults.set(preferences.languageIdentifier, forKey: Key.languageIdentifier)
            defaults.set(preferences.groupsLaunchShortcuts, forKey: Key.groupsLaunchShortcuts)
            defaults.set(encoded(preferences.launchShortcuts), forKey: Key.launchShortcuts)
            defaults.set(encoded(preferences.documentPresets), forKey: Key.documentPresets)
            defaults.set(
                encoded(preferences.observationRootPaths),
                forKey: Key.observationRootPaths
            )
        } else if let url = preferencesFileURL(),
                  let data = try? JSONEncoder().encode(preferences) {
            try? data.write(to: url, options: .atomic)
        }
        DistributedNotificationCenter.default().postNotificationName(
            Self.didChangeNotification,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        return true
    }

    func updateObservationRootPaths(_ paths: [String]) {
        var preferences = snapshot()
        preferences.observationRootPaths = Array(Set(paths)).sorted()
        update(preferences)
    }

    private func preferencesFileURL() -> URL? {
        containerProvider()?.appendingPathComponent(Key.fileName, isDirectory: false)
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
}
