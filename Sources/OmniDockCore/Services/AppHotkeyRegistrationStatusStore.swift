import Foundation

@MainActor
public final class AppHotkeyRegistrationStatusStore {
    public static let changedNotification = Notification.Name("OmniDockHotkeyRegistrationStatusChanged")

    private var warnings: [UUID: String] = [:]

    public init() {}

    public func warning(for id: UUID) -> String? {
        warnings[id]
    }

    public func replaceWarnings(_ newWarnings: [UUID: String]) {
        guard warnings != newWarnings else {
            return
        }
        warnings = newWarnings
        NotificationCenter.default.post(name: Self.changedNotification, object: self)
    }

    public func clearWarning(for id: UUID) {
        guard warnings[id] != nil else {
            return
        }
        warnings[id] = nil
        NotificationCenter.default.post(name: Self.changedNotification, object: self)
    }

    public func clear() {
        replaceWarnings([:])
    }
}
