import CoreGraphics
import Foundation

final class PreviewCaptureRequestRegistry<Session> {
    final class Request {
        let token = UUID()
        fileprivate let processIdentifier: pid_t
        fileprivate var sessions: [Session] = []
        fileprivate var completion: (() -> Void)?

        fileprivate init(processIdentifier: pid_t, completion: @escaping () -> Void) {
            self.processIdentifier = processIdentifier
            self.completion = completion
        }
    }

    private var currentRequests: [pid_t: Request] = [:]
    private let stopSession: (Session) -> Void

    init(stopSession: @escaping (Session) -> Void) {
        self.stopSession = stopSession
    }

    @discardableResult
    func begin(processIdentifier: pid_t, completion: @escaping () -> Void) -> Request {
        let request = Request(processIdentifier: processIdentifier, completion: completion)
        let supersededRequest = currentRequests.updateValue(request, forKey: processIdentifier)
        if let supersededRequest {
            retire(supersededRequest)
        }
        return request
    }

    func isCurrent(_ request: Request) -> Bool {
        guard let currentRequest = currentRequests[request.processIdentifier] else {
            return false
        }
        return currentRequest === request
            && currentRequest.token == request.token
            && request.completion != nil
    }

    @discardableResult
    func install(_ sessions: [Session], for request: Request) -> Bool {
        guard isCurrent(request) else {
            sessions.forEach(stopSession)
            return false
        }

        let replacedSessions = request.sessions
        request.sessions = sessions
        replacedSessions.forEach(stopSession)
        return true
    }

    @discardableResult
    func finish(_ request: Request) -> Bool {
        guard isCurrent(request) else {
            return false
        }

        currentRequests[request.processIdentifier] = nil
        retire(request)
        return true
    }

    func clear(processIdentifier: pid_t) {
        guard let request = currentRequests.removeValue(forKey: processIdentifier) else {
            return
        }
        retire(request)
    }

    func clearAll() {
        let requests = Array(currentRequests.values)
        currentRequests.removeAll()
        requests.forEach(retire)
    }

    private func retire(_ request: Request) {
        let sessions = request.sessions
        request.sessions = []
        let completion = request.completion
        request.completion = nil

        sessions.forEach(stopSession)
        completion?()
    }
}

protocol PreviewCaptureSession: AnyObject {
    func stop()
    func update(policy: PreviewCapturePolicy)
    func update(policy: PreviewCapturePolicy, sourceSize: CGSize)
}

final class PreviewCaptureStartLimiter {
    struct Token: Hashable {
        fileprivate let identifier = UUID()
    }

    private struct Request {
        let token: Token
        let start: (Token) -> Void
    }

    private let maximumConcurrentStarts: Int
    private let lock = NSLock()
    private var activeTokens = Set<Token>()
    private var pendingRequests: [Request] = []

    init(maximumConcurrentStarts: Int) {
        precondition(maximumConcurrentStarts > 0)
        self.maximumConcurrentStarts = maximumConcurrentStarts
    }

    @discardableResult
    func enqueue(_ start: @escaping (Token) -> Void) -> Token {
        let request = Request(token: Token(), start: start)
        var shouldStart = false

        lock.lock()
        if activeTokens.count < maximumConcurrentStarts {
            activeTokens.insert(request.token)
            shouldStart = true
        } else {
            pendingRequests.append(request)
        }
        lock.unlock()

        if shouldStart {
            request.start(request.token)
        }
        return request.token
    }

    func cancel(_ token: Token) {
        release(token)
    }

    @discardableResult
    func cancelQueued(_ token: Token) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let index = pendingRequests.firstIndex(where: { $0.token == token }) else {
            return false
        }
        pendingRequests.remove(at: index)
        return true
    }

    func finish(_ token: Token) {
        release(token)
    }

    func finish(
        _ token: Token,
        after asynchronousStop: (@escaping () -> Void) -> Void
    ) {
        asynchronousStop { [weak self] in
            self?.release(token)
        }
    }

    private func release(_ token: Token) {
        var nextRequest: Request?

        lock.lock()
        if activeTokens.remove(token) != nil {
            if !pendingRequests.isEmpty {
                nextRequest = pendingRequests.removeFirst()
                activeTokens.insert(nextRequest!.token)
            }
        } else if let index = pendingRequests.firstIndex(where: { $0.token == token }) {
            pendingRequests.remove(at: index)
        }
        lock.unlock()

        if let nextRequest {
            nextRequest.start(nextRequest.token)
        }
    }
}

extension PreviewCaptureSession {
    func update(policy: PreviewCapturePolicy) {}

    func update(policy: PreviewCapturePolicy, sourceSize: CGSize) {
        update(policy: policy)
    }
}

enum PreviewCaptureCandidatePolicy {
    static func identities(
        for windows: [PreviewWindowInfo],
        availableIdentities: Set<PreviewWindowIdentity>,
        maximumCount: Int
    ) -> [PreviewWindowIdentity] {
        Array(
            windows
                .map(PreviewWindowIdentity.init)
                .filter(availableIdentities.contains)
                .prefix(max(0, maximumCount))
        )
    }
}

struct PreviewCaptureStreamLifecycle<StreamIdentifier: Equatable> {
    typealias Generation = UInt64

    private(set) var generation: Generation = 0
    private(set) var currentStreamIdentifier: StreamIdentifier?
    private(set) var isRunning = false
    private(set) var didDeliverFirstFrame = false
    private var acceptsFrames = false
    private var didAttemptFallback = false
    private var hasPendingTerminalDelivery = false

    var isTerminal: Bool {
        hasPendingTerminalDelivery
    }

    mutating func begin(streamIdentifier: StreamIdentifier) -> Generation {
        generation &+= 1
        currentStreamIdentifier = streamIdentifier
        isRunning = false
        didDeliverFirstFrame = false
        acceptsFrames = true
        didAttemptFallback = false
        hasPendingTerminalDelivery = false
        return generation
    }

    func isCurrent(generation: Generation, streamIdentifier: StreamIdentifier) -> Bool {
        self.generation == generation && currentStreamIdentifier == streamIdentifier
    }

    func frameGeneration(for streamIdentifier: StreamIdentifier) -> Generation? {
        guard currentStreamIdentifier == streamIdentifier,
              acceptsFrames,
              !hasPendingTerminalDelivery
        else {
            return nil
        }
        return generation
    }

    @discardableResult
    mutating func markRunning(generation: Generation, streamIdentifier: StreamIdentifier) -> Bool {
        guard isCurrent(generation: generation, streamIdentifier: streamIdentifier),
              !hasPendingTerminalDelivery
        else {
            return false
        }
        isRunning = true
        return true
    }

    mutating func acceptFrame(
        generation: Generation,
        streamIdentifier: StreamIdentifier,
        continuesAfterFirstFrame: Bool
    ) -> Bool {
        guard isCurrent(generation: generation, streamIdentifier: streamIdentifier),
              acceptsFrames,
              !hasPendingTerminalDelivery,
              continuesAfterFirstFrame || !didDeliverFirstFrame
        else {
            return false
        }

        didDeliverFirstFrame = true
        if !continuesAfterFirstFrame {
            acceptsFrames = false
            hasPendingTerminalDelivery = true
        }
        return true
    }

    func canStartFallback(generation: Generation, streamIdentifier: StreamIdentifier) -> Bool {
        isCurrent(generation: generation, streamIdentifier: streamIdentifier)
            && isRunning
            && !didDeliverFirstFrame
            && !didAttemptFallback
            && !hasPendingTerminalDelivery
    }

    mutating func beginFallback(generation: Generation, streamIdentifier: StreamIdentifier) -> Bool {
        guard canStartFallback(generation: generation, streamIdentifier: streamIdentifier) else {
            return false
        }
        didAttemptFallback = true
        return true
    }

    mutating func acceptFallback(
        generation: Generation,
        streamIdentifier: StreamIdentifier,
        continuesAfterFirstFrame: Bool
    ) -> Bool {
        guard isCurrent(generation: generation, streamIdentifier: streamIdentifier),
              didAttemptFallback,
              !didDeliverFirstFrame,
              !hasPendingTerminalDelivery
        else {
            return false
        }

        guard !continuesAfterFirstFrame else {
            return true
        }

        didDeliverFirstFrame = true
        acceptsFrames = false
        hasPendingTerminalDelivery = true
        return true
    }

    mutating func acceptFallbackError(
        generation: Generation,
        streamIdentifier: StreamIdentifier,
        continuesAfterFirstFrame: Bool
    ) -> Bool {
        guard isCurrent(generation: generation, streamIdentifier: streamIdentifier),
              didAttemptFallback,
              !didDeliverFirstFrame,
              !hasPendingTerminalDelivery
        else {
            return false
        }

        guard !continuesAfterFirstFrame else {
            return true
        }

        isRunning = false
        acceptsFrames = false
        hasPendingTerminalDelivery = true
        return true
    }

    mutating func acceptError(generation: Generation, streamIdentifier: StreamIdentifier) -> Bool {
        guard isCurrent(generation: generation, streamIdentifier: streamIdentifier),
              !hasPendingTerminalDelivery
        else {
            return false
        }
        isRunning = false
        acceptsFrames = false
        hasPendingTerminalDelivery = true
        return true
    }

    mutating func invalidate() {
        generation &+= 1
        currentStreamIdentifier = nil
        isRunning = false
        didDeliverFirstFrame = false
        acceptsFrames = false
        didAttemptFallback = false
        hasPendingTerminalDelivery = false
    }
}
