import AppKit

public enum AppAppearance: String, CaseIterable, Codable, Equatable {
    case system
    case light
    case dark

    public enum Resolved: Equatable {
        case light
        case dark
    }

    public var forcedNSAppearance: NSAppearance? {
        switch self {
        case .system:
            nil
        case .light:
            NSAppearance(named: .aqua)
        case .dark:
            NSAppearance(named: .darkAqua)
        }
    }

    public func resolved(for effectiveAppearance: NSAppearance? = nil) -> Resolved {
        switch self {
        case .light:
            return .light
        case .dark:
            return .dark
        case .system:
            let match = effectiveAppearance?.bestMatch(from: [.aqua, .darkAqua])
            return match == .darkAqua ? .dark : .light
        }
    }
}
