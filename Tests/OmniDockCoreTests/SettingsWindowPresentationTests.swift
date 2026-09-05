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
