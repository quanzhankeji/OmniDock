import Foundation
import ServiceManagement

enum LaunchAtLoginStatus: Equatable {
    case unsupported
    case disabled
    case enabled
    case requiresApproval
    case unavailable
}

enum LaunchAtLoginServiceError: Error, Equatable {
    case unsupported
    case requiresApproval
    case unavailable
    case operationFailed(String)
}

final class LaunchAtLoginService {
    private let statusProvider: () -> LaunchAtLoginStatus
    private let registerService: () throws -> Void
    private let unregisterService: () throws -> Void
    private let openSystemSettingsAction: () -> Void

    init(
        statusProvider: @escaping () -> LaunchAtLoginStatus = LaunchAtLoginService.systemStatus,
        registerService: @escaping () throws -> Void = LaunchAtLoginService.systemRegister,
        unregisterService: @escaping () throws -> Void = LaunchAtLoginService.systemUnregister,
        openSystemSettings: @escaping () -> Void = LaunchAtLoginService.openSystemSettings
    ) {
        self.statusProvider = statusProvider
        self.registerService = registerService
        self.unregisterService = unregisterService
        self.openSystemSettingsAction = openSystemSettings
    }

    var status: LaunchAtLoginStatus {
        statusProvider()
    }

    func setEnabled(_ isEnabled: Bool) throws {
        let currentStatus = status
        switch currentStatus {
        case .unsupported:
            throw LaunchAtLoginServiceError.unsupported
        case .unavailable:
            throw LaunchAtLoginServiceError.unavailable
        case .enabled where isEnabled:
            return
        case .disabled where !isEnabled:
            return
        default:
            break
        }

        do {
            if isEnabled {
                try registerService()
            } else {
                try unregisterService()
            }
        } catch {
            if status == .requiresApproval {
                throw LaunchAtLoginServiceError.requiresApproval
            }
            if let serviceError = error as? LaunchAtLoginServiceError {
                throw serviceError
            }
            throw LaunchAtLoginServiceError.operationFailed(error.localizedDescription)
        }

        if isEnabled && status == .requiresApproval {
            throw LaunchAtLoginServiceError.requiresApproval
        }
    }

    func openSystemSettings() {
        openSystemSettingsAction()
    }

    private static func systemStatus() -> LaunchAtLoginStatus {
        guard #available(macOS 13.0, *) else {
            return .unsupported
        }

        switch SMAppService.mainApp.status {
        case .notRegistered:
            return .disabled
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .unavailable
        @unknown default:
            return .unavailable
        }
    }

    private static func systemRegister() throws {
        guard #available(macOS 13.0, *) else {
            throw LaunchAtLoginServiceError.unsupported
        }
        try SMAppService.mainApp.register()
    }

    private static func systemUnregister() throws {
        guard #available(macOS 13.0, *) else {
            throw LaunchAtLoginServiceError.unsupported
        }
        try SMAppService.mainApp.unregister()
    }

    private static func openSystemSettings() {
        guard #available(macOS 13.0, *) else {
            return
        }
        SMAppService.openSystemSettingsLoginItems()
    }
}
