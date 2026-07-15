import Foundation

enum PreviewContentSource: Equatable {
    case capture
    case cachedImage
    case textOnly
    case unavailable
}

enum PreviewContentSourcePolicy {
    static func source(
        hasCachedImage: Bool,
        isMinimized: Bool,
        hasCaptureWindow: Bool
    ) -> PreviewContentSource {
        if hasCachedImage {
            return .cachedImage
        }
        if isMinimized {
            return .textOnly
        }
        return hasCaptureWindow ? .capture : .unavailable
    }
}

enum PreviewContentReadinessState: Equatable {
    case waiting(deadline: Date)
    case ready
    case textOnly
    case unavailable
}

enum PreviewContentFrameAcceptance: Equatable {
    case becameReady
    case updatedReady
    case rejected
}

struct PreviewContentReadinessTracker {
    private var states: [PreviewWindowIdentity: PreviewContentReadinessState] = [:]
    private var sources: [PreviewWindowIdentity: PreviewContentSource] = [:]

    var displayableIdentities: Set<PreviewWindowIdentity> {
        Set(states.compactMap { identity, state in
            switch state {
            case .ready, .textOnly:
                return identity
            case .waiting, .unavailable:
                return nil
            }
        })
    }

    var captureEligibleIdentities: Set<PreviewWindowIdentity> {
        Set(states.compactMap { identity, state in
            guard sources[identity] == .capture else {
                return nil
            }
            switch state {
            case .waiting, .ready:
                return identity
            case .textOnly, .unavailable:
                return nil
            }
        })
    }

    var hasWaitingContent: Bool {
        nextWaitingDeadline != nil
    }

    var nextWaitingDeadline: Date? {
        states.values.compactMap { state in
            guard case let .waiting(deadline) = state else {
                return nil
            }
            return deadline
        }.min()
    }

    mutating func reset() {
        states.removeAll()
        sources.removeAll()
    }

    mutating func synchronize(
        sources newSources: [PreviewWindowIdentity: PreviewContentSource],
        now: Date,
        timeout: TimeInterval
    ) {
        var nextStates: [PreviewWindowIdentity: PreviewContentReadinessState] = [:]
        var nextSources: [PreviewWindowIdentity: PreviewContentSource] = [:]

        for (identity, source) in newSources {
            let existingState = states[identity]
            switch source {
            case .capture:
                nextSources[identity] = .capture
                switch existingState {
                case .waiting, .ready, .unavailable:
                    nextStates[identity] = existingState
                case .textOnly, nil:
                    nextStates[identity] = .waiting(
                        deadline: now.addingTimeInterval(max(0, timeout))
                    )
                }
            case .cachedImage:
                nextSources[identity] = .cachedImage
                nextStates[identity] = .ready
            case .textOnly:
                nextSources[identity] = .textOnly
                nextStates[identity] = .textOnly
            case .unavailable:
                if sources[identity] == .capture,
                   existingState == .ready || isWaiting(existingState) {
                    nextSources[identity] = .capture
                    nextStates[identity] = existingState
                } else {
                    nextSources[identity] = .unavailable
                    nextStates[identity] = existingState == .ready ? .ready : .unavailable
                }
            }
        }

        states = nextStates
        sources = nextSources
    }

    func state(for identity: PreviewWindowIdentity) -> PreviewContentReadinessState? {
        states[identity]
    }

    mutating func acceptFrame(for identity: PreviewWindowIdentity) -> PreviewContentFrameAcceptance {
        guard sources[identity] == .capture else {
            return .rejected
        }

        switch states[identity] {
        case .waiting:
            states[identity] = .ready
            return .becameReady
        case .ready:
            return .updatedReady
        case .textOnly, .unavailable, nil:
            return .rejected
        }
    }

    @discardableResult
    mutating func markUnavailable(_ identity: PreviewWindowIdentity) -> Bool {
        guard case .waiting = states[identity] else {
            return false
        }
        states[identity] = .unavailable
        return true
    }

    mutating func expireWaiting(at date: Date) -> Set<PreviewWindowIdentity> {
        let expired: Set<PreviewWindowIdentity> = Set(states.compactMap { identity, state -> PreviewWindowIdentity? in
            guard case let .waiting(deadline) = state, deadline <= date else {
                return nil
            }
            return identity
        })
        for identity in expired {
            states[identity] = .unavailable
        }
        return expired
    }

    mutating func remove(_ identity: PreviewWindowIdentity) {
        states[identity] = nil
        sources[identity] = nil
    }

    private func isWaiting(_ state: PreviewContentReadinessState?) -> Bool {
        guard case .waiting = state else {
            return false
        }
        return true
    }
}

enum PreviewContentGenerationPolicy {
    static func accepts(
        responseGeneration: Int,
        currentGeneration: Int,
        isIdentityTracked: Bool
    ) -> Bool {
        responseGeneration == currentGeneration && isIdentityTracked
    }
}

enum PreviewCaptureAvailabilityPolicy {
    static func identities(
        currentCaptureIdentities: Set<PreviewWindowIdentity>,
        registeredIdentities: Set<PreviewWindowIdentity>,
        contentEligibleIdentities: Set<PreviewWindowIdentity>
    ) -> Set<PreviewWindowIdentity> {
        currentCaptureIdentities
            .union(registeredIdentities)
            .intersection(contentEligibleIdentities)
    }
}

enum PreviewContentTimeoutPolicy {
    static func timeout(
        operatingSystemMajorVersion: Int,
        prefersReducedLoad: Bool
    ) -> TimeInterval {
        operatingSystemMajorVersion <= 13 || prefersReducedLoad ? 1.5 : 1.0
    }

    static var current: TimeInterval {
        timeout(
            operatingSystemMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
            prefersReducedLoad: PreviewPowerState.current.prefersReducedPreviewLoad
        )
    }
}
