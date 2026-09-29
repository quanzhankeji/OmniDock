import AppKit
import XCTest
@testable import OmniDockCore

final class PreviewThumbnailViewTests: XCTestCase {
    func testTitleOnlyUpdatePreservesLiveImageLayoutAndActionIdentity() throws {
        let original = previewInfo()
        let tile = PreviewThumbnailView(info: original)
        let image = NSImage(size: NSSize(width: 800, height: 500))
        tile.update(image: image)
        let originalSize = tile.preferredTileSize
        let updated = PreviewWindowInfo(
            id: original.id, windowID: original.windowID, processIdentifier: original.processIdentifier,
            appName: original.appName, title: "A renamed document", frame: original.frame, isMinimized: false
        )
        tile.updateWindowStatus(updated)

        XCTAssertTrue(tile.subviews.compactMap { $0 as? NSTextField }.contains {
            !$0.isHidden && $0.stringValue == updated.title
        })
        XCTAssertTrue(tile.toolTip?.contains(updated.title) == true)
        XCTAssertTrue(tile.subviews.compactMap { $0 as? NSImageView }.contains { $0.image === image })
        XCTAssertEqual(tile.preferredTileSize, originalSize)
        XCTAssertEqual(PreviewWindowIdentity(tile.info), PreviewWindowIdentity(original))
        var closed: PreviewWindowInfo?
        tile.onClose = { closed = $0 }
        let closeButton = try XCTUnwrap(tile.subviews.compactMap { $0 as? PreviewCloseButtonView }.first)
        closeButton.onClose?()
        XCTAssertEqual(closed?.title, updated.title)
        XCTAssertEqual(closed.map(PreviewWindowIdentity.init), PreviewWindowIdentity(original))
    }

    func testStatusRowFitsNarrowCardsAndUpdatesWhenADisplayDisappears() throws {
        let name = String(repeating: "External Display ", count: 5)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for showsIdentity in [false, true] {
                let info = previewInfo()
                let tile = PreviewThumbnailView(info: info, showsApplicationIdentity: showsIdentity,
                                                displays: [PreviewDisplay(name: name, frame: info.frame)])
                tile.appearance = NSAppearance(named: appearance)
                tile.frame = CGRect(x: 0, y: 0, width: PreviewLayoutCalculator.minTileWidth,
                                    height: tile.preferredTileSize.height)
                tile.layoutSubtreeIfNeeded()
                let labels = tile.subviews.compactMap { $0 as? NSTextField }
                let status = try XCTUnwrap(labels.first { $0.stringValue == AppStrings.format(.previewDisplay, name) })
                let title = try XCTUnwrap(labels.first { $0.stringValue == info.title })
                XCTAssertTrue(tile.bounds.contains(status.frame))
                XCTAssertLessThanOrEqual(status.frame.maxY, title.frame.minY)
                XCTAssertEqual(status.lineBreakMode, .byTruncatingTail)
                XCTAssertEqual(status.toolTip, AppStrings.format(.previewDisplay, name))

                tile.updateDisplays([])
                XCTAssertEqual(status.stringValue, AppStrings.text(.previewDisplayUnknown))
            }
        }
    }

    func testHiddenAndMinimizedStateAreIndependentAndRefreshOnReuse() {
        let base = previewInfo()
        let tile = PreviewThumbnailView(info: PreviewWindowInfo(
            id: base.id, windowID: base.windowID, processIdentifier: base.processIdentifier,
            appName: base.appName, title: base.title, frame: base.frame,
            isMinimized: true, isApplicationHidden: true, isFullScreen: false
        ))
        let originalSize = tile.preferredTileSize
        func visibleText() -> String {
            tile.subviews.compactMap { $0 as? NSTextField }.filter { !$0.isHidden }
                .map(\.stringValue).joined(separator: "\n")
        }
        XCTAssertTrue(visibleText().contains(AppStrings.text(.previewStateHidden)))
        XCTAssertTrue(visibleText().contains(AppStrings.text(.previewStateMinimized)))
        XCTAssertFalse(visibleText().contains(AppStrings.text(.previewStateFullScreen)))

        tile.update(info: PreviewWindowInfo(
            id: base.id, windowID: base.windowID, processIdentifier: base.processIdentifier,
            appName: base.appName, title: base.title, frame: base.frame,
            isMinimized: false, isApplicationHidden: false, isFullScreen: true
        ))
        XCTAssertFalse(visibleText().contains(AppStrings.text(.previewStateHidden)))
        XCTAssertFalse(visibleText().contains(AppStrings.text(.previewStateMinimized)))
        XCTAssertTrue(visibleText().contains(AppStrings.text(.previewStateFullScreen)))
        XCTAssertEqual(tile.preferredTileSize, originalSize)
    }

    func testMinimizedStatusRemainsVisibleWithACachedThumbnail() {
        let base = previewInfo()
        let tile = PreviewThumbnailView(info: PreviewWindowInfo(
            id: base.id, windowID: base.windowID, processIdentifier: base.processIdentifier,
            appName: base.appName, title: base.title, frame: base.frame, isMinimized: true,
            staticPreviewImage: NSImage(size: CGSize(width: 800, height: 500))
        ))
        let minimized = AppStrings.text(.previewMinimizedClickRestore).components(separatedBy: "\n")[0]

        XCTAssertTrue(tile.subviews.compactMap { $0 as? NSTextField }.contains {
            !$0.isHidden && $0.stringValue.contains(minimized)
        })
    }

    func testMetadataOnlyUpdateDiscardsPriorPreviewImage() {
        let info = previewInfo()
        let tile = PreviewThumbnailView(info: info, showsApplicationIdentity: true)
        let image = NSImage(size: CGSize(width: 800, height: 500))
        tile.update(image: image)
        let imageViews = tile.subviews.compactMap { $0 as? NSImageView }
        XCTAssertTrue(imageViews.contains { $0.image === image })

        tile.update(info: PreviewWindowInfo(
            id: info.id, windowID: info.windowID, processIdentifier: info.processIdentifier,
            appName: info.appName, title: info.title, frame: info.frame, isMinimized: false,
            placeholderText: AppStrings.text(.previewMetadataOnly)
        ))

        XCTAssertFalse(imageViews.contains { $0.image === image })
        XCTAssertTrue(tile.subviews.compactMap { $0 as? NSTextField }.contains {
            !$0.isHidden && $0.stringValue == AppStrings.text(.previewMetadataOnly)
        })
    }

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

    func testIndependentSwitcherTileShowsApplicationAndWindowInformation() {
        let tile = PreviewThumbnailView(
            info: previewInfo(),
            showsApplicationIdentity: true
        )
        tile.layoutSubtreeIfNeeded()
        let labels = tile.subviews.compactMap { $0 as? NSTextField }.map(\.stringValue)
        let applicationLabel = tile.subviews
            .compactMap { $0 as? NSTextField }
            .first { $0.stringValue == "Example Browser" }
        let windowLabel = tile.subviews
            .compactMap { $0 as? NSTextField }
            .first { $0.stringValue == "Start Page" }

        XCTAssertTrue(labels.contains("Example Browser"))
        XCTAssertTrue(labels.contains("Start Page"))
        XCTAssertTrue(tile.displaysApplicationIdentity)
        XCTAssertGreaterThan(applicationLabel?.frame.minY ?? 0, windowLabel?.frame.maxY ?? .greatestFiniteMagnitude)
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
            appName: "Example Browser",
            title: "Start Page",
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
