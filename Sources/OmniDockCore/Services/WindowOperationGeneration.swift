import Darwin

enum WindowOperationIntent: Equatable {
    case bring
    case hide
    case minimize
    case focus
    case open
    case close
}

struct WindowOperationToken: Equatable {
    let processIdentifier: pid_t
    let generation: UInt64
    let foregroundGeneration: UInt64
    let intent: WindowOperationIntent
}

struct PendingWindowHideToken: Equatable {
    let identifier: UInt64
    let operationToken: WindowOperationToken
}

struct WindowForegroundOperationReservation: Equatable {
    let generation: UInt64
    let frontmostProcessIdentifier: pid_t?
}

final class WindowOperationGenerationTracker {
    private var generations: [pid_t: UInt64] = [:]
    private var foregroundGeneration: UInt64 = 0
    private var nextPendingHideIdentifier: UInt64 = 0
    private var pendingHides: [UInt64: PendingWindowHideToken] = [:]
    private var pendingHideIdentifiers: [pid_t: UInt64] = [:]

    func begin(_ intent: WindowOperationIntent, for processIdentifier: pid_t) -> WindowOperationToken {
        cancelPendingHide(for: processIdentifier)
        let generation = (generations[processIdentifier] ?? 0) &+ 1
        generations[processIdentifier] = generation
        foregroundGeneration &+= 1
        return WindowOperationToken(
            processIdentifier: processIdentifier,
            generation: generation,
            foregroundGeneration: foregroundGeneration,
            intent: intent
        )
    }

    func reserveForegroundOperation(
        frontmostProcessIdentifier: pid_t?
    ) -> WindowForegroundOperationReservation {
        foregroundGeneration &+= 1
        return WindowForegroundOperationReservation(
            generation: foregroundGeneration,
            frontmostProcessIdentifier: frontmostProcessIdentifier
        )
    }

    func begin(
        _ intent: WindowOperationIntent,
        for processIdentifier: pid_t,
        reservation: WindowForegroundOperationReservation,
        currentFrontmostProcessIdentifier: pid_t?
    ) -> WindowOperationToken? {
        guard reservation.generation == foregroundGeneration,
              currentFrontmostProcessIdentifier == reservation.frontmostProcessIdentifier
                || currentFrontmostProcessIdentifier == processIdentifier
        else {
            return nil
        }

        cancelPendingHide(for: processIdentifier)
        let generation = (generations[processIdentifier] ?? 0) &+ 1
        generations[processIdentifier] = generation
        return WindowOperationToken(
            processIdentifier: processIdentifier,
            generation: generation,
            foregroundGeneration: reservation.generation,
            intent: intent
        )
    }

    func beginPendingHide(for processIdentifier: pid_t) -> PendingWindowHideToken {
        let operationToken = begin(.hide, for: processIdentifier)
        nextPendingHideIdentifier &+= 1
        let token = PendingWindowHideToken(
            identifier: nextPendingHideIdentifier,
            operationToken: operationToken
        )
        pendingHides[token.identifier] = token
        pendingHideIdentifiers[processIdentifier] = token.identifier
        return token
    }

    func hasPendingHide(for processIdentifier: pid_t) -> Bool {
        pendingHideIdentifiers[processIdentifier] != nil
    }

    @discardableResult
    func consumePendingHide(_ token: PendingWindowHideToken) -> Bool {
        guard pendingHides[token.identifier] == token,
              isForegroundCurrent(token.operationToken)
        else {
            removePendingHide(identifier: token.identifier)
            return false
        }

        removePendingHide(identifier: token.identifier)
        return true
    }

    func isCurrent(_ token: WindowOperationToken) -> Bool {
        generations[token.processIdentifier] == token.generation
    }

    func isForegroundCurrent(_ token: WindowOperationToken) -> Bool {
        isCurrent(token) && token.foregroundGeneration == foregroundGeneration
    }

    func isForegroundCurrent(
        _ token: WindowOperationToken,
        currentFrontmostProcessIdentifier: pid_t?
    ) -> Bool {
        isForegroundCurrent(token)
            && currentFrontmostProcessIdentifier == token.processIdentifier
    }

    private func cancelPendingHide(for processIdentifier: pid_t) {
        guard let identifier = pendingHideIdentifiers[processIdentifier] else {
            return
        }
        removePendingHide(identifier: identifier)
    }

    private func removePendingHide(identifier: UInt64) {
        guard let token = pendingHides.removeValue(forKey: identifier) else {
            return
        }
        let processIdentifier = token.operationToken.processIdentifier
        if pendingHideIdentifiers[processIdentifier] == identifier {
            pendingHideIdentifiers.removeValue(forKey: processIdentifier)
        }
    }
}
