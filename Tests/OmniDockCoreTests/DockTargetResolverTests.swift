import CoreGraphics
import XCTest
@testable import OmniDockCore

final class DockTargetResolverTests: XCTestCase {
    func testInteractionInventoriesAreSendableValues() {
        requireSendable(DockScreenInventoryItem.self)
        requireSendable(DockScreenInventory.self)
        requireSendable(DockRunningApplicationInventoryItem.self)
        requireSendable(DockApplicationInventory.self)
        requireSendable(DockInteractionSystemInventory.self)
    }

    func testScreenInventoryConvertsEventTapFrameWithoutAppKitObjects() throws {
        let inventory = DockScreenInventory(
            screens: [
                DockScreenInventoryItem(
                    displayIdentifier: 1,
                    appKitFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
                    eventTapFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900)
                )
            ],
            mainAppKitFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900)
        )

        let converted = try XCTUnwrap(inventory.appKitFrame(
            fromEventTapFrame: CGRect(x: 100, y: 800, width: 40, height: 50)
        ))

        XCTAssertEqual(converted, CGRect(x: 100, y: 50, width: 40, height: 50))
        XCTAssertEqual(
            inventory.accessibilityCandidatePoints(
                fromAppKitPoint: CGPoint(x: 100, y: 50)
            ),
            [CGPoint(x: 100, y: 50), CGPoint(x: 100, y: 850)]
        )
    }

    func testScreenInventoryConvertsTopLeftGlobalFramesAcrossVerticalDisplays() throws {
        let inventory = DockScreenInventory(
            screens: [
                DockScreenInventoryItem(
                    displayIdentifier: 1,
                    appKitFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900),
                    eventTapFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900)
                ),
                DockScreenInventoryItem(
                    displayIdentifier: 2,
                    appKitFrame: CGRect(x: 0, y: 900, width: 1_440, height: 900),
                    eventTapFrame: CGRect(x: 0, y: -900, width: 1_440, height: 900)
                ),
                DockScreenInventoryItem(
                    displayIdentifier: 3,
                    appKitFrame: CGRect(x: 0, y: -900, width: 1_440, height: 900),
                    eventTapFrame: CGRect(x: 0, y: 900, width: 1_440, height: 900)
                )
            ],
            mainAppKitFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900)
        )

        let upper = try XCTUnwrap(inventory.appKitFrame(
            fromEventTapFrame: CGRect(x: 100, y: -800, width: 40, height: 50)
        ))
        let lower = try XCTUnwrap(inventory.appKitFrame(
            fromEventTapFrame: CGRect(x: 100, y: 1_000, width: 40, height: 50)
        ))

        XCTAssertEqual(upper, CGRect(x: 100, y: 1_650, width: 40, height: 50))
        XCTAssertEqual(lower, CGRect(x: 100, y: -150, width: 40, height: 50))
    }

    func testMatchingApplicationUsesDockItemTitle() {
        let app = DockRunningApplicationCandidate(
            processIdentifier: 101,
            bundleIdentifier: "com.example.SampleEditor",
            localizedName: "Sample Editor"
        )

        let match = DockTargetResolver.matchingTarget(
            for: ["Sample Editor"],
            runningApps: [app]
        )?.app

        XCTAssertEqual(match, app)
    }

    func testMatchingApplicationDoesNotMatchInsideLongerWord() {
        let shortNameApp = DockRunningApplicationCandidate(
            processIdentifier: 101,
            bundleIdentifier: "com.example.Code",
            localizedName: "Code"
        )
        let fullNameApp = DockRunningApplicationCandidate(
            processIdentifier: 202,
            bundleIdentifier: "com.example.CodecPro",
            localizedName: "Codec Pro"
        )

        let match = DockTargetResolver.matchingTarget(
            for: ["Codec Pro"],
            runningApps: [shortNameApp, fullNameApp]
        )?.app

        XCTAssertEqual(match, fullNameApp)
    }

    func testMatchingApplicationUsesTokenSequenceInsideDockWrapperTitle() {
        let app = DockRunningApplicationCandidate(
            processIdentifier: 101,
            bundleIdentifier: "com.example.SampleEditor",
            localizedName: "Sample Editor"
        )

        let match = DockTargetResolver.matchingTarget(
            for: ["Dock Extra (Sample Editor.app)"],
            runningApps: [app]
        )?.app

        XCTAssertEqual(match, app)
    }

    func testFallbackApplicationUsesDockItemBounds() {
        let app = DockRunningApplicationCandidate(
            processIdentifier: 101,
            bundleIdentifier: "com.example.SampleEditor",
            localizedName: "Sample Editor"
        )
        let item = DockItemSnapshot(
            texts: ["Sample Editor"],
            frame: CGRect(x: 100, y: 200, width: 60, height: 70)
        )

        let match = DockTargetResolver.fallbackApplication(
            at: CGPoint(x: 130, y: 230),
            dockItems: [item],
            runningApps: [app]
        )

        XCTAssertEqual(match?.item, item)
        XCTAssertEqual(match?.resolution.app, app)
    }

    func testFallbackApplicationDoesNotClaimNonRunningApp() {
        let item = DockItemSnapshot(
            texts: ["Sample Editor"],
            frame: CGRect(x: 100, y: 200, width: 60, height: 70)
        )

        let match = DockTargetResolver.fallbackApplication(
            at: CGPoint(x: 130, y: 230),
            dockItems: [item],
            runningApps: [
                DockRunningApplicationCandidate(
                    processIdentifier: 202,
                    bundleIdentifier: "com.apple.TextEdit",
                    localizedName: "TextEdit"
                )
            ]
        )

        XCTAssertNil(match)
    }

    func testRelatedProcessNameDoesNotMatchShorterDockTitle() {
        let relatedProcess = DockRunningApplicationCandidate(
            processIdentifier: 303,
            bundleIdentifier: "com.example.projectwindow",
            localizedName: "Project Window Background Process"
        )

        let match = DockTargetResolver.matchingTarget(
            for: ["Project Window"],
            runningApps: [relatedProcess]
        )

        XCTAssertNil(match)
    }

    func testDirectApplicationMatchWinsOverLongerRelatedProcessName() {
        let app = DockRunningApplicationCandidate(
            processIdentifier: 101,
            bundleIdentifier: "com.example.hostapp",
            localizedName: "Host App"
        )
        let relatedProcess = DockRunningApplicationCandidate(
            processIdentifier: 202,
            bundleIdentifier: "com.example.hostapp.renderer",
            localizedName: "Host App Renderer"
        )

        let match = DockTargetResolver.matchingTarget(
            for: ["Host App"],
            runningApps: [app, relatedProcess]
        )

        XCTAssertEqual(match?.app, app)
    }

    func testSingleTokenDockTitleDoesNotMatchLongerRelatedProcessName() {
        let relatedProcess = DockRunningApplicationCandidate(
            processIdentifier: 303,
            bundleIdentifier: "com.example.note.renderer",
            localizedName: "Note Renderer"
        )

        let match = DockTargetResolver.matchingTarget(
            for: ["Note"],
            runningApps: [relatedProcess]
        )

        XCTAssertNil(match)
    }

    func testEmptyApplicationNameDoesNotMatchEveryDockTitle() {
        let app = DockRunningApplicationCandidate(
            processIdentifier: 101,
            bundleIdentifier: nil,
            localizedName: nil
        )

        let match = DockTargetResolver.matchingTarget(
            for: ["Sample Editor"],
            runningApps: [app]
        )?.app

        XCTAssertNil(match)
    }

    private func requireSendable<T: Sendable>(_ type: T.Type) {}
}
