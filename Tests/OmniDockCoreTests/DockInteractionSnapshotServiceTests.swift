import CoreGraphics
import XCTest
@testable import OmniDockCore

final class DockInteractionSnapshotServiceTests: XCTestCase {
    func testFreshSnapshotReturnsResolvedTarget() throws {
        let store = DockInteractionSnapshotStore()
        let target = makeTarget(processIdentifier: 101)
        store.publish(publication(
            generation: 1,
            target: target,
            refreshedAt: 10,
            inventoryRefreshedAt: 9.5
        ))

        let result = store.target(
            atEventTapPoint: CGPoint(x: 20, y: 20),
            now: 10.2
        )

        XCTAssertEqual(try XCTUnwrap(result).target, target)
    }

    func testHotTargetExpiresAfterQuarterSecond() {
        let store = DockInteractionSnapshotStore()
        store.publish(publication(
            generation: 1,
            target: makeTarget(processIdentifier: 101),
            refreshedAt: 10,
            inventoryRefreshedAt: 10
        ))

        XCTAssertNotNil(store.target(
            atEventTapPoint: CGPoint(x: 20, y: 20),
            now: 10.25
        ))
        XCTAssertNil(store.target(
            atEventTapPoint: CGPoint(x: 20, y: 20),
            now: 10.251
        ))
    }

    func testInventoryExpiresAfterOneSecond() {
        let store = DockInteractionSnapshotStore()
        store.publish(publication(
            generation: 1,
            target: makeTarget(processIdentifier: 101),
            refreshedAt: 10.8,
            inventoryRefreshedAt: 10
        ))

        XCTAssertNotNil(store.target(
            atEventTapPoint: CGPoint(x: 20, y: 20),
            now: 11
        ))
        XCTAssertNil(store.target(
            atEventTapPoint: CGPoint(x: 20, y: 20),
            now: 11.001
        ))
    }

    func testPointOutsideHotTargetFailsOpen() {
        let store = DockInteractionSnapshotStore()
        store.publish(publication(
            generation: 1,
            target: makeTarget(processIdentifier: 101),
            refreshedAt: 10,
            inventoryRefreshedAt: 10
        ))

        XCTAssertNil(store.target(
            atEventTapPoint: CGPoint(x: 120, y: 120),
            now: 10.1
        ))
    }

    func testUnhandleableTargetFailsOpen() {
        let store = DockInteractionSnapshotStore()
        store.publish(publication(
            generation: 1,
            target: makeTarget(processIdentifier: 101),
            shouldHandle: false,
            refreshedAt: 10,
            inventoryRefreshedAt: 10
        ))

        XCTAssertNil(store.target(
            atEventTapPoint: CGPoint(x: 20, y: 20),
            now: 10.1
        ))
    }

    func testLateGenerationCannotReplaceNewerSnapshot() {
        let store = DockInteractionSnapshotStore()
        let newerTarget = makeTarget(processIdentifier: 202)
        let olderTarget = makeTarget(processIdentifier: 101)

        XCTAssertTrue(store.publish(publication(
            generation: 2,
            target: newerTarget,
            refreshedAt: 10,
            inventoryRefreshedAt: 10
        )))
        XCTAssertFalse(store.publish(publication(
            generation: 1,
            target: olderTarget,
            refreshedAt: 10.1,
            inventoryRefreshedAt: 10.1
        )))

        XCTAssertEqual(store.currentPublication().hotTarget?.target, newerTarget)
    }

    func testClearingWithNewGenerationInvalidatesTarget() {
        let store = DockInteractionSnapshotStore()
        store.publish(publication(
            generation: 1,
            target: makeTarget(processIdentifier: 101),
            refreshedAt: 10,
            inventoryRefreshedAt: 10
        ))

        store.removeAll(generation: 2)

        XCTAssertNil(store.currentPublication().hotTarget)
        XCTAssertEqual(store.currentPublication().generation, 2)
    }

    func testRestartRejectsDelayedEvaluationFromPreviousSession() {
        let firstEvaluationStarted = DispatchSemaphore(value: 0)
        let releaseFirstEvaluation = DispatchSemaphore(value: 0)
        let secondSessionPublished = expectation(description: "second session published")
        let stateLock = NSLock()
        var evaluationCount = 0
        var publishedStaleTarget = false
        var fulfilledSecondSession = false

        let store = DockInteractionSnapshotStore { publication in
            guard let processIdentifier = publication.hotTarget?.target.processIdentifier else {
                return
            }
            stateLock.lock()
            if processIdentifier == 101 {
                publishedStaleTarget = true
            } else if processIdentifier == 202, !fulfilledSecondSession {
                fulfilledSecondSession = true
                secondSessionPublished.fulfill()
            }
            stateLock.unlock()
        }
        let inventoryTarget = makeTarget(processIdentifier: 50)
        let inventoryItem = DockHitTestInventoryItem(
            target: inventoryTarget,
            appKitFrame: CGRect(x: 0, y: 0, width: 40, height: 40),
            eventTapFrame: CGRect(x: 0, y: 0, width: 40, height: 40)
        )
        let service = DockInteractionSnapshotService(
            snapshotStore: store,
            inventoryProvider: { [inventoryItem] },
            targetEvaluator: { _ in
                stateLock.lock()
                evaluationCount += 1
                let currentEvaluation = evaluationCount
                stateLock.unlock()

                if currentEvaluation == 1 {
                    firstEvaluationStarted.signal()
                    _ = releaseFirstEvaluation.wait(timeout: .now() + 2)
                    return DockInteractionEvaluatedTarget(
                        target: self.makeTarget(processIdentifier: 101),
                        shouldHandle: true
                    )
                }
                return DockInteractionEvaluatedTarget(
                    target: self.makeTarget(processIdentifier: 202),
                    shouldHandle: true
                )
            },
            pointerLocationProvider: { CGPoint(x: 20, y: 20) }
        )

        service.start()
        XCTAssertEqual(firstEvaluationStarted.wait(timeout: .now() + 1), .success)
        service.stop()
        service.start()
        releaseFirstEvaluation.signal()

        wait(for: [secondSessionPublished], timeout: 2)
        service.stop()

        stateLock.lock()
        let didPublishStaleTarget = publishedStaleTarget
        stateLock.unlock()
        XCTAssertFalse(didPublishStaleTarget)
    }

    func testSystemInventoryIsCapturedOnMainAndConsumedOnSnapshotQueue() {
        let target = makeTarget(processIdentifier: 101)
        let application = DockRunningApplicationInventoryItem(
            processIdentifier: target.processIdentifier,
            bundleIdentifier: target.bundleIdentifier,
            localizedName: target.localizedName,
            isHidden: false,
            isDockTargetCandidate: true
        )
        let systemInventory = DockInteractionSystemInventory(
            hasAccessibilityPermission: true,
            dockProcessIdentifier: 999,
            screens: .empty,
            applications: DockApplicationInventory(runningApplications: [application])
        )
        let inventoryItem = DockHitTestInventoryItem(
            target: target,
            appKitFrame: CGRect(x: 0, y: 0, width: 40, height: 40),
            eventTapFrame: CGRect(x: 0, y: 0, width: 40, height: 40)
        )
        let published = expectation(description: "snapshot published")
        let recorder = DockSnapshotPipelineThreadRecorder()
        let store = DockInteractionSnapshotStore { publication in
            guard publication.hotTarget?.target == target,
                  recorder.claimTargetPublication()
            else {
                return
            }
            published.fulfill()
        }
        let service = DockInteractionSnapshotService(
            snapshotStore: store,
            systemInventoryProvider: {
                recorder.recordSystemInventoryProvider()
                return systemInventory
            },
            inventoryProvider: { inventory in
                recorder.recordGeometryProvider(receivedExpectedInventory: inventory == systemInventory)
                return [inventoryItem]
            },
            targetEvaluator: { evaluatedTarget, applications in
                recorder.recordTargetEvaluator(
                    receivedExpectedInventory: applications == systemInventory.applications
                )
                return DockInteractionEvaluatedTarget(
                    target: evaluatedTarget,
                    shouldHandle: true
                )
            },
            pointerLocationProvider: { CGPoint(x: 20, y: 20) }
        )

        service.start()
        defer { service.stop() }
        wait(for: [published], timeout: 2)

        let result = recorder.result()
        XCTAssertGreaterThanOrEqual(result.systemInventoryProviderCalls, 1)
        XCTAssertTrue(result.allSystemInventoryProviderCallsWereMainThread)
        XCTAssertGreaterThanOrEqual(result.geometryProviderCalls, 1)
        XCTAssertTrue(result.allGeometryProviderCallsWereBackground)
        XCTAssertTrue(result.geometryReceivedExpectedInventory)
        XCTAssertGreaterThanOrEqual(result.targetEvaluatorCalls, 1)
        XCTAssertTrue(result.allTargetEvaluatorCallsWereBackground)
        XCTAssertTrue(result.targetEvaluatorReceivedExpectedInventory)
    }

    private func publication(
        generation: UInt64,
        target: DockAppTarget,
        shouldHandle: Bool = true,
        refreshedAt: TimeInterval,
        inventoryRefreshedAt: TimeInterval
    ) -> DockInteractionSnapshotPublication {
        DockInteractionSnapshotPublication(
            generation: generation,
            hotTarget: DockInteractionHotTargetSnapshot(
                target: target,
                eventTapFrame: CGRect(x: 0, y: 0, width: 40, height: 40),
                shouldHandle: shouldHandle,
                refreshedAt: refreshedAt,
                inventoryRefreshedAt: inventoryRefreshedAt
            )
        )
    }

    private func makeTarget(processIdentifier: pid_t) -> DockAppTarget {
        DockAppTarget(
            processIdentifier: processIdentifier,
            bundleIdentifier: "com.example.app\(processIdentifier)",
            localizedName: "App \(processIdentifier)",
            dockElementTitle: "App \(processIdentifier)",
            hitPoint: CGPoint(x: 20, y: 20),
            dockItemFrame: CGRect(x: 0, y: 0, width: 40, height: 40),
            dockTileIdentifierOverride: "dock-item:\(processIdentifier)"
        )
    }
}

private final class DockSnapshotPipelineThreadRecorder {
    struct Result {
        let systemInventoryProviderCalls: Int
        let allSystemInventoryProviderCallsWereMainThread: Bool
        let geometryProviderCalls: Int
        let allGeometryProviderCallsWereBackground: Bool
        let geometryReceivedExpectedInventory: Bool
        let targetEvaluatorCalls: Int
        let allTargetEvaluatorCallsWereBackground: Bool
        let targetEvaluatorReceivedExpectedInventory: Bool
    }

    private let lock = NSLock()
    private var systemInventoryProviderCalls = 0
    private var allSystemInventoryProviderCallsWereMainThread = true
    private var geometryProviderCalls = 0
    private var allGeometryProviderCallsWereBackground = true
    private var geometryReceivedExpectedInventory = true
    private var targetEvaluatorCalls = 0
    private var allTargetEvaluatorCallsWereBackground = true
    private var targetEvaluatorReceivedExpectedInventory = true
    private var didClaimTargetPublication = false

    func recordSystemInventoryProvider() {
        lock.lock()
        systemInventoryProviderCalls += 1
        allSystemInventoryProviderCallsWereMainThread =
            allSystemInventoryProviderCallsWereMainThread && Thread.isMainThread
        lock.unlock()
    }

    func recordGeometryProvider(receivedExpectedInventory: Bool) {
        lock.lock()
        geometryProviderCalls += 1
        allGeometryProviderCallsWereBackground =
            allGeometryProviderCallsWereBackground && !Thread.isMainThread
        geometryReceivedExpectedInventory =
            geometryReceivedExpectedInventory && receivedExpectedInventory
        lock.unlock()
    }

    func recordTargetEvaluator(receivedExpectedInventory: Bool) {
        lock.lock()
        targetEvaluatorCalls += 1
        allTargetEvaluatorCallsWereBackground =
            allTargetEvaluatorCallsWereBackground && !Thread.isMainThread
        targetEvaluatorReceivedExpectedInventory =
            targetEvaluatorReceivedExpectedInventory && receivedExpectedInventory
        lock.unlock()
    }

    func claimTargetPublication() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !didClaimTargetPublication else {
            return false
        }
        didClaimTargetPublication = true
        return true
    }

    func result() -> Result {
        lock.lock()
        defer { lock.unlock() }
        return Result(
            systemInventoryProviderCalls: systemInventoryProviderCalls,
            allSystemInventoryProviderCallsWereMainThread:
                allSystemInventoryProviderCallsWereMainThread,
            geometryProviderCalls: geometryProviderCalls,
            allGeometryProviderCallsWereBackground: allGeometryProviderCallsWereBackground,
            geometryReceivedExpectedInventory: geometryReceivedExpectedInventory,
            targetEvaluatorCalls: targetEvaluatorCalls,
            allTargetEvaluatorCallsWereBackground: allTargetEvaluatorCallsWereBackground,
            targetEvaluatorReceivedExpectedInventory: targetEvaluatorReceivedExpectedInventory
        )
    }
}
