import XCTest
@testable import OmniDockCore

final class PreviewCaptureSessionRegistryTests: XCTestCase {
    func testUnchangedAndReorderedIdentitiesReuseExistingSessions() {
        let registry = PreviewCaptureSessionRegistry()
        let factory = SessionFactory()
        let first = identity(1)
        let second = identity(2)
        let policy = capturePolicy(liveCount: 2)

        registry.reconcile(
            orderedIdentities: [first, second],
            availableIdentities: [first, second],
            policy: policy,
            startSession: factory.start
        )
        let result = registry.reconcile(
            orderedIdentities: [second, first],
            availableIdentities: [first, second],
            policy: policy,
            startSession: factory.start
        )

        XCTAssertEqual(factory.startCount, 2)
        XCTAssertEqual(factory.stopCount, 0)
        XCTAssertEqual(result.retained, [first, second])
        XCTAssertTrue(result.started.isEmpty)
        XCTAssertTrue(result.stopped.isEmpty)
    }

    func testStableAdditionStartsOnlyTheNewSession() {
        let registry = PreviewCaptureSessionRegistry()
        let factory = SessionFactory()
        let first = identity(1)
        let second = identity(2)

        registry.reconcile(
            orderedIdentities: [first],
            availableIdentities: [first],
            policy: capturePolicy(liveCount: 2),
            startSession: factory.start
        )
        let result = registry.reconcile(
            orderedIdentities: [first, second],
            availableIdentities: [first, second],
            policy: capturePolicy(liveCount: 2),
            startSession: factory.start
        )

        XCTAssertEqual(factory.startCount, 2)
        XCTAssertEqual(factory.stopCount, 0)
        XCTAssertEqual(result.retained, [first])
        XCTAssertEqual(result.started, [second])
    }

    func testStableRemovalStopsOnlyTheRemovedSession() {
        let registry = PreviewCaptureSessionRegistry()
        let factory = SessionFactory()
        let first = identity(1)
        let second = identity(2)
        let policy = capturePolicy(liveCount: 2)

        registry.reconcile(
            orderedIdentities: [first, second],
            availableIdentities: [first, second],
            policy: policy,
            startSession: factory.start
        )
        let result = registry.reconcile(
            orderedIdentities: [first],
            availableIdentities: [first],
            policy: policy,
            startSession: factory.start
        )

        XCTAssertEqual(factory.startCount, 2)
        XCTAssertEqual(factory.stopCount, 1)
        XCTAssertEqual(result.retained, [first])
        XCTAssertEqual(result.stopped, [second])
    }

    func testPolicyChangeUpdatesLiveSessionWithoutRestartingIt() {
        let registry = PreviewCaptureSessionRegistry()
        let factory = SessionFactory()
        let first = identity(1)

        registry.reconcile(
            orderedIdentities: [first],
            availableIdentities: [first],
            policy: capturePolicy(liveCount: 1, framesPerSecond: 8),
            startSession: factory.start
        )
        registry.reconcile(
            orderedIdentities: [first],
            availableIdentities: [first],
            policy: capturePolicy(liveCount: 1, framesPerSecond: 4),
            startSession: factory.start
        )

        XCTAssertEqual(factory.startCount, 1)
        XCTAssertEqual(factory.stopCount, 0)
        XCTAssertEqual(factory.sessions[first]?.updateCount, 1)
    }

    func testSourceSizeChangeUpdatesSessionWithoutRestartingIt() {
        let registry = PreviewCaptureSessionRegistry()
        let factory = SessionFactory()
        let first = identity(1)
        let policy = capturePolicy(liveCount: 1)

        registry.reconcile(
            orderedIdentities: [first],
            availableIdentities: [first],
            sourceSizes: [first: CGSize(width: 800, height: 600)],
            policy: policy,
            startSession: factory.start
        )
        registry.reconcile(
            orderedIdentities: [first],
            availableIdentities: [first],
            sourceSizes: [first: CGSize(width: 1_200, height: 700)],
            policy: policy,
            startSession: factory.start
        )

        XCTAssertEqual(factory.startCount, 1)
        XCTAssertEqual(factory.stopCount, 0)
        XCTAssertEqual(factory.sessions[first]?.updateCount, 1)
    }

    func testOneThousandTransientSnapshotChangesDoNotRestartSessions() {
        let registry = PreviewCaptureSessionRegistry()
        let factory = SessionFactory()
        let stableIdentity = identity(1)
        let stableSet: Set<PreviewWindowIdentity> = [stableIdentity]
        let policy = capturePolicy(liveCount: 1)
        var stabilizer = PreviewWindowSnapshotStabilizer()
        stabilizer.reset(acceptedIdentities: stableSet)

        registry.reconcile(
            orderedIdentities: [stableIdentity],
            availableIdentities: stableSet,
            policy: policy,
            startSession: factory.start
        )

        for index in 0..<1_000 {
            let transient: Set<PreviewWindowIdentity> = [stableIdentity, identity(CGWindowID(index + 100))]
            XCTAssertEqual(stabilizer.evaluate(transient), .pending)
            XCTAssertEqual(stabilizer.evaluate(stableSet), .unchanged)
            registry.reconcile(
                orderedIdentities: [stableIdentity],
                availableIdentities: stableSet,
                policy: policy,
                startSession: factory.start
            )
        }

        XCTAssertEqual(factory.startCount, 1)
        XCTAssertEqual(factory.stopCount, 0)
    }

    func testTerminatedLiveSessionIsRemovedAndRestartWaitsForFallbackCompletion() throws {
        let registry = PreviewCaptureSessionRegistry()
        let factory = TerminationSessionFactory()
        let first = identity(1)
        let policy = capturePolicy(liveCount: 1)
        var terminations: [PreviewCaptureSessionTermination] = []

        registry.reconcile(
            orderedIdentities: [first],
            availableIdentities: [first],
            policy: policy,
            onSessionTermination: { _, _, termination in
                terminations.append(termination)
            },
            startSession: factory.start
        )
        let failedSession = try XCTUnwrap(factory.latestSession(for: first))

        failedSession.send(.streamStopped)
        XCTAssertFalse(registry.identities.contains(first))

        registry.reconcile(
            orderedIdentities: [first],
            availableIdentities: [first],
            policy: policy,
            startSession: factory.start
        )
        XCTAssertEqual(factory.startCount, 1)

        failedSession.send(.finished(PreviewCaptureSessionTermination(message: "stopped")))
        XCTAssertEqual(terminations, [PreviewCaptureSessionTermination(message: "stopped")])

        registry.reconcile(
            orderedIdentities: [first],
            availableIdentities: [first],
            policy: policy,
            startSession: factory.start
        )
        XCTAssertEqual(factory.startCount, 2)

        failedSession.send(.finished(PreviewCaptureSessionTermination(message: "late")))
        XCTAssertTrue(registry.identities.contains(first))
        XCTAssertEqual(factory.stopCount, 0)
    }

    func testFinishedEventRemovesActiveSessionAndCannotRemoveReplacement() throws {
        let registry = PreviewCaptureSessionRegistry()
        let factory = TerminationSessionFactory()
        let first = identity(1)
        let policy = capturePolicy(liveCount: 1)
        var terminations: [PreviewCaptureSessionTermination] = []

        registry.reconcile(
            orderedIdentities: [first],
            availableIdentities: [first],
            policy: policy,
            onSessionTermination: { _, _, termination in
                terminations.append(termination)
            },
            startSession: factory.start
        )
        let failedSession = try XCTUnwrap(factory.latestSession(for: first))

        failedSession.send(.finished(PreviewCaptureSessionTermination(message: "stopped")))

        XCTAssertFalse(registry.identities.contains(first))
        XCTAssertEqual(terminations, [PreviewCaptureSessionTermination(message: "stopped")])

        registry.reconcile(
            orderedIdentities: [first],
            availableIdentities: [first],
            policy: policy,
            startSession: factory.start
        )
        XCTAssertEqual(factory.startCount, 2)

        failedSession.send(.streamStopped)
        XCTAssertTrue(registry.identities.contains(first))
    }

    func testForcedStaticIdentityDoesNotBackfillItsLiveSlotOrChurnSessions() {
        let registry = PreviewCaptureSessionRegistry()
        let factory = TerminationSessionFactory()
        let first = identity(1)
        let second = identity(2)
        let policy = capturePolicy(liveCount: 2)

        registry.reconcile(
            orderedIdentities: [first, second],
            availableIdentities: [first, second],
            policy: policy,
            forcedStaticIdentities: [first],
            startSession: factory.start
        )
        registry.reconcile(
            orderedIdentities: [first, second],
            availableIdentities: [first, second],
            policy: policy,
            forcedStaticIdentities: [first],
            startSession: factory.start
        )

        XCTAssertEqual(factory.startCount, 2)
        XCTAssertEqual(factory.startedModes[first], [.staticImage])
        XCTAssertEqual(factory.startedModes[second], [.live])
        XCTAssertEqual(registry.liveIdentities, [second])
        XCTAssertEqual(factory.stopCount, 0)
    }

    private func identity(_ windowID: CGWindowID) -> PreviewWindowIdentity {
        .window(processIdentifier: 42, windowID: windowID)
    }

    private func capturePolicy(
        liveCount: Int,
        framesPerSecond: Int = 8
    ) -> PreviewCapturePolicy {
        PreviewCapturePolicy(
            maxVisibleWindows: 24,
            maxStreamCount: liveCount,
            maxStaticSnapshotCount: 0,
            framesPerSecond: framesPerSecond,
            maxThumbnailPixelSize: CGSize(width: 440, height: 300),
            minimumThumbnailPixelSize: CGSize(width: 160, height: 100),
            queueDepth: 3,
            continuesAfterFirstFrame: liveCount > 0
        )
    }

    private final class SessionFactory {
        private(set) var sessions: [PreviewWindowIdentity: FakeSession] = [:]
        private(set) var startCount = 0

        var stopCount: Int {
            sessions.values.reduce(0) { $0 + $1.stopCount }
        }

        func start(
            identity: PreviewWindowIdentity,
            mode: PreviewCaptureMode,
            policy: PreviewCapturePolicy
        ) -> (any PreviewCaptureSession)? {
            startCount += 1
            let session = FakeSession()
            sessions[identity] = session
            return session
        }
    }

    private final class FakeSession: PreviewCaptureSession {
        private(set) var stopCount = 0
        private(set) var updateCount = 0

        func stop() {
            stopCount += 1
        }

        func update(policy: PreviewCapturePolicy) {
            updateCount += 1
        }
    }

    private final class TerminationSessionFactory {
        private var sessions: [PreviewWindowIdentity: [TerminationSession]] = [:]
        private(set) var startedModes: [PreviewWindowIdentity: [PreviewCaptureMode]] = [:]

        var startCount: Int {
            sessions.values.reduce(0) { $0 + $1.count }
        }

        var stopCount: Int {
            sessions.values.flatMap { $0 }.reduce(0) { $0 + $1.stopCount }
        }

        func start(
            identity: PreviewWindowIdentity,
            mode: PreviewCaptureMode,
            policy: PreviewCapturePolicy
        ) -> (any PreviewCaptureSession)? {
            let session = TerminationSession()
            sessions[identity, default: []].append(session)
            startedModes[identity, default: []].append(mode)
            return session
        }

        func latestSession(for identity: PreviewWindowIdentity) -> TerminationSession? {
            sessions[identity]?.last
        }
    }

    private final class TerminationSession: PreviewCaptureSessionTerminationReporting {
        private var terminationHandler: ((PreviewCaptureSessionTerminationEvent) -> Void)?
        private(set) var stopCount = 0

        func stop() {
            stopCount += 1
        }

        func setTerminationHandler(
            _ handler: @escaping (PreviewCaptureSessionTerminationEvent) -> Void
        ) {
            terminationHandler = handler
        }

        func send(_ event: PreviewCaptureSessionTerminationEvent) {
            terminationHandler?(event)
        }
    }
}
