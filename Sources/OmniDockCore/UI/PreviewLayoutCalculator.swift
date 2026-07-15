import AppKit

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
