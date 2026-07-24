import Foundation

enum FinderMenuAction: Equatable {
    case createDocument(FinderDocumentPreset)
    case copyCurrentDirectoryPath
    case copySelectedPaths
    case openSelection(FinderLaunchShortcut)

    var location: FinderMenuLocation {
        switch self {
        case .createDocument, .copyCurrentDirectoryPath:
            return .folderBackground
        case .copySelectedPaths, .openSelection:
            return .selection
        }
    }
}

enum FinderMenuLocation: String, Codable, Equatable {
    case folderBackground
    case selection
}

struct FinderMenuContext: Equatable {
    let location: FinderMenuLocation
    let currentDirectory: URL?
    let selectedURLs: [URL]
}

struct FinderMenuCommandBinding: Equatable {
    let action: FinderMenuAction
    let context: FinderMenuContext
}

final class FinderMenuActionRegistry {
    private let capacity: Int
    private var nextToken = 1
    private var tokensInOrder: [Int] = []
    private var bindings: [Int: FinderMenuCommandBinding] = [:]

    init(capacity: Int = 256) {
        self.capacity = max(1, capacity)
    }

    func issueToken(for binding: FinderMenuCommandBinding) -> Int {
        let token = reserveToken()
        bindings[token] = binding
        tokensInOrder.append(token)

        while tokensInOrder.count > capacity {
            let expiredToken = tokensInOrder.removeFirst()
            bindings.removeValue(forKey: expiredToken)
        }

        return token
    }

    func consume(token: Int) -> FinderMenuCommandBinding? {
        guard let binding = bindings.removeValue(forKey: token) else {
            return nil
        }
        tokensInOrder.removeAll { $0 == token }
        return binding
    }

    private func reserveToken() -> Int {
        while bindings[nextToken] != nil {
            advanceToken()
        }
        let token = nextToken
        advanceToken()
        return token
    }

    private func advanceToken() {
        nextToken = nextToken == Int.max ? 1 : nextToken + 1
    }
}

enum FinderMenuEntry: Equatable {
    case action(FinderMenuAction)
    case documentSubmenu([FinderMenuAction])
    case applicationSubmenu([FinderMenuAction])
}

enum FinderMenuCatalog {
    static func entries(
        for context: FinderMenuContext,
        preferences: FinderMenuPreferences
    ) -> [FinderMenuEntry] {
        guard preferences.isEnabled else {
            return []
        }

        switch context.location {
        case .folderBackground:
            guard context.currentDirectory != nil else {
                return []
            }
            var entries: [FinderMenuEntry] = [.action(.copyCurrentDirectoryPath)]
            if !preferences.documentPresets.isEmpty {
                entries.append(.documentSubmenu(
                    preferences.documentPresets.map(FinderMenuAction.createDocument)
                ))
            }
            return entries
        case .selection:
            guard !context.selectedURLs.isEmpty else {
                return []
            }

            let applicationActions = preferences.launchShortcuts
                .filter { shortcut in
                    guard let url = shortcut.bundleURL else {
                        return false
                    }
                    return FileManager.default.fileExists(atPath: url.path)
                }
                .map(FinderMenuAction.openSelection)

            var entries: [FinderMenuEntry] = [.action(.copySelectedPaths)]
            if preferences.groupsLaunchShortcuts, !applicationActions.isEmpty {
                entries.append(.applicationSubmenu(applicationActions))
            } else {
                entries.append(contentsOf: applicationActions.map(FinderMenuEntry.action))
            }
            return entries
        }
    }
}

enum FinderMenuLabels {
    static func title(for action: FinderMenuAction, languageIdentifier: String) -> String {
        switch (action, usesChinese(languageIdentifier)) {
        case (.copyCurrentDirectoryPath, true), (.copySelectedPaths, true):
            return "复制路径"
        case (.copyCurrentDirectoryPath, false), (.copySelectedPaths, false):
            return "Copy Path"
        case let (.createDocument(preset), true):
            switch preset.fileExtension {
            case "txt":
                return "TXT 文件"
            case "md":
                return "Markdown 文件"
            default:
                return preset.displayName
            }
        case let (.createDocument(preset), false):
            return preset.fileExtension == "txt"
                ? "Text File"
                : preset.displayName
        case let (.openSelection(shortcut), _):
            return shortcut.displayName
        }
    }

    static func documentSubmenuTitle(languageIdentifier: String) -> String {
        usesChinese(languageIdentifier) ? "新建文件" : "New File"
    }

    static func applicationSubmenuTitle(languageIdentifier: String) -> String {
        usesChinese(languageIdentifier) ? "打开方式" : "Open With"
    }

    private static func usesChinese(_ languageIdentifier: String) -> Bool {
        languageIdentifier == "zhHans" || (
            languageIdentifier == "system"
                && Locale.preferredLanguages.contains { $0.lowercased().hasPrefix("zh") }
        )
    }
}

enum FinderPathList {
    static func text(for urls: [URL]) -> String {
        urls.map(\.path).joined(separator: "\n")
    }
}
