import CoreGraphics

enum WindowPlacementGeometry {
    static func targetFrame(
        for command: WindowPlacementCommand,
        currentFrame: CGRect,
        visibleFrame: CGRect,
        adjacentVisibleFrame: CGRect? = nil,
        restoreFrame: CGRect? = nil
    ) -> CGRect? {
        switch command.behavior {
        case .proportional:
            return command.targetRegion?.frame(in: visibleFrame)
        case .maximize:
            return visibleFrame.integral
        case .center:
            let size = CGSize(
                width: min(currentFrame.width, visibleFrame.width),
                height: min(currentFrame.height, visibleFrame.height)
            )
            return aligned(CGRect(
                x: visibleFrame.midX - size.width / 2,
                y: visibleFrame.midY - size.height / 2,
                width: size.width,
                height: size.height
            ))
        case .nextDisplay, .previousDisplay:
            guard let adjacentVisibleFrame else {
                return nil
            }
            return mappedFrame(
                currentFrame,
                from: visibleFrame,
                to: adjacentVisibleFrame
            )
        case .restore:
            return restoreFrame?.integral
        }
    }

    static func mappedFrame(_ frame: CGRect, from source: CGRect, to destination: CGRect) -> CGRect {
        guard source.width > 0, source.height > 0 else {
            return frame
        }
        let relativeCenterX = (frame.midX - source.minX) / source.width
        let relativeCenterY = (frame.midY - source.minY) / source.height
        let size = CGSize(
            width: min(frame.width, destination.width),
            height: min(frame.height, destination.height)
        )
        let proposed = CGRect(
            x: destination.minX + destination.width * relativeCenterX - size.width / 2,
            y: destination.minY + destination.height * relativeCenterY - size.height / 2,
            width: size.width,
            height: size.height
        )
        return aligned(clamped(proposed, to: destination))
    }

    static func clamped(_ frame: CGRect, to container: CGRect) -> CGRect {
        let width = min(frame.width, container.width)
        let height = min(frame.height, container.height)
        return CGRect(
            x: min(max(frame.minX, container.minX), container.maxX - width),
            y: min(max(frame.minY, container.minY), container.maxY - height),
            width: width,
            height: height
        )
    }

    static func aligned(_ frame: CGRect) -> CGRect {
        CGRect(
            x: frame.origin.x.rounded(),
            y: frame.origin.y.rounded(),
            width: frame.width.rounded(),
            height: frame.height.rounded()
        )
    }

    static func region(containing point: CGPoint, in screenFrame: CGRect) -> WindowPlacementRegion? {
        guard screenFrame.width > 0, screenFrame.height > 0, screenFrame.contains(point) else {
            return nil
        }
        return WindowPlacementRegion(
            x: (point.x - screenFrame.minX) / screenFrame.width,
            y: (point.y - screenFrame.minY) / screenFrame.height,
            width: 1 / Double(WindowPlacementRegion.columns),
            height: 1 / Double(WindowPlacementRegion.rows)
        )
    }
}
