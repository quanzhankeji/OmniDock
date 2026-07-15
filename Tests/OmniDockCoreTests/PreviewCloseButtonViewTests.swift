import AppKit
import XCTest
@testable import OmniDockCore

final class PreviewCloseButtonViewTests: XCTestCase {
    func testCloseButtonAcceptsFirstMouse() {
        let button = PreviewCloseButtonView(frame: CGRect(x: 0, y: 0, width: 13, height: 13))

        XCTAssertTrue(button.acceptsFirstMouse(for: nil))
    }

    func testMouseUpInsideInvokesCloseCallback() {
        let button = PreviewCloseButtonView(frame: CGRect(x: 0, y: 0, width: 13, height: 13))
        var closeCount = 0
        button.onClose = {
            closeCount += 1
        }

        button.mouseDown(with: mouseEvent(type: .leftMouseDown, location: CGPoint(x: 6, y: 6)))
        button.mouseUp(with: mouseEvent(type: .leftMouseUp, location: CGPoint(x: 6, y: 6)))

        XCTAssertEqual(closeCount, 1)
    }

    func testMouseUpOutsideDoesNotInvokeCloseCallback() {
        let button = PreviewCloseButtonView(frame: CGRect(x: 0, y: 0, width: 13, height: 13))
        var closeCount = 0
        button.onClose = {
            closeCount += 1
        }

        button.mouseDown(with: mouseEvent(type: .leftMouseDown, location: CGPoint(x: 6, y: 6)))
        button.mouseUp(with: mouseEvent(type: .leftMouseUp, location: CGPoint(x: 30, y: 30)))

        XCTAssertEqual(closeCount, 0)
    }

    private func mouseEvent(type: NSEvent.EventType, location: CGPoint) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
    }
}
