import AppKit
import XCTest
@testable import OmniDockCore

final class PreviewThumbnailViewTests: XCTestCase {
    func testTileAcceptsFirstMouse() {
        let tile = PreviewThumbnailView(info: previewInfo())

        XCTAssertTrue(tile.acceptsFirstMouse(for: nil))
    }

    func testCloseButtonWinsHitTestingAndDoesNotTriggerTileClick() throws {
        let tile = PreviewThumbnailView(info: previewInfo())
        tile.layoutSubtreeIfNeeded()
        let closeButton = try XCTUnwrap(tile.subviews.compactMap { $0 as? PreviewCloseButtonView }.first)
        let hitPoint = tile.convert(
            CGPoint(x: closeButton.bounds.midX, y: closeButton.bounds.midY),
            from: closeButton
        )
        var tileClickCount = 0
        var closeCount = 0
        tile.onClick = { _ in tileClickCount += 1 }
        closeButton.onClose = { closeCount += 1 }

        XCTAssertTrue(tile.hitTest(hitPoint) === closeButton)
        closeButton.mouseDown(with: mouseEvent(type: .leftMouseDown, location: hitPoint))
        closeButton.mouseUp(with: mouseEvent(type: .leftMouseUp, location: hitPoint))

        XCTAssertEqual(closeCount, 1)
        XCTAssertEqual(tileClickCount, 0)
    }

    func testQuitButtonWinsHitTestingAndDoesNotTriggerTileClick() throws {
        let tile = PreviewThumbnailView(info: previewInfo())
        tile.layoutSubtreeIfNeeded()
        let quitButton = try XCTUnwrap(tile.subviews.compactMap { $0 as? PreviewQuitButtonView }.first)
        let hitPoint = tile.convert(
            CGPoint(x: quitButton.bounds.midX, y: quitButton.bounds.midY),
            from: quitButton
        )
        var tileClickCount = 0
        var quitCount = 0
        tile.onClick = { _ in tileClickCount += 1 }
        quitButton.onQuit = { quitCount += 1 }

        XCTAssertTrue(tile.hitTest(hitPoint) === quitButton)
        quitButton.mouseDown(with: mouseEvent(type: .leftMouseDown, location: hitPoint))
        quitButton.mouseUp(with: mouseEvent(type: .leftMouseUp, location: hitPoint))

        XCTAssertEqual(quitCount, 1)
        XCTAssertEqual(tileClickCount, 0)
    }

    func testQuitButtonIsPositionedToTheLeftOfCloseButton() throws {
        let tile = PreviewThumbnailView(info: previewInfo())
        tile.layoutSubtreeIfNeeded()
        let closeButton = try XCTUnwrap(tile.subviews.compactMap { $0 as? PreviewCloseButtonView }.first)
        let quitButton = try XCTUnwrap(tile.subviews.compactMap { $0 as? PreviewQuitButtonView }.first)

        XCTAssertLessThan(quitButton.frame.midX, closeButton.frame.midX)
    }

    func testCommandTabHoverShowsOnlyTheHoveredActionGlyph() throws {
        let info = previewInfo()
        let tile = PreviewThumbnailView(info: info)
        let closeButton = try XCTUnwrap(tile.subviews.compactMap { $0 as? PreviewCloseButtonView }.first)
        let quitButton = try XCTUnwrap(tile.subviews.compactMap { $0 as? PreviewQuitButtonView }.first)

        tile.setCommandTabHoveredAction(.closeWindow(PreviewWindowIdentity(info)))

        XCTAssertTrue(closeButton.isGlyphVisible)
        XCTAssertFalse(quitButton.isGlyphVisible)

        tile.setCommandTabHoveredAction(.quitApplication(info.processIdentifier))

        XCTAssertFalse(closeButton.isGlyphVisible)
        XCTAssertTrue(quitButton.isGlyphVisible)
    }

    func testClickFiresOnMouseUpInsteadOfMouseDown() {
        let tile = PreviewThumbnailView(info: previewInfo())
        var clickCount = 0
        tile.onClick = { _ in
            clickCount += 1
        }

        tile.mouseDown(with: mouseEvent(type: .leftMouseDown, location: CGPoint(x: 20, y: 20)))
        XCTAssertEqual(clickCount, 0)

        tile.mouseUp(with: mouseEvent(type: .leftMouseUp, location: CGPoint(x: 20, y: 20)))
        XCTAssertEqual(clickCount, 1)
    }

    func testHorizontalDragScrollsAndDoesNotClick() {
        let tile = PreviewThumbnailView(info: previewInfo())
        var clickCount = 0
        var dragDeltas: [CGFloat] = []
        tile.onClick = { _ in
            clickCount += 1
        }
        tile.onHorizontalDrag = { deltaX in
            dragDeltas.append(deltaX)
        }

        tile.mouseDown(with: mouseEvent(type: .leftMouseDown, location: CGPoint(x: 80, y: 20)))
        tile.mouseDragged(with: mouseEvent(type: .leftMouseDragged, location: CGPoint(x: 60, y: 20)))
        tile.mouseUp(with: mouseEvent(type: .leftMouseUp, location: CGPoint(x: 60, y: 20)))

        XCTAssertEqual(clickCount, 0)
        XCTAssertEqual(dragDeltas, [-20])
    }

    private func previewInfo() -> PreviewWindowInfo {
        PreviewWindowInfo(
            id: "window-1",
            windowID: 1,
            processIdentifier: 123,
            appName: "Safari",
            title: "起始页",
            frame: CGRect(x: 0, y: 0, width: 1200, height: 800),
            isMinimized: false
        )
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
