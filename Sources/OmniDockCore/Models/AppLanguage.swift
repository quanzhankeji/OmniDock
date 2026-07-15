import Foundation

public enum AppLanguage: String, CaseIterable, Codable, Equatable {
    case system
    case zhHans
    case en

    public enum Resolved: String, CaseIterable {
        case zhHans = "zh-Hans"
        case en
    }

    public func resolved(preferredLanguages: [String] = Locale.preferredLanguages) -> Resolved {
        switch self {
        case .zhHans:
            return .zhHans
        case .en:
            return .en
        case .system:
            let firstLanguage = preferredLanguages.first?.lowercased() ?? ""
            return firstLanguage.hasPrefix("zh") ? .zhHans : .en
        }
    }
}
