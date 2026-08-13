import Foundation

struct EventTapRecoveryPolicy {
    static let defaultDelays: [TimeInterval] = [0, 0.5, 2]
    static let stableRunDuration: TimeInterval = 5

    private(set) var attempt = 0
    private(set) var lastEnabledAt: TimeInterval?

    mutating func didEnable(at timestamp: TimeInterval) {
        lastEnabledAt = timestamp
    }

    mutating func nextDelay(afterFailureAt timestamp: TimeInterval) -> TimeInterval? {
        if let lastEnabledAt,
           timestamp - lastEnabledAt >= Self.stableRunDuration {
            attempt = 0
        }
        guard attempt < Self.defaultDelays.count else {
            return nil
        }
        defer { attempt += 1 }
        return Self.defaultDelays[attempt]
    }

    mutating func reset() {
        attempt = 0
        lastEnabledAt = nil
    }
}
