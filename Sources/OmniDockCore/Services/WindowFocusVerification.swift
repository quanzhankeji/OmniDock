import Foundation

public enum WindowFocusResult: Equatable {
    case focused
    case unavailable
    case unconfirmed
    case superseded
}

enum WindowFocusState {
    case focused
    case unfocused
    case unreadable
    case unavailable
}

struct WindowFocusObservation {
    let applicationIsCurrent: Bool
    let querySucceeded: Bool
    let targetIsPresent: Bool
    let targetIsMinimized: Bool?
    let isFrontmost: Bool
    let focusedWindowMatches: Bool

    var state: WindowFocusState {
        guard applicationIsCurrent else { return .unavailable }
        guard querySucceeded else { return .unreadable }
        guard targetIsPresent else { return .unavailable }
        return isFrontmost && focusedWindowMatches && targetIsMinimized == false
            ? .focused : .unfocused
    }
}

final class WindowFocusAttempt {
    private let isCurrent: () -> Bool
    private let observe: () -> WindowFocusState
    private let raise: () -> Void
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private let completion: (WindowFocusResult) -> Void
    private var attemptsRemaining = 3
    private var didFinish = false

    init(
        isCurrent: @escaping () -> Bool,
        observe: @escaping () -> WindowFocusState,
        raise: @escaping () -> Void,
        schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        },
        completion: @escaping (WindowFocusResult) -> Void
    ) {
        self.isCurrent = isCurrent
        self.observe = observe
        self.raise = raise
        self.schedule = schedule
        self.completion = completion
    }

    func start(after delay: TimeInterval = 0) {
        if delay > 0 {
            schedule(delay) { self.step() }
        } else {
            step()
        }
    }

    private func step() {
        guard !didFinish else { return }
        guard isCurrent() else { return finish(.superseded) }
        let state = observe()
        guard isCurrent() else { return finish(.superseded) }
        switch state {
        case .focused:
            finish(.focused)
        case .unavailable:
            finish(.unavailable)
        case .unfocused, .unreadable:
            guard attemptsRemaining > 0 else { return finish(.unconfirmed) }
            attemptsRemaining -= 1
            if state == .unfocused {
                raise()
            }
            // A successful AX action is only a request; confirm on a later turn.
            schedule(0.08) { self.step() }
        }
    }

    private func finish(_ result: WindowFocusResult) {
        didFinish = true
        completion(result)
    }
}
