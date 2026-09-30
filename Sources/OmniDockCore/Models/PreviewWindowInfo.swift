import AppKit
import ApplicationServices
import CoreGraphics

public struct PreviewAccessibilityWindowReference: Hashable {
    let element: AXUIElement
    let processIdentifier: pid_t
    let applicationLaunchDate: Date

    func resolve(
        in windows: [AXUIElement],
        processIdentifier: pid_t,
        applicationLaunchDate: Date?
    ) -> AXUIElement? {
        guard self.processIdentifier == processIdentifier,
              self.applicationLaunchDate == applicationLaunchDate else { return nil }
        var owner: pid_t = 0
        guard AXUIElementGetPid(element, &owner) == .success,
              owner == processIdentifier,
              windows.contains(where: { CFEqual($0, element) }) else { return nil }
        return element
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.processIdentifier == rhs.processIdentifier
            && lhs.applicationLaunchDate == rhs.applicationLaunchDate
            && CFEqual(lhs.element, rhs.element)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(processIdentifier)
        hasher.combine(applicationLaunchDate)
        hasher.combine(CFHash(element))
    }
}

public final class PreviewWindowInfo: Identifiable {
    public let id: String
    public let windowID: CGWindowID?
    public let processIdentifier: pid_t
    public let appName: String
    public let title: String
    public let frame: CGRect
    public let isMinimized: Bool
    public let isApplicationHidden: Bool?
    public let isFullScreen: Bool?
    public let staticPreviewImage: NSImage?
    public let placeholderText: String?
    public let accessibilityReference: PreviewAccessibilityWindowReference?

    public init(
        id: String,
        windowID: CGWindowID?,
        processIdentifier: pid_t,
        appName: String,
        title: String,
        frame: CGRect,
        isMinimized: Bool,
        isApplicationHidden: Bool? = nil,
        isFullScreen: Bool? = nil,
        staticPreviewImage: NSImage? = nil,
        placeholderText: String? = nil,
        accessibilityReference: PreviewAccessibilityWindowReference? = nil
    ) {
        self.id = id
        self.windowID = windowID
        self.processIdentifier = processIdentifier
        self.appName = appName
        self.title = title
        self.frame = frame
        self.isMinimized = isMinimized
        self.isApplicationHidden = isApplicationHidden
        self.isFullScreen = isFullScreen
        self.staticPreviewImage = staticPreviewImage
        self.placeholderText = placeholderText
        self.accessibilityReference = accessibilityReference
    }
}
