import AppKit
import CoreGraphics

public enum DockOrientation: String, Equatable {
    case bottom
    case left
    case right
}

public struct DockGeometry: Equatable {
    public static let likelyDockEdgeDepth: CGFloat = 136

    public init() {}

    public func isPointInLikelyDockArea(_ point: CGPoint, screen: NSScreen?) -> Bool {
        let targetScreen = screen ?? NSScreen.main
        guard let targetScreen else {
            return true
        }
        return isPointInLikelyDockArea(
            point,
            screenFrame: targetScreen.frame,
            visibleFrame: targetScreen.visibleFrame
        )
    }

    public func isPointInLikelyDockArea(
        _ point: CGPoint,
        screenFrame frame: CGRect,
        visibleFrame visible: CGRect
    ) -> Bool {
        guard point.x >= frame.minX,
              point.x <= frame.maxX,
              point.y >= frame.minY,
              point.y <= frame.maxY
        else {
            return false
        }

        let bottomDockDepth = max(0, visible.minY - frame.minY)
        let leftDockDepth = max(0, visible.minX - frame.minX)
        let rightDockDepth = max(0, frame.maxX - visible.maxX)
        let isBelowMenuBar = point.y <= min(frame.maxY, visible.maxY)

        return point.y <= frame.minY + bottomDockDepth + Self.likelyDockEdgeDepth
            || (isBelowMenuBar && point.x <= frame.minX + leftDockDepth + Self.likelyDockEdgeDepth)
            || (isBelowMenuBar && point.x >= frame.maxX - rightDockDepth - Self.likelyDockEdgeDepth)
    }

    public func inferredOrientation(
        dockItemFrame: CGRect?,
        anchor: CGPoint,
        screenFrame: CGRect
    ) -> DockOrientation {
        let distances: [(orientation: DockOrientation, distance: CGFloat)]
        if let dockItemFrame, isUsable(dockItemFrame) {
            distances = [
                (.bottom, abs(dockItemFrame.minY - screenFrame.minY)),
                (.left, abs(dockItemFrame.minX - screenFrame.minX)),
                (.right, abs(screenFrame.maxX - dockItemFrame.maxX))
            ]
        } else {
            distances = [
                (.bottom, abs(anchor.y - screenFrame.minY)),
                (.left, abs(anchor.x - screenFrame.minX)),
                (.right, abs(screenFrame.maxX - anchor.x))
            ]
        }

        return distances.dropFirst().reduce(distances[0]) { closest, candidate in
            candidate.distance < closest.distance ? candidate : closest
        }.orientation
    }

    private func isUsable(_ frame: CGRect) -> Bool {
        frame.width > 0
            && frame.height > 0
            && frame.minX.isFinite
            && frame.minY.isFinite
            && frame.maxX.isFinite
            && frame.maxY.isFinite
    }
}
