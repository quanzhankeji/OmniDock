import ApplicationServices

enum AccessibilityElementFactory {
    static let messagingTimeout: Float = 0.5

    static func application(
        processIdentifier: pid_t,
        timeout: Float = messagingTimeout
    ) -> AXUIElement {
        let element = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(element, timeout)
        return element
    }

    static func systemWide(timeout: Float = messagingTimeout) -> AXUIElement {
        let element = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(element, timeout)
        return element
    }

    static func pointAttribute(
        _ attribute: String,
        from element: AXUIElement
    ) -> CGPoint? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &rawValue
        ) == .success else {
            return nil
        }
        return point(from: rawValue)
    }

    static func sizeAttribute(
        _ attribute: String,
        from element: AXUIElement
    ) -> CGSize? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &rawValue
        ) == .success else {
            return nil
        }
        return size(from: rawValue)
    }

    static func point(from rawValue: CFTypeRef?) -> CGPoint? {
        guard let rawValue,
              CFGetTypeID(rawValue) == AXValueGetTypeID()
        else {
            return nil
        }
        var point = CGPoint.zero
        return AXValueGetValue(rawValue as! AXValue, .cgPoint, &point) ? point : nil
    }

    static func size(from rawValue: CFTypeRef?) -> CGSize? {
        guard let rawValue,
              CFGetTypeID(rawValue) == AXValueGetTypeID()
        else {
            return nil
        }
        var size = CGSize.zero
        return AXValueGetValue(rawValue as! AXValue, .cgSize, &size) ? size : nil
    }
}
