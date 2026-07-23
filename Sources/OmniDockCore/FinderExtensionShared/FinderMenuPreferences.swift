import Foundation

struct FinderMenuPreferences: Codable, Equatable {
    var isEnabled: Bool
    var languageIdentifier: String

    init(isEnabled: Bool = false, languageIdentifier: String = "system") {
        self.isEnabled = isEnabled
        self.languageIdentifier = languageIdentifier
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
                languageIdentifier: defaults.string(forKey: Key.languageIdentifier) ?? "system"
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
}
