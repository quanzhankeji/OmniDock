import Foundation

enum FinderMenuAction: String, Codable, CaseIterable {
    case createTextFile
    case createMarkdownFile
    case copyCurrentDirectoryPath
    case copySelectedPaths

    var menuTag: Int {
        switch self {
        case .createTextFile:
            return 1_001
        case .createMarkdownFile:
            return 1_002
        case .copyCurrentDirectoryPath:
            return 1_003
        case .copySelectedPaths:
            return 1_004
        }
    }

    init?(menuTag: Int) {
        guard let action = Self.allCases.first(where: { $0.menuTag == menuTag }) else {
            return nil
        }
        self = action
    }

    var documentKind: FinderDocumentKind? {
        switch self {
        case .createTextFile:
            return .text
        case .createMarkdownFile:
            return .markdown
        case .copyCurrentDirectoryPath, .copySelectedPaths:
            return nil
        }
    }

    var location: FinderMenuLocation {
        switch self {
        case .createTextFile, .createMarkdownFile, .copyCurrentDirectoryPath:
            return .folderBackground
        case .copySelectedPaths:
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

enum FinderMenuEntry: Equatable {
    case action(FinderMenuAction)
    case documentSubmenu([FinderMenuAction])
}

enum FinderMenuCatalog {
    static func entries(
        for context: FinderMenuContext,
        isEnabled: Bool = true
    ) -> [FinderMenuEntry] {
        guard isEnabled else {
            return []
        }

        switch context.location {
        case .folderBackground:
            guard context.currentDirectory != nil else {
                return []
            }
            return [
                .action(.copyCurrentDirectoryPath),
                .documentSubmenu([.createTextFile, .createMarkdownFile])
            ]
        case .selection:
            return context.selectedURLs.isEmpty ? [] : [.action(.copySelectedPaths)]
        }
    }
}

enum FinderMenuLabels {
    static func title(for action: FinderMenuAction, languageIdentifier: String) -> String {
        switch (action, usesChinese(languageIdentifier)) {
        case (.createTextFile, true):
            return "TXT 文件"
        case (.createMarkdownFile, true):
            return "Markdown 文件"
        case (.copyCurrentDirectoryPath, true), (.copySelectedPaths, true):
            return "复制路径"
        case (.createTextFile, false):
            return "Text File"
        case (.createMarkdownFile, false):
            return "Markdown File"
        case (.copyCurrentDirectoryPath, false), (.copySelectedPaths, false):
            return "Copy Path"
        }
    }

    static func documentSubmenuTitle(languageIdentifier: String) -> String {
        usesChinese(languageIdentifier) ? "新建文件" : "New File"
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
