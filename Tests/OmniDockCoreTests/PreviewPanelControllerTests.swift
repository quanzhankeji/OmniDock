import AppKit
import XCTest
@testable import OmniDockCore

@MainActor
final class PreviewPanelControllerTests: XCTestCase {
    func testWindowCycleSelectionScrollsToTheLastRowAndBack() throws {
        let priorWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        let controller = PreviewPanelController(
            requestWindowFocus: { _, _, _, _ in }, requestWindowClose: { _, _, _, _ in }
        )
        defer { controller.hide() }
        let windows = (1...70).map { previewInfo(windowID: CGWindowID($0)) }
        controller.show(target: windowCycleTarget(), windows: windows, message: nil)
        let panel = try XCTUnwrap(NSApp.windows.first { !priorWindows.contains(ObjectIdentifier($0)) })
        let scroll = try XCTUnwrap(panel.contentView?.subviews.compactMap { $0 as? NSScrollView }.first)
        let document = try XCTUnwrap(scroll.documentView)
        let grid = try XCTUnwrap(document.subviews.compactMap { $0 as? NSGridView }.first)
        XCTAssertEqual(controller.windowCycleColumnCount, grid.numberOfColumns)
        panel.contentView?.layoutSubtreeIfNeeded()

        for index in [windows.count - 1, 0] {
            controller.setSelectedWindow(windows[index])
            let tile = try XCTUnwrap(grid.cell(atColumnIndex: index % grid.numberOfColumns,
                                               rowIndex: index / grid.numberOfColumns).contentView)
            let frame = tile.convert(tile.bounds, to: document)
            XCTAssertTrue(scroll.contentView.bounds.insetBy(dx: -1, dy: -1).contains(frame))
        }
    }

    func testMetadataOnlyPanelFitsApplicationIdentityOnFirstPresentationAndReuse() throws {
        let info = previewInfo()
        let metadata = PreviewWindowInfo(
            id: info.id, windowID: info.windowID, processIdentifier: info.processIdentifier,
            appName: info.appName, title: info.title, frame: info.frame, isMinimized: false,
            placeholderText: AppStrings.text(.previewMetadataOnly)
        )
        let controller = PreviewPanelController(
            requestWindowFocus: { _, _, _, _ in }, requestWindowClose: { _, _, _, _ in }
        )
        defer { controller.hide() }
        for target in [dockTarget(), commandTabTarget(), windowCycleTarget()] {
            controller.show(target: target, windows: [metadata], message: nil)
            XCTAssertEqual(try XCTUnwrap(controller.frame).height,
                           174 + PreviewThumbnailView.statusRowHeight + PreviewLayoutCalculator.margin * 2, accuracy: 1)
            controller.hide()
        }

        controller.show(target: dockTarget(), windows: [metadata], message: nil)
        controller.show(target: dockTarget(), windows: [info], message: nil)
        XCTAssertEqual(try XCTUnwrap(controller.frame).height,
                       150 + PreviewThumbnailView.statusRowHeight + PreviewLayoutCalculator.margin * 2)
    }

    func testIndependentSwitcherGridKeepsItsCardsForMetadataOnlyUpdates() {
        let current = [previewInfo()]
        let renamed = [previewInfo(title: "Updated title")]

        XCTAssertFalse(
            WindowCyclePresentationPolicy.needsGridRebuild(
                current: current,
                replacement: renamed
            )
        )
    }

    func testIndependentSwitcherGridRebuildsWhenWindowOrderOrGeometryChanges() {
        let first = previewInfo(id: "one", windowID: 1)
        let second = previewInfo(id: "two", windowID: 2)
        let resized = previewInfo(
            id: "one",
            windowID: 1,
            frame: CGRect(x: 0, y: 0, width: 1000, height: 600)
        )

        XCTAssertTrue(
            WindowCyclePresentationPolicy.needsGridRebuild(
                current: [first, second],
                replacement: [second, first]
            )
        )
        XCTAssertTrue(
            WindowCyclePresentationPolicy.needsGridRebuild(
                current: [first],
                replacement: [resized]
            )
        )
    }

    func testWindowFocusEndsPreviewLifecycleBeforeRequestingFocus() {
        let info = previewInfo()
        var events: [String] = []
        var focusedWindowID: CGWindowID?
        let controller = PreviewPanelController(
            requestWindowFocus: { _, _, windowID, _ in
                events.append("focus")
                focusedWindowID = windowID
            },
            requestWindowClose: { _, _, _, _ in }
        )
        controller.onPreviewLifecycleEndRequested = {
            events.append("lifecycle")
        }

        controller.focusWindowAndHidePreview(info)

        XCTAssertEqual(events, ["lifecycle", "focus"])
        XCTAssertEqual(focusedWindowID, info.windowID)
        XCTAssertNil(controller.frame)
    }

    func testCommandTabFocusUsesItsPresentationHandler() {
        let info = previewInfo()
        var events: [String] = []
        let controller = PreviewPanelController(
            requestWindowFocus: { _, _, _, _ in
                events.append("focus")
            },
            requestWindowClose: { _, _, _, _ in }
        )
        controller.onPreviewLifecycleEndRequested = {
            events.append("dock")
        }
        controller.setPresentationHandler(
            for: .commandTab,
            onLifecycleEndRequested: {
                events.append("command-tab")
            },
            onWindowClosed: { _ in }
        )
        controller.show(target: commandTabTarget(), windows: [info], message: nil)

        controller.focusWindowAndHidePreview(info)

        XCTAssertEqual(events, ["command-tab", "focus"])
    }

    func testHideReleasesInstalledPreviewContentAndPanelCanBeReused() {
        let controller = PreviewPanelController(
            requestWindowFocus: { _, _, _, _ in },
            requestWindowClose: { _, _, _, _ in }
        )
        controller.show(target: dockTarget(), windows: [previewInfo()], message: nil)

        XCTAssertTrue(controller.hasInstalledContentView)

        controller.hide()

        XCTAssertFalse(controller.hasInstalledContentView)
        XCTAssertNil(controller.frame)

        controller.show(target: dockTarget(), windows: [previewInfo()], message: nil)

        XCTAssertTrue(controller.hasInstalledContentView)
        XCTAssertNotNil(controller.frame)
        controller.hide()
    }

    func testFailedFocusReportsTheSameResultForEachPreviewEntryWithoutRestoringCards() async {
        for target in [dockTarget(), commandTabTarget(), windowCycleTarget()] {
            let info = previewInfo()
            var focusCompletion: ((WindowFocusResult) -> Void)?
            var lifecycleEnds = 0
            let controller = PreviewPanelController(
                requestWindowFocus: { _, _, _, completion in focusCompletion = completion },
                requestWindowClose: { _, _, _, _ in }
            )
            defer { controller.hide() }
            controller.onPreviewLifecycleEndRequested = { lifecycleEnds += 1 }
            controller.show(target: target, windows: [info], message: nil)

            if target.previewAnchorKind == .windowCycle {
                controller.hide()
                controller.focusWindowAfterPreviewDismissal(info, feedbackTarget: target)
            } else {
                controller.focusWindowAndHidePreview(info)
                XCTAssertEqual(lifecycleEnds, 1)
            }
            XCTAssertNil(controller.frame)
            XCTAssertFalse(controller.hasInstalledContentView)
            focusCompletion?(.unconfirmed)
            await settleMainActor()

            XCTAssertEqual(controller.displayedWindowCount, 0)
            XCTAssertEqual(controller.displayedMessage, AppStrings.text(.previewFocusFailed))
            XCTAssertNotNil(controller.frame)
        }
    }

    func testConfirmedOrSupersededFocusDoesNotReopenPreview() async {
        for result in [WindowFocusResult.focused, .superseded] {
            let controller = PreviewPanelController(
                requestWindowFocus: { _, _, _, completion in completion(result) },
                requestWindowClose: { _, _, _, _ in }
            )
            controller.show(target: dockTarget(), windows: [previewInfo()], message: nil)
            controller.focusWindowAndHidePreview(previewInfo())
            await settleMainActor()

            XCTAssertNil(controller.frame)
            XCTAssertFalse(controller.hasInstalledContentView)
        }
    }

    func testOldFocusFailureCannotReplaceANewerPreview() async {
        var focusCompletion: ((WindowFocusResult) -> Void)?
        let controller = PreviewPanelController(
            requestWindowFocus: { _, _, _, completion in focusCompletion = completion },
            requestWindowClose: { _, _, _, _ in }
        )
        defer { controller.hide() }
        controller.show(target: dockTarget(), windows: [previewInfo()], message: nil)
        controller.focusWindowAndHidePreview(previewInfo())
        controller.show(target: commandTabTarget(), windows: [previewInfo(windowID: 43)], message: nil)

        focusCompletion?(.unavailable)
        await settleMainActor()

        XCTAssertEqual(controller.displayedWindowCount, 1)
        XCTAssertNil(controller.displayedMessage)
    }

    func testStartingNextSwitchCancelsFocusAndPendingFailureFeedback() async {
        var focusCompletion: ((WindowFocusResult) -> Void)?
        var cancellations = 0
        let controller = PreviewPanelController(
            requestWindowFocus: { _, _, _, completion in focusCompletion = completion },
            requestWindowClose: { _, _, _, _ in },
            cancelWindowFocus: { cancellations += 1 }
        )
        controller.show(target: dockTarget(), windows: [previewInfo()], message: nil)
        controller.focusWindowAndHidePreview(previewInfo())

        controller.cancelPendingWindowFocus()
        focusCompletion?(.unconfirmed)
        await settleMainActor()

        XCTAssertEqual(cancellations, 1)
        XCTAssertNil(controller.frame)
        XCTAssertFalse(controller.hasInstalledContentView)
    }

    func testNewFocusRequestDiscardsThePreviousFailure() async {
        var completions: [(WindowFocusResult) -> Void] = []
        let controller = PreviewPanelController(
            requestWindowFocus: { _, _, _, completion in completions.append(completion) },
            requestWindowClose: { _, _, _, _ in }
        )
        controller.focusWindowAfterPreviewDismissal(previewInfo(), feedbackTarget: dockTarget())
        controller.focusWindowAfterPreviewDismissal(previewInfo(windowID: 43), feedbackTarget: dockTarget())

        completions[1](.focused)
        completions[0](.unavailable)
        await settleMainActor()

        XCTAssertNil(controller.frame)
        XCTAssertFalse(controller.hasInstalledContentView)
    }

    func testFocusFailureMessageDismissesEvenIfNextSwitchHasNotPresentedYet() async throws {
        let controller = PreviewPanelController(
            requestWindowFocus: { _, _, _, completion in completion(.unavailable) },
            requestWindowClose: { _, _, _, _ in }
        )
        defer { controller.hide() }
        controller.focusWindowAfterPreviewDismissal(previewInfo(), feedbackTarget: dockTarget())
        await settleMainActor()
        XCTAssertEqual(controller.displayedMessage, AppStrings.text(.previewFocusFailed))
        controller.cancelPendingWindowFocus()

        try await Task.sleep(nanoseconds: 2_100_000_000)

        XCTAssertNil(controller.frame)
        XCTAssertFalse(controller.hasInstalledContentView)
    }

    func testMessageOnlyPanelHasValidTextGeometryAfterPreviewDismissal() throws {
        let controller = PreviewPanelController(
            requestWindowFocus: { _, _, _, _ in },
            requestWindowClose: { _, _, _, _ in }
        )
        defer { controller.hide() }
        controller.show(target: dockTarget(), windows: [previewInfo()], message: nil)
        controller.hide()
        let message = "Window focus verification message"
        controller.show(target: dockTarget(), windows: [], message: message)

        let label = NSApplication.shared.windows
            .compactMap(\.contentView)
            .flatMap(\.subviews)
            .compactMap { $0 as? NSTextField }
            .first { $0.stringValue == message }
        let field = try XCTUnwrap(label)
        let root = try XCTUnwrap(field.superview)
        XCTAssertTrue(field.frame.origin.x.isFinite)
        XCTAssertTrue(field.frame.origin.y.isFinite)
        XCTAssertGreaterThan(field.frame.width, 0)
        XCTAssertGreaterThan(field.frame.height, 0)
        XCTAssertTrue(root.bounds.contains(field.frame))
    }

    func testFocusFailureDismissalDoesNotHideNewContentForTheSameTarget() async throws {
        let controller = PreviewPanelController(
            requestWindowFocus: { _, _, _, completion in completion(.unconfirmed) },
            requestWindowClose: { _, _, _, _ in }
        )
        defer { controller.hide() }
        controller.focusWindowAfterPreviewDismissal(previewInfo(), feedbackTarget: dockTarget())
        await settleMainActor()
        controller.show(target: dockTarget(), windows: [previewInfo()], message: nil)

        try await Task.sleep(nanoseconds: 2_100_000_000)

        XCTAssertNotNil(controller.frame)
        XCTAssertEqual(controller.displayedWindowCount, 1)
        XCTAssertNil(controller.displayedMessage)
    }

    func testConfirmedCloseRemovesWindowOnlyAfterCompletion() async {
        let info = previewInfo()
        var closeRequests = 0
        var closeCompletion: ((Bool) -> Void)?
        let controller = PreviewPanelController(
            requestWindowFocus: { _, _, _, _ in },
            requestWindowClose: { _, _, _, completion in
                closeRequests += 1
                closeCompletion = completion
            }
        )
        defer { controller.hide() }
        let closed = expectation(description: "confirmed window disappearance")
        controller.onWindowClosed = { closedInfo in
            XCTAssertTrue(closedInfo === info)
            closed.fulfill()
        }
        controller.show(target: dockTarget(), windows: [info], message: nil)

        controller.closeWindowFromPreview(info)
        controller.closeWindowFromPreview(info)

        XCTAssertEqual(closeRequests, 1)
        XCTAssertTrue(controller.isWindowClosePending(info))
        XCTAssertEqual(controller.displayedWindowCount, 1)

        closeCompletion?(true)
        await fulfillment(of: [closed], timeout: 1)

        XCTAssertFalse(controller.isWindowClosePending(info))
        XCTAssertEqual(controller.displayedWindowCount, 0)
    }

    func testCommandTabCloseUsesItsPresentationHandler() async {
        let info = previewInfo()
        var closeCompletion: ((Bool) -> Void)?
        var dockCloseCount = 0
        var commandTabCloseCount = 0
        let controller = PreviewPanelController(
            requestWindowFocus: { _, _, _, _ in },
            requestWindowClose: { _, _, _, completion in
                closeCompletion = completion
            }
        )
        defer { controller.hide() }
        controller.onWindowClosed = { _ in
            dockCloseCount += 1
        }
        controller.setPresentationHandler(
            for: .commandTab,
            onLifecycleEndRequested: {},
            onWindowClosed: { _ in
                commandTabCloseCount += 1
            }
        )
        controller.show(target: commandTabTarget(), windows: [info], message: nil)

        controller.closeWindowFromPreview(info)
        closeCompletion?(true)
        while controller.isWindowClosePending(info) {
            await Task.yield()
        }

        XCTAssertEqual(commandTabCloseCount, 1)
        XCTAssertEqual(dockCloseCount, 0)
    }

    func testConfirmedQuitUsesCurrentPresentationHandlerAndHidesPreview() async {
        let info = previewInfo()
        var events: [String] = []
        var quitCompletion: ((Bool) -> Void)?
        let controller = PreviewPanelController(
            requestWindowFocus: { _, _, _, _ in },
            requestWindowClose: { _, _, _, _ in },
            requestApplicationQuit: { processIdentifier, completion in
                events.append("quit:\(processIdentifier)")
                quitCompletion = completion
                return true
            }
        )
        defer { controller.hide() }
        controller.onApplicationQuitRequested = { processIdentifier in
            events.append("dock:\(processIdentifier)")
        }
        controller.onPreviewLifecycleEndRequested = {
            events.append("dock-lifecycle")
        }
        controller.setPresentationHandler(
            for: .commandTab,
            onLifecycleEndRequested: {
                events.append("command-tab-lifecycle")
            },
            onWindowClosed: { _ in },
            onApplicationQuitRequested: { processIdentifier in
                events.append("command-tab:\(processIdentifier)")
            }
        )
        controller.show(target: commandTabTarget(), windows: [info], message: nil)

        controller.quitApplicationFromPreview(info)

        XCTAssertEqual(events, ["quit:123"])
        XCTAssertEqual(controller.displayedWindowCount, 1)
        quitCompletion?(true)
        await settleMainActor()

        XCTAssertEqual(
            events,
            ["quit:123", "command-tab:123", "command-tab-lifecycle"]
        )
        XCTAssertNil(controller.frame)
    }

    func testConfirmedQuitUsesDockCallbacksWhenNoSpecialPresentationHandlerExists() async {
        let info = previewInfo()
        var events: [String] = []
        var quitCompletion: ((Bool) -> Void)?
        let controller = PreviewPanelController(
            requestWindowFocus: { _, _, _, _ in },
            requestWindowClose: { _, _, _, _ in },
            requestApplicationQuit: { processIdentifier, completion in
                events.append("quit:\(processIdentifier)")
                quitCompletion = completion
                return true
            }
        )
        defer { controller.hide() }
        controller.onApplicationQuitRequested = { processIdentifier in
            events.append("dock:\(processIdentifier)")
        }
        controller.onPreviewLifecycleEndRequested = {
            events.append("dock-lifecycle")
        }
        controller.show(target: dockTarget(), windows: [info], message: nil)

        controller.quitApplicationFromPreview(info)

        XCTAssertEqual(events, ["quit:123"])
        XCTAssertEqual(controller.displayedWindowCount, 1)
        quitCompletion?(true)
        await settleMainActor()

        XCTAssertEqual(events, ["quit:123", "dock:123", "dock-lifecycle"])
        XCTAssertNil(controller.frame)
    }

    func testFailedQuitKeepsPreviewAndShowsFeedback() {
        let info = previewInfo()
        let controller = PreviewPanelController(
            requestWindowFocus: { _, _, _, _ in },
            requestWindowClose: { _, _, _, _ in },
            requestApplicationQuit: { _, _ in false }
        )
        defer { controller.hide() }
        controller.show(target: dockTarget(), windows: [info], message: nil)

        controller.quitApplicationFromPreview(info)

        XCTAssertEqual(controller.displayedWindowCount, 1)
        XCTAssertEqual(controller.displayedMessage, AppStrings.text(.previewQuitFailed))
    }

    func testRejectedQuitConfirmationKeepsThePreviewVisible() async {
        let info = previewInfo()
        var quitCompletion: ((Bool) -> Void)?
        let controller = PreviewPanelController(
            requestWindowFocus: { _, _, _, _ in },
            requestWindowClose: { _, _, _, _ in },
            requestApplicationQuit: { _, completion in
                quitCompletion = completion
                return true
            }
        )
        defer { controller.hide() }
        controller.show(target: commandTabTarget(), windows: [info], message: nil)

        controller.quitApplicationFromPreview(info)
        quitCompletion?(false)
        await settleMainActor()

        XCTAssertEqual(controller.displayedWindowCount, 1)
        XCTAssertEqual(controller.displayedMessage, AppStrings.text(.previewQuitFailed))
    }

    func testCommandTabActionUsesTheExactPreviewWindowIdentity() {
        let first = previewInfo(id: "window-1", windowID: 42, title: "Same")
        let second = previewInfo(id: "window-2", windowID: 43, title: "Same")
        var closedWindowID: CGWindowID?
        let controller = PreviewPanelController(
            requestWindowFocus: { _, _, _, _ in },
            requestWindowClose: { _, _, windowID, _ in
                closedWindowID = windowID
            }
        )
        defer { controller.hide() }
        controller.show(target: commandTabTarget(), windows: [first, second], message: nil)

        controller.performCommandTabAction(.closeWindow(PreviewWindowIdentity(second)))

        XCTAssertEqual(closedWindowID, second.windowID)
    }

    func testCommandTabButtonTargetsUsePanelCoordinatesAndKeepQuitOnTheLeft() throws {
        let info = previewInfo()
        let controller = PreviewPanelController(
            requestWindowFocus: { _, _, _, _ in },
            requestWindowClose: { _, _, _, _ in }
        )
        defer { controller.hide() }
        controller.show(target: commandTabTarget(), windows: [info], message: nil)

        let panelFrame = try XCTUnwrap(controller.frame)
        let targets = controller.commandTabButtonHitTargets()
        let quitTarget = try XCTUnwrap(targets.first { target in
            if case .quitApplication = target.action {
                return true
            }
            return false
        })
        let closeTarget = try XCTUnwrap(targets.first { target in
            if case .closeWindow = target.action {
                return true
            }
            return false
        })

        XCTAssertTrue(panelFrame.contains(quitTarget.screenFrame))
        XCTAssertTrue(panelFrame.contains(closeTarget.screenFrame))
        XCTAssertLessThan(quitTarget.screenFrame.midX, closeTarget.screenFrame.midX)
    }

    func testFailedCloseKeepsWindowAndShowsExistingFeedback() async {
        let info = previewInfo()
        var closeCompletion: ((Bool) -> Void)?
        var closedWindowCount = 0
        let controller = PreviewPanelController(
            requestWindowFocus: { _, _, _, _ in },
            requestWindowClose: { _, _, _, completion in
                closeCompletion = completion
            }
        )
        defer { controller.hide() }
        controller.onWindowClosed = { _ in
            closedWindowCount += 1
        }
        controller.show(target: dockTarget(), windows: [info], message: nil)
        controller.closeWindowFromPreview(info)

        closeCompletion?(false)
        while controller.isWindowClosePending(info) {
            await Task.yield()
        }

        XCTAssertEqual(closedWindowCount, 0)
        XCTAssertEqual(controller.displayedWindowCount, 1)
        XCTAssertEqual(
            controller.displayedMessage,
            AppStrings.text(.previewCloseFailed)
        )
    }

    func testDelayedCloseFailureDoesNotAppearOnDifferentTarget() async {
        let firstInfo = previewInfo()
        let secondInfo = previewInfo(
            id: "window-2",
            windowID: 52,
            processIdentifier: 456,
            title: "Other"
        )
        var closeCompletion: ((Bool) -> Void)?
        let controller = PreviewPanelController(
            requestWindowFocus: { _, _, _, _ in },
            requestWindowClose: { _, _, _, completion in
                closeCompletion = completion
            }
        )
        defer { controller.hide() }
        controller.show(target: dockTarget(), windows: [firstInfo], message: nil)
        controller.closeWindowFromPreview(firstInfo)
        controller.show(
            target: dockTarget(
                processIdentifier: 456,
                identifier: "dock-item:other"
            ),
            windows: [secondInfo],
            message: nil
        )

        closeCompletion?(false)
        while controller.isWindowClosePending(firstInfo) {
            await Task.yield()
        }

        XCTAssertEqual(controller.displayedWindowCount, 1)
        XCTAssertNil(controller.displayedMessage)
    }

    private func dockTarget(
        processIdentifier: pid_t = 123,
        identifier: String = "dock-item:example"
    ) -> DockAppTarget {
        DockAppTarget(
            processIdentifier: processIdentifier,
            bundleIdentifier: "com.example.app",
            localizedName: "Example",
            dockElementTitle: "Example",
            hitPoint: CGPoint(x: 100, y: 20),
            dockItemFrame: CGRect(x: 80, y: 0, width: 48, height: 48),
            dockTileIdentifierOverride: identifier
        )
    }

    private func commandTabTarget() -> DockAppTarget {
        DockAppTarget(
            processIdentifier: 123,
            bundleIdentifier: "com.example.app",
            localizedName: "Example",
            dockElementTitle: "Example",
            hitPoint: CGPoint(x: 100, y: 300),
            dockItemFrame: CGRect(x: 72, y: 272, width: 56, height: 56),
            dockTileIdentifierOverride: "command-tab:123",
            previewAnchorKind: .commandTab
        )
    }

    private func windowCycleTarget() -> DockAppTarget {
        DockAppTarget(
            processIdentifier: 123,
            bundleIdentifier: "com.example.app",
            localizedName: "Example",
            dockElementTitle: "Example",
            hitPoint: CGPoint(x: 600, y: 400),
            dockItemFrame: CGRect(x: 572, y: 372, width: 56, height: 56),
            dockTileIdentifierOverride: "window-cycle:1",
            previewAnchorKind: .windowCycle
        )
    }

    private func previewInfo(
        id: String = "window-1",
        windowID: CGWindowID = 42,
        processIdentifier: pid_t = 123,
        title: String = "Document",
        frame: CGRect = CGRect(x: 0, y: 0, width: 1200, height: 800)
    ) -> PreviewWindowInfo {
        PreviewWindowInfo(
            id: id,
            windowID: windowID,
            processIdentifier: processIdentifier,
            appName: "Example",
            title: title,
            frame: frame,
            isMinimized: false
        )
    }

    private func settleMainActor() async {
        for _ in 0 ..< 3 {
            await Task.yield()
        }
    }
}
