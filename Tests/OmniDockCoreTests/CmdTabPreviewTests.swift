import AppKit
import XCTest
@testable import OmniDockCore

final class CmdTabPreviewTests: XCTestCase {
    @MainActor
    func testDisplayChangeEndsCommandTabWithoutRestoringTheOldSelection() throws {
        let applicationCenter = NotificationCenter()
        let provider = TestWorkspaceSwitcherProvider()
        let observer = CmdTabPreviewObserver(
            isFeatureEnabled: { true }, processSwitcher: provider,
            workspaceNotificationCenter: NotificationCenter(), applicationNotificationCenter: applicationCenter
        )
        var ended = 0
        observer.onInteractionEnded = { ended += 1 }
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: 0, context: nil, characters: "\t", charactersIgnoringModifiers: "\t",
            isARepeat: false, keyCode: 48
        ))
        observer.start()
        defer { observer.stop() }
        observer.handle(event)
        XCTAssertTrue(provider.isObserving)

        applicationCenter.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)

        XCTAssertEqual(ended, 1)
        XCTAssertFalse(provider.isObserving)
        provider.onSelectionChanged?()
        XCTAssertEqual(ended, 1)
        observer.handle(event)
        XCTAssertTrue(provider.isObserving)
    }

    @MainActor
    func testWorkspaceSuspensionEndsCommandTabAndRequiresNewInputAfterResume() throws {
        let center = NotificationCenter()
        let provider = TestWorkspaceSwitcherProvider()
        let observer = CmdTabPreviewObserver(
            isFeatureEnabled: { true }, processSwitcher: provider, workspaceNotificationCenter: center
        )
        var started = 0
        var ended = 0
        observer.onInteractionBegan = { started += 1 }
        observer.onInteractionEnded = { ended += 1 }
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: 0, context: nil, characters: "\t", charactersIgnoringModifiers: "\t",
            isARepeat: false, keyCode: 48
        ))
        observer.start()
        defer { observer.stop() }
        observer.handle(event)
        XCTAssertEqual(started, 1)
        XCTAssertTrue(provider.isObserving)

        center.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)

        XCTAssertEqual(ended, 1)
        XCTAssertFalse(provider.isObserving)
        observer.handle(event)
        XCTAssertEqual(started, 1)
        center.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        XCTAssertEqual(started, 1)
        observer.handle(event)
        XCTAssertEqual(started, 2)
        XCTAssertTrue(provider.isObserving)
    }

    func testApplicationResolutionPrefersBundleIdentifier() {
        let first = candidate(pid: 101, bundleIdentifier: "com.example.first", name: "Shared Name")
        let second = candidate(pid: 202, bundleIdentifier: "com.example.second", name: "Shared Name")

        let resolved = CmdTabApplicationResolutionPolicy.resolve(
            bundleIdentifier: "com.example.second",
            title: "Shared Name",
            candidates: [first, second]
        )

        XCTAssertEqual(resolved, second)
    }

    func testApplicationResolutionUsesUniqueNormalizedTitleFallback() {
        let expected = candidate(pid: 101, bundleIdentifier: nil, name: "Résumé")
        let other = candidate(pid: 202, bundleIdentifier: nil, name: "Different")

        let resolved = CmdTabApplicationResolutionPolicy.resolve(
            bundleIdentifier: nil,
            title: " resume ",
            candidates: [other, expected]
        )

        XCTAssertEqual(resolved, expected)
    }

    func testApplicationResolutionRefusesAmbiguousTitleFallback() {
        let first = candidate(pid: 101, bundleIdentifier: nil, name: "Shared Name")
        let second = candidate(pid: 202, bundleIdentifier: nil, name: "Shared Name")

        XCTAssertNil(CmdTabApplicationResolutionPolicy.resolve(
            bundleIdentifier: nil,
            title: "Shared Name",
            candidates: [first, second]
        ))
    }

    func testLifecycleRejectsStaleDiscoveryAfterInteractionEnds() throws {
        var state = CmdTabPreviewLifecycleState()
        state.start()
        let generation = try XCTUnwrap(state.beginDiscovery())

        XCTAssertTrue(state.accepts(generation))
        XCTAssertTrue(state.endInteraction())
        XCTAssertFalse(state.accepts(generation))
        XCTAssertFalse(state.beginObservation(for: generation))
        XCTAssertEqual(state.phase, .idle)
    }

    func testLifecycleObservationCanOnlyBeginForCurrentDiscovery() throws {
        var state = CmdTabPreviewLifecycleState()
        state.start()
        let generation = try XCTUnwrap(state.beginDiscovery())

        XCTAssertFalse(state.beginObservation(for: generation &+ 1))
        XCTAssertTrue(state.beginObservation(for: generation))
        XCTAssertEqual(state.phase, .observing(generation))
    }

    func testLifecycleCanRestartDiscoveryWhenTheSwitcherNeverBecomesReady() throws {
        var state = CmdTabPreviewLifecycleState()
        state.start()
        let firstGeneration = try XCTUnwrap(state.beginDiscovery())
        XCTAssertTrue(state.beginObservation(for: firstGeneration))

        let retryGeneration = try XCTUnwrap(state.restartDiscovery(for: firstGeneration))

        XCTAssertNotEqual(retryGeneration, firstGeneration)
        XCTAssertEqual(state.phase, .discovering(retryGeneration))
        XCTAssertFalse(state.accepts(firstGeneration))
        XCTAssertTrue(state.accepts(retryGeneration))
    }

    func testRequestStateRejectsPreviousTargetAndCanceledResponse() {
        var state = CmdTabPreviewRequestState()
        let first = state.begin(targetIdentifier: "command-tab:101")
        let second = state.begin(targetIdentifier: "command-tab:202")

        XCTAssertFalse(state.accepts(generation: first, targetIdentifier: "command-tab:101"))
        XCTAssertTrue(state.accepts(generation: second, targetIdentifier: "command-tab:202"))

        state.cancel()
        XCTAssertFalse(state.accepts(generation: second, targetIdentifier: "command-tab:202"))
    }

    func testPointerButtonActionRunsOnlyAfterReleaseInsideTheSameButton() {
        var state = CmdTabPreviewPointerState()
        let snapshot = pointerSnapshot()
        let expectedInvocation = CmdTabPreviewButtonInvocation(
            action: .quitApplication(101),
            requestGeneration: snapshot.requestGeneration,
            targetIdentifier: snapshot.targetIdentifier
        )
        state.update(snapshot: snapshot)

        XCTAssertEqual(state.mouseDown(at: CGPoint(x: 15, y: 15)), .swallow)
        XCTAssertEqual(state.mouseUp(at: CGPoint(x: 15, y: 15)), .invoke(expectedInvocation))
    }

    func testPointerReleaseOutsideButtonCancelsTheActionAndSwallowsTheRelease() {
        var state = CmdTabPreviewPointerState()
        state.update(snapshot: pointerSnapshot())

        XCTAssertEqual(state.mouseDown(at: CGPoint(x: 15, y: 15)), .swallow)
        XCTAssertEqual(state.mouseDragged(at: CGPoint(x: 15, y: 15)), .swallow)
        XCTAssertEqual(state.mouseUp(at: CGPoint(x: 80, y: 80)), .swallow)
    }

    func testPointerOutsidePreviewEndsInteractionWithoutSwallowingTheSystemClick() {
        var state = CmdTabPreviewPointerState()
        state.update(snapshot: pointerSnapshot())

        XCTAssertEqual(state.mouseDown(at: CGPoint(x: 140, y: 140)), .endInteraction)
    }

    func testPointerInsidePreviewButOutsideButtonsPassesThrough() {
        var state = CmdTabPreviewPointerState()
        state.update(snapshot: pointerSnapshot())

        XCTAssertEqual(state.mouseDown(at: CGPoint(x: 60, y: 60)), .passThrough)
    }

    func testPointerRejectsActionWhenThePreviewGenerationChangesBeforeRelease() {
        var state = CmdTabPreviewPointerState()
        state.update(snapshot: pointerSnapshot(requestGeneration: 3))
        XCTAssertEqual(state.mouseDown(at: CGPoint(x: 15, y: 15)), .swallow)

        state.update(snapshot: pointerSnapshot(requestGeneration: 4))

        XCTAssertEqual(state.mouseUp(at: CGPoint(x: 15, y: 15)), .swallow)
    }

    func testPointerHoverPublishesOnlyWhenTheHoveredButtonChanges() {
        var state = CmdTabPreviewPointerState()
        state.update(snapshot: pointerSnapshot())

        XCTAssertEqual(
            state.mouseMoved(at: CGPoint(x: 15, y: 15)),
            .changed(.quitApplication(101))
        )
        XCTAssertEqual(state.mouseMoved(at: CGPoint(x: 15, y: 15)), .unchanged)
        XCTAssertEqual(state.mouseMoved(at: CGPoint(x: 60, y: 60)), .changed(nil))
    }

    func testCardClickKeepsExactIdentityAndButtonPriority() {
        var state = CmdTabPreviewPointerState()
        let snapshot = cardSnapshot()
        state.update(snapshot: snapshot)
        XCTAssertEqual(state.mouseDown(at: CGPoint(x: 15, y: 15)), .swallow)
        XCTAssertEqual(state.mouseUp(at: CGPoint(x: 15, y: 15)), .invoke(.init(
            action: .quitApplication(101), requestGeneration: 3, targetIdentifier: snapshot.targetIdentifier
        )))
        XCTAssertEqual(state.mouseDown(at: CGPoint(x: 60, y: 60)), .swallow)
        XCTAssertEqual(state.mouseDragged(at: CGPoint(x: 62, y: 60)), .swallow)
        XCTAssertEqual(state.mouseUp(at: CGPoint(x: 62, y: 60)), .invoke(.init(
            action: snapshot.buttonTargets[1].action, requestGeneration: 3, targetIdentifier: snapshot.targetIdentifier
        )))
    }

    func testCardDragScrollsWithoutFocusingOnReleaseEvenAfterReturningToOrigin() {
        var state = CmdTabPreviewPointerState()
        let snapshot = cardSnapshot()
        let invocation = CmdTabPreviewButtonInvocation(
            action: snapshot.buttonTargets[1].action, requestGeneration: 3, targetIdentifier: snapshot.targetIdentifier
        )
        state.update(snapshot: snapshot)
        XCTAssertEqual(state.mouseDown(at: CGPoint(x: 60, y: 60)), .swallow)
        XCTAssertEqual(state.mouseDragged(at: CGPoint(x: 70, y: 60)), .scroll(invocation, deltaX: 10))
        XCTAssertEqual(state.mouseDragged(at: CGPoint(x: 60, y: 60)), .scroll(invocation, deltaX: -10))
        XCTAssertEqual(state.mouseUp(at: CGPoint(x: 60, y: 60)), .swallow)
        XCTAssertFalse(state.isCapturingPointer)
    }

    func testCardCannotFocusAfterItsTargetIsRemovedOrReplaced() {
        let original = cardSnapshot()
        let replacements: [CmdTabPreviewPointerSnapshot?] = [
            nil, pointerSnapshot(), cardSnapshot(generation: 4),
            cardSnapshot(windowID: 202), cardSnapshot(targetIdentifier: "command-tab:other")
        ]
        for replacement in replacements {
            var state = CmdTabPreviewPointerState()
            state.update(snapshot: original)
            XCTAssertEqual(state.mouseDown(at: CGPoint(x: 60, y: 60)), .swallow)
            state.update(snapshot: replacement)
            XCTAssertEqual(state.mouseUp(at: CGPoint(x: 60, y: 60)), .swallow)
        }
    }

    func testCardDragDoesNotScrollANewerPresentation() {
        var state = CmdTabPreviewPointerState()
        state.update(snapshot: cardSnapshot())
        XCTAssertEqual(state.mouseDown(at: CGPoint(x: 60, y: 60)), .swallow)
        state.update(snapshot: cardSnapshot(generation: 4))
        XCTAssertEqual(state.mouseDragged(at: CGPoint(x: 80, y: 60)), .swallow)
        XCTAssertEqual(state.mouseUp(at: CGPoint(x: 80, y: 60)), .swallow)
    }

    private func cardSnapshot(
        generation: UInt64 = 3, windowID: CGWindowID = 201, targetIdentifier: String = "command-tab:101"
    ) -> CmdTabPreviewPointerSnapshot {
        let buttons = pointerSnapshot().buttonTargets
        return CmdTabPreviewPointerSnapshot(
            eventTapPanelFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
            buttonTargets: buttons + [.init(
                action: .focusWindow(.window(processIdentifier: 101, windowID: windowID)),
                eventTapFrame: CGRect(x: 5, y: 5, width: 90, height: 90)
            )],
            requestGeneration: generation, targetIdentifier: targetIdentifier
        )
    }

    private func candidate(
        pid: pid_t,
        bundleIdentifier: String?,
        name: String
    ) -> CmdTabApplicationCandidate {
        CmdTabApplicationCandidate(
            processIdentifier: pid,
            bundleIdentifier: bundleIdentifier,
            localizedName: name,
            bundleURL: URL(fileURLWithPath: "/Applications/\(name).app")
        )
    }

    private func pointerSnapshot(
        requestGeneration: UInt64 = 3
    ) -> CmdTabPreviewPointerSnapshot {
        CmdTabPreviewPointerSnapshot(
            eventTapPanelFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
            buttonTargets: [
                CmdTabPreviewPointerButtonTarget(
                    action: .quitApplication(101),
                    eventTapFrame: CGRect(x: 10, y: 10, width: 13, height: 13)
                )
            ],
            requestGeneration: requestGeneration,
            targetIdentifier: "command-tab:101"
        )
    }
}

@MainActor
private final class TestWorkspaceSwitcherProvider: CmdTabProcessSwitcherProviding {
    var onSelectionChanged: (() -> Void)?
    var onDestroyed: (() -> Void)?
    private(set) var isObserving = false
    func beginObserving() -> Bool { isObserving = true; return true }
    func currentSelection() -> CmdTabSwitcherSelection? { nil }
    func stopObserving() { isObserving = false }
}
