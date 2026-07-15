import AppKit
import XCTest
@testable import OmniDockCore

@MainActor
final class ApplicationPresentationCoordinatorTests: XCTestCase {
    func testFirstVisibleSurfaceSwitchesToRegularAndActivates() {
        let harness = PresentationCoordinatorHarness()
        let coordinator = harness.coordinator

        coordinator.present(.settings)

        XCTAssertEqual(harness.policies, [.regular])
        XCTAssertEqual(harness.activationCount, 1)
        XCTAssertEqual(coordinator.activeSurfaceCount, 1)
    }

    func testPresentingSameSurfaceTwiceDoesNotDoubleCountOrSwitchAgain() {
        let harness = PresentationCoordinatorHarness()
        let coordinator = harness.coordinator

        coordinator.present(.settings)
        coordinator.present(.settings)

        XCTAssertEqual(harness.policies, [.regular])
        XCTAssertEqual(harness.activationCount, 2)
        XCTAssertEqual(coordinator.activeSurfaceCount, 1)
    }

    func testAccessoryPresentationWaitsUntilLastSurfaceCloses() {
        let harness = PresentationCoordinatorHarness()
        let coordinator = harness.coordinator

        coordinator.present(.settings)
        coordinator.present(.permissionOnboarding)
        coordinator.dismiss(.settings)

        XCTAssertEqual(coordinator.activeSurfaceCount, 1)
        XCTAssertTrue(harness.deferredActions.isEmpty)

        coordinator.dismiss(.permissionOnboarding)

        XCTAssertEqual(coordinator.activeSurfaceCount, 0)
        XCTAssertEqual(harness.deferredActions.count, 1)
        XCTAssertEqual(harness.policies, [.regular])

        harness.deferredActions[0]()

        XCTAssertEqual(harness.policies, [.regular, .accessory])
    }

    func testDuplicateDismissIsIgnored() {
        let harness = PresentationCoordinatorHarness()
        let coordinator = harness.coordinator

        coordinator.dismiss(.settings)
        coordinator.present(.settings)
        coordinator.dismiss(.settings)
        coordinator.dismiss(.settings)

        XCTAssertEqual(harness.deferredActions.count, 1)
        XCTAssertEqual(coordinator.activeSurfaceCount, 0)
    }

    func testReopeningBeforeDeferredDismissCancelsAccessoryTransition() {
        let harness = PresentationCoordinatorHarness()
        let coordinator = harness.coordinator

        coordinator.present(.settings)
        coordinator.dismiss(.settings)
        coordinator.present(.permissionOnboarding)
        harness.deferredActions[0]()

        XCTAssertEqual(harness.policies, [.regular])
        XCTAssertEqual(coordinator.activeSurfaceCount, 1)
    }

    func testFailedPolicyTransitionIsNotRetriedForSamePresentationCycle() {
        let harness = PresentationCoordinatorHarness(policyResult: false)
        let coordinator = harness.coordinator

        coordinator.present(.settings)
        coordinator.present(.settings)

        XCTAssertEqual(harness.policies, [.regular])
        XCTAssertEqual(harness.activationCount, 2)
    }
}

@MainActor
private final class PresentationCoordinatorHarness {
    var policies: [NSApplication.ActivationPolicy] = []
    var activationCount = 0
    var deferredActions: [ApplicationPresentationCoordinator.DeferredAction] = []

    private let policyResult: Bool

    init(policyResult: Bool = true) {
        self.policyResult = policyResult
    }

    lazy var coordinator = ApplicationPresentationCoordinator(
        setActivationPolicy: { policy in
            self.policies.append(policy)
            return self.policyResult
        },
        activateApplication: {
            self.activationCount += 1
        },
        scheduleDeferred: { action in
            self.deferredActions.append(action)
        }
    )
}
