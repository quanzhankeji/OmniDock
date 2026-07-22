import XCTest
@testable import OmniDockCore

final class PreviewLayoutCalculatorTests: XCTestCase {
    func testPanelFrameStaysWithinScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 700)
        let frame = PreviewLayoutCalculator.panelFrame(
            itemCount: 4,
            anchor: CGPoint(x: 980, y: 20),
            screenFrame: screen
        )

        XCTAssertGreaterThanOrEqual(frame.minX, screen.minX)
        XCTAssertLessThanOrEqual(frame.maxX, screen.maxX)
        XCTAssertGreaterThan(frame.minY, 20)
    }

    func testMessagePanelIsCompact() {
        let frame = PreviewLayoutCalculator.panelFrame(
            itemCount: 0,
            anchor: CGPoint(x: 300, y: 20),
            screenFrame: CGRect(x: 0, y: 0, width: 1000, height: 700)
        )

        XCTAssertEqual(frame.width, PreviewLayoutCalculator.messageSize.width)
        XCTAssertEqual(frame.height, PreviewLayoutCalculator.messageSize.height)
    }

    func testPanelWidthShrinksWhenThumbnailCountDrops() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 700)
        let twoWindows = PreviewLayoutCalculator.panelFrame(
            windowFrames: [
                CGRect(x: 0, y: 0, width: 1600, height: 900),
                CGRect(x: 0, y: 0, width: 900, height: 1200)
            ],
            anchor: CGPoint(x: 500, y: 20),
            screenFrame: screen
        )
        let oneWindow = PreviewLayoutCalculator.panelFrame(
            windowFrames: [
                CGRect(x: 0, y: 0, width: 1600, height: 900)
            ],
            anchor: CGPoint(x: 500, y: 20),
            screenFrame: screen
        )
        let removedTileWidth = PreviewLayoutCalculator.tileSize(
            for: CGRect(x: 0, y: 0, width: 900, height: 1200)
        ).width

        XCTAssertEqual(
            twoWindows.width - oneWindow.width,
            removedTileWidth + PreviewLayoutCalculator.gap
        )
    }

    func testTileWidthFollowsWindowAspectRatioWithFixedHeight() {
        let wide = PreviewLayoutCalculator.tileSize(for: CGRect(x: 0, y: 0, width: 1600, height: 900))
        let portrait = PreviewLayoutCalculator.tileSize(for: CGRect(x: 0, y: 0, width: 900, height: 1400))

        XCTAssertEqual(wide.height, PreviewLayoutCalculator.tileSize.height)
        XCTAssertEqual(portrait.height, PreviewLayoutCalculator.tileSize.height)
        XCTAssertGreaterThan(wide.width, portrait.width)
        XCTAssertGreaterThanOrEqual(portrait.width, PreviewLayoutCalculator.minTileWidth)
        XCTAssertLessThanOrEqual(wide.width, PreviewLayoutCalculator.maxTileWidth)
    }

    func testPanelWidthUsesDynamicTileWidths() {
        let frames = [
            CGRect(x: 0, y: 0, width: 1600, height: 900),
            CGRect(x: 0, y: 0, width: 900, height: 1400),
            CGRect(x: 0, y: 0, width: 1200, height: 900)
        ]
        let panel = PreviewLayoutCalculator.panelFrame(
            windowFrames: frames,
            anchor: CGPoint(x: 500, y: 20),
            screenFrame: CGRect(x: 0, y: 0, width: 1200, height: 700)
        )
        let expectedWidth = frames
            .map { PreviewLayoutCalculator.tileSize(for: $0).width }
            .reduce(PreviewLayoutCalculator.margin * 2, +)
            + CGFloat(frames.count - 1) * PreviewLayoutCalculator.gap

        XCTAssertEqual(panel.width, expectedWidth)
    }

    func testPanelFrameCanUseCapturedThumbnailSizes() {
        let sizes = [
            CGSize(width: 186, height: 150),
            CGSize(width: 250, height: 150)
        ]
        let panel = PreviewLayoutCalculator.panelFrame(
            tileSizes: sizes,
            anchor: CGPoint(x: 500, y: 20),
            screenFrame: CGRect(x: 0, y: 0, width: 1200, height: 700)
        )

        XCTAssertEqual(
            panel.width,
            PreviewLayoutCalculator.margin * 2 + sizes[0].width + sizes[1].width + PreviewLayoutCalculator.gap
        )
    }

    func testLargeWindowSetCapsPanelWidthButKeepsScrollableContentWidth() {
        let screenFrame = CGRect(x: 0, y: 0, width: 1200, height: 700)
        let sizes = Array(repeating: PreviewLayoutCalculator.tileSize, count: 20)
        let panel = PreviewLayoutCalculator.panelFrame(
            tileSizes: sizes,
            anchor: CGPoint(x: 600, y: 20),
            screenFrame: screenFrame
        )
        let contentWidth = PreviewLayoutCalculator.contentWidth(for: sizes)

        XCTAssertLessThanOrEqual(panel.width, screenFrame.width - PreviewLayoutCalculator.edgeInset * 2)
        XCTAssertGreaterThan(contentWidth, panel.width)
        XCTAssertGreaterThanOrEqual(panel.minX, screenFrame.minX + PreviewLayoutCalculator.edgeInset)
        XCTAssertLessThanOrEqual(panel.maxX, screenFrame.maxX - PreviewLayoutCalculator.edgeInset)
    }

    func testPanelFrameUsesLeftDockOrientation() {
        let anchor = CGPoint(x: 36, y: 400)
        let frame = PreviewLayoutCalculator.panelFrame(
            tileSizes: [PreviewLayoutCalculator.tileSize],
            anchor: anchor,
            screenFrame: CGRect(x: 0, y: 0, width: 1200, height: 800),
            orientation: .left
        )

        XCTAssertGreaterThan(frame.minX, anchor.x)
        XCTAssertEqual(frame.midY, anchor.y, accuracy: 0.5)
    }

    func testPanelFrameUsesRightDockOrientation() {
        let anchor = CGPoint(x: 1164, y: 400)
        let frame = PreviewLayoutCalculator.panelFrame(
            tileSizes: [PreviewLayoutCalculator.tileSize],
            anchor: anchor,
            screenFrame: CGRect(x: 0, y: 0, width: 1200, height: 800),
            orientation: .right
        )

        XCTAssertLessThan(frame.maxX, anchor.x)
        XCTAssertEqual(frame.midY, anchor.y, accuracy: 0.5)
    }

    func testThumbnailSizeKeepsMinimums() {
        let size = PreviewLayoutCalculator.thumbnailPixelSize(for: CGSize(width: 100, height: 80))

        XCTAssertGreaterThanOrEqual(size.width, 160)
        XCTAssertGreaterThanOrEqual(size.height, 100)
    }

    func testIndependentSwitcherUsesMultipleRowsForAWindowSetThatDoesNotFitOneRow() {
        let screen = CGRect(x: 0, y: 0, width: 1_200, height: 800)
        let metrics = PreviewLayoutCalculator.windowCycleGridMetrics(
            tileSizes: Array(repeating: PreviewLayoutCalculator.tileSize, count: 7),
            screenFrame: screen
        )

        XCTAssertGreaterThan(metrics.columnCount, 1)
        XCTAssertGreaterThan(metrics.rowCount, 1)
        XCTAssertEqual(metrics.columnWidths.count, metrics.columnCount)
        XCTAssertLessThanOrEqual(metrics.viewportSize.width, screen.width - PreviewLayoutCalculator.edgeInset * 2)
        XCTAssertLessThanOrEqual(metrics.viewportSize.height, screen.height - PreviewLayoutCalculator.edgeInset * 2)
    }

    func testIndependentSwitcherCapsViewportHeightButKeepsTheFullGridScrollable() {
        let screen = CGRect(x: 0, y: 0, width: 1_200, height: 800)
        let metrics = PreviewLayoutCalculator.windowCycleGridMetrics(
            tileSizes: Array(repeating: PreviewLayoutCalculator.tileSize, count: 30),
            screenFrame: screen
        )

        XCTAssertGreaterThan(metrics.contentSize.height, metrics.viewportSize.height)
        XCTAssertGreaterThan(metrics.rowCount, 3)
    }

    func testIndependentSwitcherWrapsLargeWindowSetsOnWideDisplays() {
        let metrics = PreviewLayoutCalculator.windowCycleGridMetrics(
            tileSizes: Array(repeating: PreviewLayoutCalculator.tileSize, count: 10),
            screenFrame: CGRect(x: 0, y: 0, width: 3_840, height: 2_160)
        )

        XCTAssertEqual(metrics.columnCount, 7)
        XCTAssertEqual(metrics.rowCount, 2)
    }
}
