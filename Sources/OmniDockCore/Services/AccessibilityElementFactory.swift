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
}
