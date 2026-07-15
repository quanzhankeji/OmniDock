import CoreGraphics
import ScreenCaptureKit

enum PreviewWindowIdentity: Hashable {
    case window(processIdentifier: pid_t, windowID: CGWindowID)
    case transient(processIdentifier: pid_t, identifier: String)

    init(_ window: PreviewWindowInfo) {
        if let windowID = window.windowID {
            self = .window(
                processIdentifier: window.processIdentifier,
                windowID: windowID
            )
        } else {
            self = .transient(
                processIdentifier: window.processIdentifier,
                identifier: window.id
            )
        }
    }

    var windowID: CGWindowID? {
        guard case let .window(_, windowID) = self else {
            return nil
        }
        return windowID
    }
}

struct PreviewWindowPresentation: Hashable {
    let identity: PreviewWindowIdentity
    let title: String
    let frame: WindowFrameKey
    let isMinimized: Bool

    init(_ window: PreviewWindowInfo) {
        identity = PreviewWindowIdentity(window)
        title = window.title
        frame = WindowFrameKey(window.frame)
        isMinimized = window.isMinimized
    }
}

final class PreviewWindowSnapshot {
    let windows: [PreviewWindowInfo]
    let captureWindows: [PreviewWindowIdentity: SCWindow]
    let message: String?

    init(
        windows: [PreviewWindowInfo],
        captureWindows: [PreviewWindowIdentity: SCWindow],
        message: String? = nil
    ) {
        self.windows = windows
        self.captureWindows = captureWindows
        self.message = message
    }

    var identities: Set<PreviewWindowIdentity> {
        Set(windows.map(PreviewWindowIdentity.init))
    }

    var orderedIdentities: [PreviewWindowIdentity] {
        windows.map(PreviewWindowIdentity.init)
    }

    var presentations: [PreviewWindowPresentation] {
        windows.map(PreviewWindowPresentation.init)
    }

    func removing(_ identity: PreviewWindowIdentity) -> PreviewWindowSnapshot {
        PreviewWindowSnapshot(
            windows: windows.filter { PreviewWindowIdentity($0) != identity },
            captureWindows: captureWindows.filter { $0.key != identity },
            message: message
        )
    }
}

enum PreviewWindowSnapshotDecision: Equatable {
    case unchanged
    case pending
    case apply
}

struct PreviewWindowSnapshotStabilizer {
    private(set) var acceptedIdentities: Set<PreviewWindowIdentity>?
    private var pendingIdentities: Set<PreviewWindowIdentity>?
    private var pendingConfirmationCount = 0

    mutating func reset(acceptedIdentities: Set<PreviewWindowIdentity>? = nil) {
        self.acceptedIdentities = acceptedIdentities
        pendingIdentities = nil
        pendingConfirmationCount = 0
    }

    mutating func evaluate(
        _ identities: Set<PreviewWindowIdentity>,
        requiredConfirmationCount: Int = 2
    ) -> PreviewWindowSnapshotDecision {
        guard let acceptedIdentities else {
            self.acceptedIdentities = identities
            pendingIdentities = nil
            pendingConfirmationCount = 0
            return .apply
        }

        guard identities != acceptedIdentities else {
            pendingIdentities = nil
            pendingConfirmationCount = 0
            return .unchanged
        }

        if pendingIdentities == identities {
            pendingConfirmationCount += 1
        } else {
            pendingIdentities = identities
            pendingConfirmationCount = 1
        }

        guard pendingConfirmationCount >= max(1, requiredConfirmationCount) else {
            return .pending
        }

        self.acceptedIdentities = identities
        pendingIdentities = nil
        pendingConfirmationCount = 0
        return .apply
    }
}
