import AppKit
import ApplicationServices
import CoreGraphics

struct WindowPlacementTarget {
    let element: AXUIElement
    let processIdentifier: pid_t
    let windowID: CGWindowID?
    let frame: CGRect
    let isMinimized: Bool
    let isFullScreen: Bool
    let canMove: Bool
    let canResize: Bool

    var runtimeIdentifier: WindowPlacementRuntimeIdentifier {
        WindowPlacementRuntimeIdentifier(
            processIdentifier: processIdentifier,
            windowID: windowID,
            fallbackElementHash: CFHash(element)
        )
    }
}

struct WindowPlacementRuntimeIdentifier: Hashable {
    let processIdentifier: pid_t
    let windowID: CGWindowID?
    let fallbackElementHash: CFHashCode

    static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.processIdentifier == rhs.processIdentifier else {
            return false
        }
        if let lhsWindowID = lhs.windowID, let rhsWindowID = rhs.windowID {
            return lhsWindowID == rhsWindowID
        }
        return lhs.windowID == nil
            && rhs.windowID == nil
            && lhs.fallbackElementHash == rhs.fallbackElementHash
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(processIdentifier)
        if let windowID {
            hasher.combine(windowID)
        } else {
            hasher.combine(fallbackElementHash)
        }
    }
}

enum WindowPlacementExecutionResult: Equatable {
    case applied(CGRect)
    case noWindow
    case unsupportedWindow
    case noTargetScreen
    case noRestoreFrame
    case accessibilityFailure
}

enum WindowPlacementGreenButtonAvailabilityPolicy {
    static func isAvailable(
        windowFrame: CGRect,
        buttonFrame: CGRect,
        isWindowMinimized: Bool,
        isWindowFullScreen: Bool,
        canResizeWindow: Bool,
        isButtonHidden: Bool?,
        isButtonEnabled: Bool?
    ) -> Bool {
        guard !isWindowMinimized,
              !isWindowFullScreen,
              canResizeWindow,
              isButtonHidden != true,
              isButtonEnabled != false,
              (6...48).contains(buttonFrame.width),
              (6...48).contains(buttonFrame.height)
        else {
            return false
        }

        let windowBounds = windowFrame.insetBy(dx: -4, dy: -4)
        guard windowBounds.contains(
            CGPoint(x: buttonFrame.midX, y: buttonFrame.midY)
        ) else {
            return false
        }

        let titleBarDepth = min(72, max(44, windowFrame.height * 0.12))
        return buttonFrame.midY <= windowFrame.minY + titleBarDepth
    }
}

enum WindowPlacementAccessibility {
    static func focusedGreenButtonTarget()
        -> (target: WindowPlacementTarget, buttonFrame: CGRect)? {
        guard let target = focusedWindow(),
              let button = availableGreenButton(for: target)
        else {
            return nil
        }
        return (target, button.frame)
    }

    private static func availableGreenButton(
        for target: WindowPlacementTarget
    ) -> (element: AXUIElement, frame: CGRect)? {
        let buttonAttributes = [
            kAXFullScreenButtonAttribute as String,
            kAXZoomButtonAttribute as String
        ]
        for attribute in buttonAttributes {
            guard let button = elementAttribute(
                attribute,
                from: target.element
            ),
            let buttonFrame = frameAttribute(from: button)
            else {
                continue
            }
            guard WindowPlacementGreenButtonAvailabilityPolicy.isAvailable(
                windowFrame: target.frame,
                buttonFrame: buttonFrame,
                isWindowMinimized: target.isMinimized,
                isWindowFullScreen: target.isFullScreen,
                canResizeWindow: target.canResize,
                isButtonHidden: boolAttribute(
                    kAXHiddenAttribute,
                    from: button
                ),
                isButtonEnabled: boolAttribute(
                    kAXEnabledAttribute,
                    from: button
                )
            ) else {
                continue
            }
            return (button, buttonFrame)
        }
        return nil
    }

    static func focusedWindow() -> WindowPlacementTarget? {
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else {
            return nil
        }

        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        if let focused = elementAttribute(kAXFocusedWindowAttribute, from: appElement),
           let target = target(
               from: focused,
               processIdentifier: application.processIdentifier
           ) {
            return target
        }

        return elementsAttribute(kAXWindowsAttribute, from: appElement)
            .lazy
            .compactMap {
                target(from: $0, processIdentifier: application.processIdentifier)
            }
            .first
    }

    static func pressGreenButton(for target: WindowPlacementTarget) -> Bool {
        guard let button = availableGreenButton(for: target)?.element else {
            return false
        }
        return AXUIElementPerformAction(
            button,
            kAXPressAction as CFString
        ) == .success
    }

    static func window(at eventTapPoint: CGPoint) -> WindowPlacementTarget? {
        let systemWideElement = AXUIElementCreateSystemWide()
        var rawElement: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            systemWideElement,
            Float(eventTapPoint.x),
            Float(eventTapPoint.y),
            &rawElement
        ) == .success,
        let rawElement
        else {
            return nil
        }

        var processIdentifier = pid_t()
        guard AXUIElementGetPid(rawElement, &processIdentifier) == .success,
              processIdentifier != ProcessInfo.processInfo.processIdentifier
        else {
            return nil
        }

        if stringAttribute(kAXRoleAttribute, from: rawElement) == kAXWindowRole as String {
            return target(from: rawElement, processIdentifier: processIdentifier)
        }

        guard let window = elementAttribute(kAXWindowAttribute, from: rawElement) else {
            return nil
        }
        return target(from: window, processIdentifier: processIdentifier)
    }

    static func setFrame(_ frame: CGRect, for target: WindowPlacementTarget) -> CGRect? {
        if target.isMinimized {
            _ = AXUIElementSetAttributeValue(
                target.element,
                kAXMinimizedAttribute as CFString,
                kCFBooleanFalse
            )
        }

        guard setPoint(frame.origin, attribute: kAXPositionAttribute, on: target.element),
              setSize(frame.size, attribute: kAXSizeAttribute, on: target.element)
        else {
            return nil
        }

        // Some applications adjust position while enforcing their minimum size.
        // Re-applying the origin keeps the accepted result aligned to the chosen region.
        _ = setPoint(frame.origin, attribute: kAXPositionAttribute, on: target.element)
        return frameAttribute(from: target.element)
    }

    static func currentFrame(of target: WindowPlacementTarget) -> CGRect? {
        frameAttribute(from: target.element)
    }

    private static func target(
        from element: AXUIElement,
        processIdentifier: pid_t
    ) -> WindowPlacementTarget? {
        let role = stringAttribute(kAXRoleAttribute, from: element)
        let subrole = stringAttribute(kAXSubroleAttribute, from: element)
        guard WindowFiltering.isNormalAXWindow(role: role, subrole: subrole),
              let frame = frameAttribute(from: element),
              frame.width >= 80,
              frame.height >= 60
        else {
            return nil
        }

        return WindowPlacementTarget(
            element: element,
            processIdentifier: processIdentifier,
            windowID: intAttribute("AXWindowNumber", from: element).map(CGWindowID.init),
            frame: frame,
            isMinimized: boolAttribute(kAXMinimizedAttribute, from: element) ?? false,
            isFullScreen: boolAttribute("AXFullScreen", from: element) ?? false,
            canMove: isSettable(kAXPositionAttribute, on: element),
            canResize: isSettable(kAXSizeAttribute, on: element)
        )
    }

    private static func isSettable(_ attribute: String, on element: AXUIElement) -> Bool {
        var isSettable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(
            element,
            attribute as CFString,
            &isSettable
        ) == .success else {
            return false
        }
        return isSettable.boolValue
    }

    private static func setPoint(
        _ point: CGPoint,
        attribute: String,
        on element: AXUIElement
    ) -> Bool {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else {
            return false
        }
        return AXUIElementSetAttributeValue(
            element,
            attribute as CFString,
            value
        ) == .success
    }

    private static func setSize(
        _ size: CGSize,
        attribute: String,
        on element: AXUIElement
    ) -> Bool {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else {
            return false
        }
        return AXUIElementSetAttributeValue(
            element,
            attribute as CFString,
            value
        ) == .success
    }

    private static func frameAttribute(from element: AXUIElement) -> CGRect? {
        guard let origin = pointAttribute(kAXPositionAttribute, from: element),
              let size = sizeAttribute(kAXSizeAttribute, from: element)
        else {
            return nil
        }
        return CGRect(origin: origin, size: size)
    }

    private static func elementAttribute(
        _ attribute: String,
        from element: AXUIElement
    ) -> AXUIElement? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &rawValue
        ) == .success,
        let rawValue,
        CFGetTypeID(rawValue) == AXUIElementGetTypeID()
        else {
            return nil
        }
        return (rawValue as! AXUIElement)
    }

    private static func elementsAttribute(
        _ attribute: String,
        from element: AXUIElement
    ) -> [AXUIElement] {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &rawValue
        ) == .success,
        let values = rawValue as? [AXUIElement]
        else {
            return []
        }
        return values
    }

    private static func stringAttribute(
        _ attribute: String,
        from element: AXUIElement
    ) -> String? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &rawValue
        ) == .success else {
            return nil
        }
        return rawValue as? String
    }

    private static func boolAttribute(
        _ attribute: String,
        from element: AXUIElement
    ) -> Bool? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &rawValue
        ) == .success else {
            return nil
        }
        return rawValue as? Bool
    }

    private static func intAttribute(
        _ attribute: String,
        from element: AXUIElement
    ) -> Int? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &rawValue
        ) == .success else {
            return nil
        }
        return (rawValue as? NSNumber)?.intValue
    }

    private static func pointAttribute(
        _ attribute: String,
        from element: AXUIElement
    ) -> CGPoint? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &rawValue
        ) == .success,
        let rawValue,
        CFGetTypeID(rawValue) == AXValueGetTypeID()
        else {
            return nil
        }
        let value = rawValue as! AXValue
        var point = CGPoint.zero
        return AXValueGetValue(value, .cgPoint, &point) ? point : nil
    }

    private static func sizeAttribute(
        _ attribute: String,
        from element: AXUIElement
    ) -> CGSize? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &rawValue
        ) == .success,
        let rawValue,
        CFGetTypeID(rawValue) == AXValueGetTypeID()
        else {
            return nil
        }
        let value = rawValue as! AXValue
        var size = CGSize.zero
        return AXValueGetValue(value, .cgSize, &size) ? size : nil
    }
}
