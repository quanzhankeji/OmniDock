import AppKit
import ApplicationServices
import CoreGraphics

struct DockScreenInventoryItem: Equatable, Sendable {
    let displayIdentifier: CGDirectDisplayID
    let appKitFrame: CGRect
    let eventTapFrame: CGRect
}

struct DockScreenInventory: Equatable, Sendable {
    let screens: [DockScreenInventoryItem]
    let mainAppKitFrame: CGRect?

    static let empty = DockScreenInventory(screens: [], mainAppKitFrame: nil)

    func appKitFrame(fromEventTapFrame frame: CGRect) -> CGRect? {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        guard let screen = screens.first(where: { $0.eventTapFrame.contains(center) }) else {
            return nil
        }

        let firstCorner = DisplayCoordinateConverter.appKitPoint(
            fromQuartzPoint: frame.origin,
            quartzDisplayBounds: screen.eventTapFrame,
            appKitScreenFrame: screen.appKitFrame
        )
        let secondCorner = DisplayCoordinateConverter.appKitPoint(
            fromQuartzPoint: CGPoint(x: frame.maxX, y: frame.maxY),
            quartzDisplayBounds: screen.eventTapFrame,
            appKitScreenFrame: screen.appKitFrame
        )
        return CGRect(
            x: min(firstCorner.x, secondCorner.x),
            y: min(firstCorner.y, secondCorner.y),
            width: abs(secondCorner.x - firstCorner.x),
            height: abs(secondCorner.y - firstCorner.y)
        )
    }

    func eventTapFrame(fromAppKitFrame frame: CGRect) -> CGRect? {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        guard let screen = screens.first(where: { $0.appKitFrame.contains(center) }) else {
            return nil
        }

        let firstCorner = DisplayCoordinateConverter.eventTapPoint(
            fromAppKitPoint: frame.origin,
            quartzDisplayBounds: screen.eventTapFrame,
            appKitScreenFrame: screen.appKitFrame
        )
        let secondCorner = DisplayCoordinateConverter.eventTapPoint(
            fromAppKitPoint: CGPoint(x: frame.maxX, y: frame.maxY),
            quartzDisplayBounds: screen.eventTapFrame,
            appKitScreenFrame: screen.appKitFrame
        )
        return CGRect(
            x: min(firstCorner.x, secondCorner.x),
            y: min(firstCorner.y, secondCorner.y),
            width: abs(secondCorner.x - firstCorner.x),
            height: abs(secondCorner.y - firstCorner.y)
        )
    }

    func accessibilityCandidatePoints(fromAppKitPoint point: CGPoint) -> [CGPoint] {
        var points = [point]
        if let screenFrame = screens.first(where: { $0.appKitFrame.contains(point) })?.appKitFrame
            ?? mainAppKitFrame {
            let converted = CGPoint(
                x: point.x,
                y: screenFrame.maxY - point.y + screenFrame.minY
            )
            if converted != point {
                points.append(converted)
            }
        }
        return points
    }

    func appKitFrame(containing point: CGPoint) -> CGRect? {
        screens.first(where: { $0.appKitFrame.contains(point) })?.appKitFrame
            ?? mainAppKitFrame
    }
}

struct DockRunningApplicationInventoryItem: Equatable, Sendable {
    let processIdentifier: pid_t
    let bundleIdentifier: String?
    let localizedName: String?
    let isHidden: Bool
    let isDockTargetCandidate: Bool

    var targetCandidate: DockRunningApplicationCandidate {
        DockRunningApplicationCandidate(
            processIdentifier: processIdentifier,
            bundleIdentifier: bundleIdentifier,
            localizedName: localizedName
        )
    }
}

struct DockApplicationInventory: Equatable, Sendable {
    let runningApplications: [DockRunningApplicationInventoryItem]

    static let empty = DockApplicationInventory(runningApplications: [])

    var dockTargetCandidates: [DockRunningApplicationCandidate] {
        runningApplications.compactMap { application in
            application.isDockTargetCandidate ? application.targetCandidate : nil
        }
    }

    func application(processIdentifier: pid_t) -> DockRunningApplicationInventoryItem? {
        runningApplications.first { $0.processIdentifier == processIdentifier }
    }
}

struct DockInteractionSystemInventory: Equatable, Sendable {
    let hasAccessibilityPermission: Bool
    let dockProcessIdentifier: pid_t?
    let screens: DockScreenInventory
    let applications: DockApplicationInventory

    static let empty = DockInteractionSystemInventory(
        hasAccessibilityPermission: true,
        dockProcessIdentifier: nil,
        screens: .empty,
        applications: .empty
    )
}

struct DockHitTestInventoryItem: Equatable {
    let target: DockAppTarget
    let appKitFrame: CGRect
    let eventTapFrame: CGRect
}

public final class DockHitTester {
    private let permissionService: PermissionService

    public init(permissionService: PermissionService) {
        self.permissionService = permissionService
    }

    public func target(at appKitPoint: CGPoint) -> DockAppTarget? {
        precondition(Thread.isMainThread, "Dock hit testing must capture AppKit state on the main thread")
        let systemInventory = captureSystemInventory()
        guard systemInventory.hasAccessibilityPermission,
              let dockProcessIdentifier = systemInventory.dockProcessIdentifier
        else {
            return nil
        }

        let dockElement = AXUIElementCreateApplication(dockProcessIdentifier)
        let candidatePoints = systemInventory.screens.accessibilityCandidatePoints(
            fromAppKitPoint: appKitPoint
        )
        let runningApps = systemInventory.applications.dockTargetCandidates

        for point in candidatePoints {
            var hitElement: AXUIElement?
            let error = AXUIElementCopyElementAtPosition(
                dockElement,
                Float(point.x),
                Float(point.y),
                &hitElement
            )
            guard error == .success, let hitElement else {
                continue
            }
            if let target = target(
                from: hitElement,
                appKitPoint: appKitPoint,
                accessibilityPoint: point,
                runningApps: runningApps,
                screens: systemInventory.screens
            ) {
                return target
            }
        }

        let dockItems = dockItemSnapshots(from: dockElement)
        for point in candidatePoints {
            if let fallback = DockTargetResolver.fallbackApplication(
                at: point,
                dockItems: dockItems,
                runningApps: runningApps
            ) {
                return makeTarget(
                    resolution: fallback.resolution,
                    dockElementTitle: fallback.item.texts.first ?? fallback.resolution.app.localizedName ?? "",
                    hitPoint: appKitPoint,
                    dockItemFrame: appKitFrame(
                        from: fallback.item.frame,
                        accessibilityPoint: point,
                        appKitPoint: appKitPoint,
                        screens: systemInventory.screens
                    )
                )
            }
        }

        return nil
    }

    func captureSystemInventory() -> DockInteractionSystemInventory {
        precondition(Thread.isMainThread, "AppKit inventory must be captured on the main thread")

        let runningApplications = NSWorkspace.shared.runningApplications.map { application in
            DockRunningApplicationInventoryItem(
                processIdentifier: application.processIdentifier,
                bundleIdentifier: application.bundleIdentifier,
                localizedName: application.localizedName,
                isHidden: application.isHidden,
                isDockTargetCandidate: application.activationPolicy == .regular
                    && application.processIdentifier != getpid()
            )
        }
        let screens = NSScreen.screens.compactMap { screen -> DockScreenInventoryItem? in
            guard let screenNumber = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber else {
                return nil
            }
            let displayIdentifier = screenNumber.uint32Value
            return DockScreenInventoryItem(
                displayIdentifier: displayIdentifier,
                appKitFrame: screen.frame,
                eventTapFrame: CGDisplayBounds(displayIdentifier)
            )
        }
        return DockInteractionSystemInventory(
            hasAccessibilityPermission: permissionService.snapshot().accessibility,
            dockProcessIdentifier: runningApplications.first {
                $0.bundleIdentifier == "com.apple.dock"
            }?.processIdentifier,
            screens: DockScreenInventory(
                screens: screens,
                mainAppKitFrame: NSScreen.main?.frame
            ),
            applications: DockApplicationInventory(runningApplications: runningApplications)
        )
    }

    func interactionInventory(
        using systemInventory: DockInteractionSystemInventory
    ) -> [DockHitTestInventoryItem] {
        guard systemInventory.hasAccessibilityPermission,
              let dockProcessIdentifier = systemInventory.dockProcessIdentifier
        else {
            return []
        }

        let dockElement = AXUIElementCreateApplication(dockProcessIdentifier)
        let runningApps = systemInventory.applications.dockTargetCandidates
        return dockItemSnapshots(from: dockElement).compactMap { item in
            guard let eventTapFrame = item.frame?.standardized,
                  eventTapFrame.width > 0,
                  eventTapFrame.height > 0,
                  let appKitFrame = systemInventory.screens.appKitFrame(
                    fromEventTapFrame: eventTapFrame
                  ),
                  let resolution = DockTargetResolver.matchingTarget(
                    for: item.texts,
                    runningApps: runningApps
                  )
            else {
                return nil
            }

            let title = item.texts.first ?? resolution.app.localizedName ?? ""
            return DockHitTestInventoryItem(
                target: makeTarget(
                    resolution: resolution,
                    dockElementTitle: title,
                    hitPoint: CGPoint(x: appKitFrame.midX, y: appKitFrame.midY),
                    dockItemFrame: appKitFrame
                ),
                appKitFrame: appKitFrame,
                eventTapFrame: eventTapFrame
            )
        }
    }

    private func target(
        from element: AXUIElement,
        appKitPoint: CGPoint,
        accessibilityPoint: CGPoint,
        runningApps: [DockRunningApplicationCandidate],
        screens: DockScreenInventory
    ) -> DockAppTarget? {
        let strings = textCandidates(from: element)
        guard !strings.isEmpty else {
            return nil
        }

        guard let match = DockTargetResolver.matchingTarget(for: strings, runningApps: runningApps) else {
            return nil
        }

        return makeTarget(
            resolution: match,
            dockElementTitle: strings.first ?? match.app.localizedName ?? "",
            hitPoint: appKitPoint,
            dockItemFrame: appKitFrame(
                from: frame(from: element),
                accessibilityPoint: accessibilityPoint,
                appKitPoint: appKitPoint,
                screens: screens
            )
        )
    }

    private func makeTarget(
        resolution: DockTargetResolution,
        dockElementTitle: String,
        hitPoint: CGPoint,
        dockItemFrame: CGRect? = nil
    ) -> DockAppTarget {
        let app = resolution.app
        return DockAppTarget(
            processIdentifier: app.processIdentifier,
            bundleIdentifier: app.bundleIdentifier,
            localizedName: app.localizedName ?? dockElementTitle,
            dockElementTitle: dockElementTitle,
            hitPoint: hitPoint,
            dockItemFrame: dockItemFrame,
            dockTileIdentifierOverride: dockTileIdentifier(
                processIdentifier: app.processIdentifier,
                title: dockElementTitle
            )
        )
    }

    private func dockTileIdentifier(
        processIdentifier: pid_t,
        title: String
    ) -> String {
        let normalizedTitle = DockTitleMatcher.normalized(title)
        return "dock-item:\(processIdentifier):\(normalizedTitle)"
    }

    private func appKitFrame(
        from accessibilityFrame: CGRect?,
        accessibilityPoint: CGPoint,
        appKitPoint: CGPoint,
        screens: DockScreenInventory
    ) -> CGRect? {
        guard let accessibilityFrame else {
            return nil
        }

        if accessibilityFrame.contains(appKitPoint) {
            return accessibilityFrame
        }

        guard accessibilityFrame.contains(accessibilityPoint),
              let screenFrame = screens.appKitFrame(containing: appKitPoint)
        else {
            return accessibilityFrame
        }

        return CGRect(
            x: accessibilityFrame.minX,
            y: screenFrame.maxY - accessibilityFrame.maxY + screenFrame.minY,
            width: accessibilityFrame.width,
            height: accessibilityFrame.height
        )
    }

    private func dockItemSnapshots(from root: AXUIElement) -> [DockItemSnapshot] {
        var snapshots: [DockItemSnapshot] = []
        collectDockItemSnapshots(from: root, depth: 0, snapshots: &snapshots)
        return snapshots
    }

    private func collectDockItemSnapshots(
        from element: AXUIElement,
        depth: Int,
        snapshots: inout [DockItemSnapshot]
    ) {
        guard depth <= 8 else {
            return
        }

        if stringAttribute(kAXRoleAttribute, from: element) == "AXDockItem" {
            let texts = textCandidates(from: element)
            if !texts.isEmpty {
                snapshots.append(DockItemSnapshot(
                    texts: texts,
                    frame: frame(from: element)
                ))
            }
        }

        for child in children(of: element) {
            collectDockItemSnapshots(from: child, depth: depth + 1, snapshots: &snapshots)
        }
    }

    private func textCandidates(from element: AXUIElement) -> [String] {
        var values: [String] = []
        let attributes = [
            kAXTitleAttribute,
            kAXDescriptionAttribute,
            kAXHelpAttribute,
            kAXValueAttribute
        ]

        for attribute in attributes {
            var rawValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue) == .success,
               let string = rawValue as? String,
               !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                values.append(string)
            }
        }

        return Array(NSOrderedSet(array: values)) as? [String] ?? values
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &rawValue) == .success,
              let children = rawValue as? [AXUIElement]
        else {
            return []
        }
        return children
    }

    private func frame(from element: AXUIElement) -> CGRect? {
        guard let position = pointAttribute(kAXPositionAttribute, from: element),
              let size = sizeAttribute(kAXSizeAttribute, from: element)
        else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    private func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue) == .success else {
            return nil
        }
        return rawValue as? String
    }

    private func pointAttribute(_ attribute: String, from element: AXUIElement) -> CGPoint? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue) == .success,
              let rawValue,
              CFGetTypeID(rawValue) == AXValueGetTypeID()
        else {
            return nil
        }
        var point = CGPoint.zero
        AXValueGetValue(rawValue as! AXValue, .cgPoint, &point)
        return point
    }

    private func sizeAttribute(_ attribute: String, from element: AXUIElement) -> CGSize? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue) == .success,
              let rawValue,
              CFGetTypeID(rawValue) == AXValueGetTypeID()
        else {
            return nil
        }
        var size = CGSize.zero
        AXValueGetValue(rawValue as! AXValue, .cgSize, &size)
        return size
    }

}

struct DockRunningApplicationCandidate: Equatable, Sendable {
    let processIdentifier: pid_t
    let bundleIdentifier: String?
    let localizedName: String?
}

struct DockTargetResolution: Equatable, Sendable {
    let app: DockRunningApplicationCandidate
}

struct DockItemSnapshot: Equatable, Sendable {
    let texts: [String]
    let frame: CGRect?
}

enum DockTargetResolver {
    static func matchingTarget(
        for texts: [String],
        runningApps: [DockRunningApplicationCandidate]
    ) -> DockTargetResolution? {
        for text in texts {
            if let match = runningApps.first(where: {
                DockTitleMatcher.matches(
                    dockTitle: text,
                    appName: $0.localizedName,
                    bundleIdentifier: $0.bundleIdentifier
                )
            }) {
                return DockTargetResolution(app: match)
            }
        }

        return nil
    }

    static func fallbackApplication(
        at point: CGPoint,
        dockItems: [DockItemSnapshot],
        runningApps: [DockRunningApplicationCandidate]
    ) -> (item: DockItemSnapshot, resolution: DockTargetResolution)? {
        for item in dockItems {
            guard item.frame?.contains(point) == true,
                  let resolution = matchingTarget(for: item.texts, runningApps: runningApps)
            else {
                continue
            }
            return (item, resolution)
        }
        return nil
    }
}

public enum DockTitleMatcher {
    public static func normalized(_ value: String?) -> String {
        guard let value else {
            return ""
        }
        let trimmed = value
            .replacingOccurrences(of: "—", with: "-")
            .replacingOccurrences(of: "–", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return trimmed
            .replacingOccurrences(of: ", running", with: "")
            .replacingOccurrences(of: " running", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func matches(dockTitle: String, appName: String?, bundleIdentifier: String?) -> Bool {
        let title = normalized(dockTitle)
        let app = normalized(appName)
        let bundleName = normalized(bundleIdentifier?.split(separator: ".").last.map(String.init))
        guard !title.isEmpty else {
            return false
        }
        return tokenSequence(app, appearsIn: title)
            || tokenSequence(bundleName, appearsIn: title)
    }

    public static func matchesWindowScope(windowTitle: String?, dockTitle: String) -> Bool {
        let window = normalized(windowTitle)
        let dock = normalized(dockTitle)
        return !window.isEmpty && !dock.isEmpty && window == dock
    }

    private static func tokenSequence(_ candidate: String, appearsIn title: String) -> Bool {
        let candidateTokens = tokens(from: candidate)
        guard !candidateTokens.isEmpty else {
            return false
        }

        let titleTokens = tokens(from: title)
        guard titleTokens.count >= candidateTokens.count else {
            return false
        }

        for startIndex in 0...(titleTokens.count - candidateTokens.count) {
            let endIndex = startIndex + candidateTokens.count
            if Array(titleTokens[startIndex..<endIndex]) == candidateTokens {
                return true
            }
        }
        return false
    }

    private static func tokens(from value: String) -> [String] {
        value.split { character in
            !character.isLetter && !character.isNumber
        }.map(String.init)
    }
}
