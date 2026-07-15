import AppKit
import CoreGraphics

public struct DockAppTarget: Equatable {
    public let processIdentifier: pid_t
    public let bundleIdentifier: String?
    public let localizedName: String
    public let dockElementTitle: String
    public let hitPoint: CGPoint
    public let dockItemFrame: CGRect?
    public let dockTileIdentifierOverride: String?
    private let dockTileIdentityProcessIdentifier: pid_t

    public var previewAnchorPoint: CGPoint {
        guard let dockItemFrame else {
            return hitPoint
        }
        return CGPoint(x: dockItemFrame.midX, y: dockItemFrame.midY)
    }

    public var dockTileIdentifier: String {
        if let dockTileIdentifierOverride {
            return dockTileIdentifierOverride
        }
        return "\(dockTileIdentityProcessIdentifier):application"
    }

    public func isSameDockTile(as other: DockAppTarget) -> Bool {
        dockTileIdentifier == other.dockTileIdentifier
    }

    public init(
        processIdentifier: pid_t,
        bundleIdentifier: String?,
        localizedName: String,
        dockElementTitle: String,
        hitPoint: CGPoint,
        dockItemFrame: CGRect? = nil,
        dockTileIdentifierOverride: String? = nil
    ) {
        self.init(
            processIdentifier: processIdentifier,
            bundleIdentifier: bundleIdentifier,
            localizedName: localizedName,
            dockElementTitle: dockElementTitle,
            hitPoint: hitPoint,
            dockItemFrame: dockItemFrame,
            dockTileIdentifierOverride: dockTileIdentifierOverride,
            dockTileIdentityProcessIdentifier: processIdentifier
        )
    }

    private init(
        processIdentifier: pid_t,
        bundleIdentifier: String?,
        localizedName: String,
        dockElementTitle: String,
        hitPoint: CGPoint,
        dockItemFrame: CGRect?,
        dockTileIdentifierOverride: String?,
        dockTileIdentityProcessIdentifier: pid_t
    ) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.localizedName = localizedName
        self.dockElementTitle = dockElementTitle
        self.hitPoint = hitPoint
        self.dockItemFrame = dockItemFrame
        self.dockTileIdentifierOverride = dockTileIdentifierOverride
        self.dockTileIdentityProcessIdentifier = dockTileIdentityProcessIdentifier
    }

    public func proxying(
        to processIdentifier: pid_t,
        bundleIdentifier: String?,
        localizedName: String?
    ) -> DockAppTarget {
        DockAppTarget(
            processIdentifier: processIdentifier,
            bundleIdentifier: bundleIdentifier,
            localizedName: localizedName ?? self.localizedName,
            dockElementTitle: dockElementTitle,
            hitPoint: hitPoint,
            dockItemFrame: dockItemFrame,
            dockTileIdentifierOverride: dockTileIdentifierOverride,
            dockTileIdentityProcessIdentifier: dockTileIdentityProcessIdentifier
        )
    }
}
