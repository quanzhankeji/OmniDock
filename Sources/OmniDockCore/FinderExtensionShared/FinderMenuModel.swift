import Foundation

enum FinderMenuAction: Equatable {
    case createDocument(FinderDocumentPreset)
    case copyCurrentDirectoryPath
    case copySelectedPaths
    case showHiddenFiles
    case hideHiddenFiles
    case openSelection(FinderLaunchShortcut)

    func isAvailable(in location: FinderMenuLocation) -> Bool {
        switch self {
        case .createDocument, .copyCurrentDirectoryPath:
            return location == .folderBackground
        case .copySelectedPaths, .openSelection:
            return location == .selection
        case .showHiddenFiles, .hideHiddenFiles:
            return true
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
            let enabledPresets = preferences.documentPresets.filter(\.isEnabled)
            if !enabledPresets.isEmpty {
                entries.append(.documentSubmenu(
                    enabledPresets.map(FinderMenuAction.createDocument)
                ))
            }
            entries.append(contentsOf: hiddenFileEntries)
            return entries
        case .selection:
            guard !context.selectedURLs.isEmpty else {
                return []
            }

            let applicationActions = preferences.launchShortcuts
                .filter { shortcut in
                    guard shortcut.isEnabled else {
                        return false
                    }
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
            entries.append(contentsOf: hiddenFileEntries)
            return entries
        }
    }

    private static let hiddenFileEntries: [FinderMenuEntry] = [
        .action(.showHiddenFiles),
        .action(.hideHiddenFiles)
    ]
}

enum FinderMenuLabels {
    static func title(for action: FinderMenuAction, languageIdentifier: String) -> String {
        switch (action, usesChinese(languageIdentifier)) {
        case (.copyCurrentDirectoryPath, true), (.copySelectedPaths, true):
            return "复制路径"
        case (.copyCurrentDirectoryPath, false), (.copySelectedPaths, false):
            return "Copy Path"
        case (.showHiddenFiles, true):
            return "显示所有文件"
        case (.showHiddenFiles, false):
            return "Show All Files"
        case (.hideHiddenFiles, true):
            return "隐藏所有文件"
        case (.hideHiddenFiles, false):
            return "Hide Hidden Files"
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
