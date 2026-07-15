import AppKit
import CoreGraphics

enum DisplayCoordinateConverter {
    static func appKitPoint(fromEventTapPoint point: CGPoint) -> CGPoint {
        guard let displayID = displayID(containingQuartzPoint: point),
              let screen = screen(for: displayID)
        else {
            return NSEvent.mouseLocation
        }

        return appKitPoint(
            fromQuartzPoint: point,
            quartzDisplayBounds: CGDisplayBounds(displayID),
            appKitScreenFrame: screen.frame
        )
    }

    static func appKitPoint(
        fromQuartzPoint point: CGPoint,
        quartzDisplayBounds: CGRect,
        appKitScreenFrame: CGRect
    ) -> CGPoint {
        CGPoint(
            x: appKitScreenFrame.minX + point.x - quartzDisplayBounds.minX,
            y: appKitScreenFrame.maxY - (point.y - quartzDisplayBounds.minY)
        )
    }

    static func eventTapPoint(fromAppKitPoint point: CGPoint) -> CGPoint {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main,
              let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else {
            return point
        }

        let displayBounds = CGDisplayBounds(screenNumber.uint32Value)
        return CGPoint(
            x: displayBounds.minX + point.x - screen.frame.minX,
            y: displayBounds.minY + screen.frame.maxY - point.y
        )
    }

    private static func displayID(containingQuartzPoint point: CGPoint) -> CGDirectDisplayID? {
        var displayID = CGDirectDisplayID()
        var displayCount: UInt32 = 0
        let status = CGGetDisplaysWithPoint(point, 1, &displayID, &displayCount)
        guard status == .success, displayCount > 0 else {
            return nil
        }
        return displayID
    }

    private static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { screen in
            guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }
            return screenNumber.uint32Value == displayID
        }
    }
}
