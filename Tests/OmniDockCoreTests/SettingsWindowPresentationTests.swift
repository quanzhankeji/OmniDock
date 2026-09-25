import AppKit
import XCTest
@testable import OmniDockCore

final class HotkeyRowsSignatureTests: XCTestCase {
    private func binding(_ name: String) -> AppHotkeyBinding {
        AppHotkeyBinding(
            appName: name,
            bundleURLString: "file:///Applications/\(name).app",
            bundleIdentifier: "com.example.\(name)"
        )
    }

    func testSameBindingsAndWarningsCompareEqual() {
        let first = HotkeyRowsSignature(bindings: [binding("a")], warnings: [:])
        let second = HotkeyRowsSignature(bindings: [binding("a")], warnings: [:])
        XCTAssertEqual(first.bindings.count, second.bindings.count)
    }

    func testAddingABindingChangesTheSignature() {
        let before = HotkeyRowsSignature(bindings: [], warnings: [:])
        let after = HotkeyRowsSignature(bindings: [binding("a")], warnings: [:])
        XCTAssertNotEqual(before, after)
    }

    func testAWarningChangeAloneChangesTheSignature() {
        let one = binding("a")
        let before = HotkeyRowsSignature(bindings: [one], warnings: [:])
        let after = HotkeyRowsSignature(bindings: [one], warnings: [one.id: "clash"])
        XCTAssertNotEqual(before, after)
    }
}

@MainActor
final class FeaturePermissionStatusViewTests: XCTestCase {
    func testMissingPermissionAndMetadataOnlyProvideTheCorrectGrantAction() throws {
        _ = NSApplication.shared
        let view = FeaturePermissionStatusView()
        var requested: PermissionKind?
        view.onRequestPermission = { requested = $0 }
        let button = try XCTUnwrap(view.arrangedSubviews.compactMap { $0 as? NSButton }.first)
        view.update(.unavailable([.accessibility, .inputMonitoring]))
        XCTAssertFalse(view.isHidden)
        button.performClick(nil)
        XCTAssertEqual(requested, .accessibility)
        view.update(.metadataOnly)
        XCTAssertFalse(view.isHidden)
        button.performClick(nil)
        XCTAssertEqual(requested, .screenRecording)
    }

    func testDisabledAndAvailableFeaturesDoNotShowPermissionWarnings() {
        let view = FeaturePermissionStatusView()
        for state in [PermissionFeatureAvailability.disabled, .available] {
            view.update(state)
            XCTAssertTrue(view.isHidden)
            XCTAssertNil(view.permissionToRequest)
        }
    }
}
