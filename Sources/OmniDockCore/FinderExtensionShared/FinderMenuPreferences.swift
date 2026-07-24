import Foundation

struct FinderLaunchShortcut: Codable, Equatable, Hashable, Identifiable {
    let id: UUID
    var displayName: String
    var bundleURLString: String
    var bundleIdentifier: String?

    init(
        id: UUID = UUID(),
        displayName: String,
        bundleURLString: String,
        bundleIdentifier: String?
    ) {
        self.id = id
        self.displayName = displayName
        self.bundleURLString = bundleURLString
        self.bundleIdentifier = bundleIdentifier
    }

    var bundleURL: URL? {
        URL(string: bundleURLString)
    }
}

struct FinderDocumentPreset: Codable, Equatable, Hashable, Identifiable {
    private static let textIdentifier = UUID(uuidString: "1A7E2BF4-791D-4D68-9A93-7517A5B11B5E")!
    private static let markdownIdentifier = UUID(uuidString: "A6B58F49-0D91-42A8-B3B8-5AC74DC297C1")!

    let id: UUID
    var displayName: String
    var fileExtension: String

    init?(id: UUID = UUID(), displayName: String, fileExtension: String) {
        let normalizedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalizedExtension = Self.normalizedFileExtension(fileExtension),
              !normalizedName.isEmpty
        else {
            return nil
        }

        self.id = id
        self.displayName = normalizedName
        self.fileExtension = normalizedExtension
    }

    static let defaultPresets: [FinderDocumentPreset] = [
        FinderDocumentPreset(
            id: textIdentifier,
            displayName: "Text",
            fileExtension: "txt"
        )!,
        FinderDocumentPreset(
            id: markdownIdentifier,
            displayName: "Markdown",
            fileExtension: "md"
        )!
    ]

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
}

struct FinderMenuPreferences: Codable, Equatable {
    var isEnabled: Bool
    var languageIdentifier: String
    var groupsLaunchShortcuts: Bool
    var launchShortcuts: [FinderLaunchShortcut]
    var documentPresets: [FinderDocumentPreset]

    init(
        isEnabled: Bool = false,
        languageIdentifier: String = "system",
        groupsLaunchShortcuts: Bool = true,
        launchShortcuts: [FinderLaunchShortcut] = [],
        documentPresets: [FinderDocumentPreset] = FinderDocumentPreset.defaultPresets
    ) {
        self.isEnabled = isEnabled
        self.languageIdentifier = languageIdentifier
        self.groupsLaunchShortcuts = groupsLaunchShortcuts
        self.launchShortcuts = launchShortcuts
        self.documentPresets = documentPresets
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled
        case languageIdentifier
        case groupsLaunchShortcuts
        case launchShortcuts
        case documentPresets
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
        launchShortcuts = try container.decodeIfPresent(
            [FinderLaunchShortcut].self,
            forKey: .launchShortcuts
        ) ?? []
        documentPresets = try container.decodeIfPresent(
            [FinderDocumentPreset].self,
            forKey: .documentPresets
        ) ?? FinderDocumentPreset.defaultPresets
    }
}

enum FinderObservationRoots {
    static func registeredURLs(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Set<URL> {
        [
            URL(fileURLWithPath: "/", isDirectory: true),
            desktopURL(homeDirectory: homeDirectory)
        ]
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
}

final class FinderMenuPreferencesStore {
    static var appGroupIdentifier: String? {
        Bundle.main.object(forInfoDictionaryKey: "OmniDockAppGroupIdentifier") as? String
    }

    private enum Key {
        static let isEnabled = "finderExtensionEnabled"
        static let languageIdentifier = "finderExtensionLanguage"
        static let groupsLaunchShortcuts = "finderExtensionGroupsLaunchShortcuts"
        static let launchShortcuts = "finderExtensionLaunchShortcuts"
        static let documentPresets = "finderExtensionDocumentPresets"
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
                ) ?? FinderDocumentPreset.defaultPresets
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

    func update(_ preferences: FinderMenuPreferences) {
        if let defaults = defaultsProvider() {
            defaults.set(preferences.isEnabled, forKey: Key.isEnabled)
            defaults.set(preferences.languageIdentifier, forKey: Key.languageIdentifier)
            defaults.set(preferences.groupsLaunchShortcuts, forKey: Key.groupsLaunchShortcuts)
            defaults.set(encoded(preferences.launchShortcuts), forKey: Key.launchShortcuts)
            defaults.set(encoded(preferences.documentPresets), forKey: Key.documentPresets)
            return
        }

        guard let url = preferencesFileURL(),
              let data = try? JSONEncoder().encode(preferences)
        else {
            return
        }
        try? data.write(to: url, options: .atomic)
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
