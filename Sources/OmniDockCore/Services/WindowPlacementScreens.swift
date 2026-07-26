import AppKit
import CoreGraphics

struct WindowPlacementScreen: Equatable {
    let displayID: CGDirectDisplayID
    let frame: CGRect
    let visibleFrame: CGRect
}

@MainActor
enum WindowPlacementScreens {
    static func current() -> [WindowPlacementScreen] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber else {
                return nil
            }
            let displayID = number.uint32Value
            let quartzBounds = CGDisplayBounds(displayID)
            let visibleTopLeft = DisplayCoordinateConverter.eventTapPoint(
                fromAppKitPoint: CGPoint(
                    x: screen.visibleFrame.minX,
                    y: screen.visibleFrame.maxY
                ),
                quartzDisplayBounds: quartzBounds,
                appKitScreenFrame: screen.frame
            )
            let visibleBottomRight = DisplayCoordinateConverter.eventTapPoint(
                fromAppKitPoint: CGPoint(
                    x: screen.visibleFrame.maxX,
                    y: screen.visibleFrame.minY
                ),
                quartzDisplayBounds: quartzBounds,
                appKitScreenFrame: screen.frame
            )
            return WindowPlacementScreen(
                displayID: displayID,
                frame: quartzBounds,
                visibleFrame: CGRect(
                    x: min(visibleTopLeft.x, visibleBottomRight.x),
                    y: min(visibleTopLeft.y, visibleBottomRight.y),
                    width: abs(visibleBottomRight.x - visibleTopLeft.x),
                    height: abs(visibleBottomRight.y - visibleTopLeft.y)
                )
            )
        }
    }

    static func screen(
        containing point: CGPoint,
        in screens: [WindowPlacementScreen]
    ) -> WindowPlacementScreen? {
        screens.first { $0.frame.contains(point) }
    }

    static func screen(
        withLargestIntersection frame: CGRect,
        in screens: [WindowPlacementScreen]
    ) -> WindowPlacementScreen? {
        screens.max { lhs, rhs in
            intersectionArea(lhs.frame, frame) < intersectionArea(rhs.frame, frame)
        }
    }

    static func adjacent(
        to screen: WindowPlacementScreen,
        direction: WindowPlacementBehavior,
        in screens: [WindowPlacementScreen]
    ) -> WindowPlacementScreen? {
        guard screens.count > 1,
              let currentIndex = ordered(screens).firstIndex(where: {
                  $0.displayID == screen.displayID
              })
        else {
            return nil
        }
        let orderedScreens = ordered(screens)
        switch direction {
        case .nextDisplay:
            return orderedScreens[(currentIndex + 1) % orderedScreens.count]
        case .previousDisplay:
            return orderedScreens[(currentIndex - 1 + orderedScreens.count) % orderedScreens.count]
        default:
            return nil
        }
    }

    private static func ordered(_ screens: [WindowPlacementScreen]) -> [WindowPlacementScreen] {
        screens.sorted {
            if $0.frame.minX == $1.frame.minX {
                return $0.frame.minY < $1.frame.minY
            }
            return $0.frame.minX < $1.frame.minX
        }
    }

    private static func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else {
            return 0
        }
        return intersection.width * intersection.height
    }
}
