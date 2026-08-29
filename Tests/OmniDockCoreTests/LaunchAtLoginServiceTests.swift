import XCTest
@testable import OmniDockCore

final class LaunchAtLoginServiceTests: XCTestCase {
    func testEnablingRegistersTheMainApplication() throws {
        var status = LaunchAtLoginStatus.disabled
        var registrationCount = 0
        let service = LaunchAtLoginService(
            statusProvider: { status },
            registerService: {
                registrationCount += 1
                status = .enabled
            },
            unregisterService: {}
        )

        try service.setEnabled(true)

        XCTAssertEqual(registrationCount, 1)
        XCTAssertEqual(service.status, .enabled)
    }

    func testDisablingUnregistersTheMainApplication() throws {
        var status = LaunchAtLoginStatus.enabled
        var unregistrationCount = 0
        let service = LaunchAtLoginService(
            statusProvider: { status },
            registerService: {},
            unregisterService: {
                unregistrationCount += 1
                status = .disabled
            }
        )

        try service.setEnabled(false)

        XCTAssertEqual(unregistrationCount, 1)
        XCTAssertEqual(service.status, .disabled)
    }

    func testMatchingStateDoesNotRegisterAgain() throws {
        var registrationCount = 0
        let service = LaunchAtLoginService(
            statusProvider: { .enabled },
            registerService: { registrationCount += 1 },
            unregisterService: {}
        )

        try service.setEnabled(true)

        XCTAssertEqual(registrationCount, 0)
    }

    func testDeniedRegistrationReportsRequiredApproval() {
        var status = LaunchAtLoginStatus.disabled
        let service = LaunchAtLoginService(
            statusProvider: { status },
            registerService: {
                status = .requiresApproval
                throw TestError.denied
            },
            unregisterService: {}
        )

        XCTAssertThrowsError(try service.setEnabled(true)) { error in
            XCTAssertEqual(error as? LaunchAtLoginServiceError, .requiresApproval)
        }
    }

    func testUnsupportedSystemsDoNotAttemptRegistration() {
        var registrationCount = 0
        let service = LaunchAtLoginService(
            statusProvider: { .unsupported },
            registerService: { registrationCount += 1 },
            unregisterService: {}
        )

        XCTAssertThrowsError(try service.setEnabled(true)) { error in
            XCTAssertEqual(error as? LaunchAtLoginServiceError, .unsupported)
        }
        XCTAssertEqual(registrationCount, 0)
    }

    func testOpenSystemSettingsForwardsToTheSystemBackend() {
        var didOpenSettings = false
        let service = LaunchAtLoginService(
            statusProvider: { .requiresApproval },
            registerService: {},
            unregisterService: {},
            openSystemSettings: { didOpenSettings = true }
        )

        service.openSystemSettings()

        XCTAssertTrue(didOpenSettings)
    }

    private enum TestError: Error {
        case denied
    }
}
