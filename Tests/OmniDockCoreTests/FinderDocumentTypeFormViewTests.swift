import AppKit
import XCTest
@testable import OmniDockCore

@MainActor
final class FinderDocumentTypeFormViewTests: XCTestCase {
    func testFieldsRemainEditableAndWideInsideAnAlertAccessoryView() {
        let form = FinderDocumentTypeFormView(
            nameLabel: "Name",
            fileExtensionLabel: "Extension"
        )

        form.layoutSubtreeIfNeeded()

        XCTAssertTrue(form.nameField.isEditable)
        XCTAssertTrue(form.nameField.isSelectable)
        XCTAssertTrue(form.fileExtensionField.isEditable)
        XCTAssertTrue(form.fileExtensionField.isSelectable)
        XCTAssertGreaterThanOrEqual(form.nameField.frame.width, 250)
        XCTAssertEqual(form.nameField.frame.width, form.fileExtensionField.frame.width)
    }

    func testTabOrderMovesFromNameToExtension() {
        let form = FinderDocumentTypeFormView(
            nameLabel: "名称",
            fileExtensionLabel: "扩展名"
        )

        XCTAssertTrue(form.nameField.nextKeyView === form.fileExtensionField)
    }
}
