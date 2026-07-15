import AppKit
import CoreGraphics

public final class PreviewWindowInfo: Identifiable {
    public let id: String
    public let windowID: CGWindowID?
    public let processIdentifier: pid_t
    public let appName: String
    public let title: String
    public let frame: CGRect
    public let isMinimized: Bool
    public let staticPreviewImage: NSImage?
    public let placeholderText: String?

    public init(
        id: String,
        windowID: CGWindowID?,
        processIdentifier: pid_t,
        appName: String,
        title: String,
        frame: CGRect,
        isMinimized: Bool,
        staticPreviewImage: NSImage? = nil,
        placeholderText: String? = nil
    ) {
        self.id = id
        self.windowID = windowID
        self.processIdentifier = processIdentifier
        self.appName = appName
        self.title = title
        self.frame = frame
        self.isMinimized = isMinimized
        self.staticPreviewImage = staticPreviewImage
        self.placeholderText = placeholderText
    }
}
