import AppKit

struct PreviewGridMetrics: Equatable {
    let columnCount: Int
    let rowCount: Int
    let columnWidths: [CGFloat]
    let rowHeight: CGFloat
    let contentSize: CGSize
    let viewportSize: CGSize

    var gridSize: CGSize {
        CGSize(
            width: max(0, contentSize.width - PreviewLayoutCalculator.margin * 2),
            height: max(0, contentSize.height - PreviewLayoutCalculator.margin * 2)
        )
    }
}

public enum PreviewLayoutCalculator {
    public static let tileSize = CGSize(width: 220, height: 150)
    public static let minTileWidth: CGFloat = 150
    public static let maxTileWidth: CGFloat = 280
    public static let messageSize = CGSize(width: 260, height: 82)
    public static let margin: CGFloat = 12
    public static let gap: CGFloat = 10
    public static let edgeInset: CGFloat = 12

    public static func panelFrame(itemCount: Int, anchor: CGPoint, screenFrame: CGRect) -> CGRect {
        let count = max(1, itemCount)
        let width = itemCount == 0
            ? messageSize.width
            : CGFloat(count) * tileSize.width + CGFloat(count - 1) * gap + margin * 2
        let height = itemCount == 0 ? messageSize.height : tileSize.height + margin * 2
        return panelFrame(
            size: CGSize(width: width, height: height),
            anchor: anchor,
            screenFrame: screenFrame,
            orientation: .bottom
        )
    }

    public static func panelFrame(windowFrames: [CGRect], anchor: CGPoint, screenFrame: CGRect) -> CGRect {
        guard !windowFrames.isEmpty else {
            return panelFrame(itemCount: 0, anchor: anchor, screenFrame: screenFrame)
        }

        let sizes = windowFrames.map(tileSize(for:))
        return panelFrame(tileSizes: sizes, anchor: anchor, screenFrame: screenFrame)
    }

    public static func panelFrame(tileSizes: [CGSize], anchor: CGPoint, screenFrame: CGRect) -> CGRect {
        guard !tileSizes.isEmpty else {
            return panelFrame(itemCount: 0, anchor: anchor, screenFrame: screenFrame)
        }

        let width = contentWidth(for: tileSizes)
        let height = tileSize.height + margin * 2

        return panelFrame(
            size: CGSize(width: width, height: height),
            anchor: anchor,
            screenFrame: screenFrame,
            orientation: .bottom
        )
    }

    public static func panelFrame(
        tileSizes: [CGSize],
        anchor: CGPoint,
        screenFrame: CGRect,
        orientation: DockOrientation
    ) -> CGRect {
        guard !tileSizes.isEmpty else {
            return panelFrame(itemCount: 0, anchor: anchor, screenFrame: screenFrame)
        }

        let width = contentWidth(for: tileSizes)
        let height = tileSize.height + margin * 2
        return panelFrame(
            size: CGSize(width: width, height: height),
            anchor: anchor,
            screenFrame: screenFrame,
            orientation: orientation
        )
    }

    public static func tileSize(for windowFrame: CGRect) -> CGSize {
        tileSize(forContentAspectRatio: contentAspectRatio(for: windowFrame))
    }

    public static func tileSize(forContentAspectRatio aspectRatio: CGFloat) -> CGSize {
        let imageHeight = tileSize.height - 40
        let safeAspectRatio = aspectRatio.isFinite && aspectRatio > 0
            ? aspectRatio
            : (tileSize.width - 16) / imageHeight
        let width = min(max(safeAspectRatio * imageHeight + 16, minTileWidth), maxTileWidth)
        return CGSize(width: width.rounded(.toNearestOrAwayFromZero), height: tileSize.height)
    }

    public static func contentAspectRatio(for windowFrame: CGRect) -> CGFloat {
        guard windowFrame.width > 0, windowFrame.height > 0 else {
            return (tileSize.width - 16) / (tileSize.height - 40)
        }
        return windowFrame.width / windowFrame.height
    }

    public static func thumbnailPixelSize(for sourceSize: CGSize) -> CGSize {
        PreviewCapturePolicy.adaptive(
            livePreviewsEnabled: true,
            windowCount: 1,
            powerState: PreviewPowerState(isLowPowerModeEnabled: false, isOnBatteryPower: false)
        ).thumbnailPixelSize(for: sourceSize)
    }

    public static func contentWidth(for tileSizes: [CGSize]) -> CGFloat {
        tileSizes.reduce(margin * 2) { partial, size in
            partial + size.width
        } + CGFloat(max(0, tileSizes.count - 1)) * gap
    }

    public static func maximumPanelWidth(screenFrame: CGRect) -> CGFloat {
        max(messageSize.width, screenFrame.width - edgeInset * 2)
    }

    public static func centeredPanelFrame(
        tileSizes: [CGSize],
        screenFrame: CGRect
    ) -> CGRect {
        let width = min(contentWidth(for: tileSizes), maximumPanelWidth(screenFrame: screenFrame))
        let height = tileSize.height + margin * 2
        return CGRect(
            x: screenFrame.midX - width / 2,
            y: screenFrame.midY - height / 2,
            width: width,
            height: height
        ).integral
    }

    static func windowCycleGridMetrics(
        tileSizes: [CGSize],
        screenFrame: CGRect
    ) -> PreviewGridMetrics {
        let safeTileSizes = tileSizes.isEmpty ? [tileSize] : tileSizes
        let availableWidth = maximumPanelWidth(screenFrame: screenFrame)
        let widestTile = safeTileSizes.map(\.width).max() ?? tileSize.width
        let availableGridWidth = max(1, availableWidth - margin * 2)
        let fittingColumns = Int(
            floor((availableGridWidth + gap) / max(1, widestTile + gap))
        )
        let columnCount = min(
            safeTileSizes.count,
            max(1, min(fittingColumns, preferredSwitcherColumnLimit(screenFrame: screenFrame)))
        )
        let rowCount = Int(ceil(CGFloat(safeTileSizes.count) / CGFloat(columnCount)))
        let rowHeight = safeTileSizes.map(\.height).max() ?? tileSize.height

        var columnWidths = Array(repeating: CGFloat(0), count: columnCount)
        for (index, size) in safeTileSizes.enumerated() {
            columnWidths[index % columnCount] = max(columnWidths[index % columnCount], size.width)
        }

        let gridWidth = columnWidths.reduce(0, +) + CGFloat(max(0, columnCount - 1)) * gap
        let gridHeight = CGFloat(rowCount) * rowHeight + CGFloat(max(0, rowCount - 1)) * gap
        let contentSize = CGSize(
            width: gridWidth + margin * 2,
            height: gridHeight + margin * 2
        )
        let maximumHeight = max(
            messageSize.height,
            min(screenFrame.height * 0.70, screenFrame.height - edgeInset * 2)
        )
        let viewportSize = CGSize(
            width: min(contentSize.width, availableWidth),
            height: min(contentSize.height, maximumHeight)
        )
        return PreviewGridMetrics(
            columnCount: columnCount,
            rowCount: rowCount,
            columnWidths: columnWidths,
            rowHeight: rowHeight,
            contentSize: contentSize,
            viewportSize: viewportSize
        )
    }

    static func centeredPanelFrame(
        gridMetrics: PreviewGridMetrics,
        screenFrame: CGRect
    ) -> CGRect {
        CGRect(
            x: screenFrame.midX - gridMetrics.viewportSize.width / 2,
            y: screenFrame.midY - gridMetrics.viewportSize.height / 2,
            width: gridMetrics.viewportSize.width,
            height: gridMetrics.viewportSize.height
        ).integral
    }

    private static func preferredSwitcherColumnLimit(screenFrame: CGRect) -> Int {
        switch screenFrame.width {
        case ..<1_280:
            4
        case ..<1_800:
            5
        case ..<2_560:
            6
        default:
            7
        }
    }

    private static func panelFrame(
        size: CGSize,
        anchor: CGPoint,
        screenFrame: CGRect,
        orientation: DockOrientation
    ) -> CGRect {
        let spacing: CGFloat = 74
        let effectiveSize = CGSize(
            width: min(size.width, maximumPanelWidth(screenFrame: screenFrame)),
            height: size.height
        )
        let rawOrigin: CGPoint

        switch orientation {
        case .bottom:
            rawOrigin = CGPoint(x: anchor.x - effectiveSize.width / 2, y: anchor.y + spacing)
        case .left:
            rawOrigin = CGPoint(x: anchor.x + spacing, y: anchor.y - effectiveSize.height / 2)
        case .right:
            rawOrigin = CGPoint(x: anchor.x - effectiveSize.width - spacing, y: anchor.y - effectiveSize.height / 2)
        }

        let x = min(max(rawOrigin.x, screenFrame.minX + edgeInset), screenFrame.maxX - effectiveSize.width - edgeInset)
        let y = min(max(rawOrigin.y, screenFrame.minY + edgeInset), screenFrame.maxY - effectiveSize.height - edgeInset)
        return CGRect(x: x, y: y, width: effectiveSize.width, height: effectiveSize.height)
    }
}
