import CoreGraphics
import XCTest
@testable import OmniDockCore

final class WindowControlPoliciesTests: XCTestCase {
    func testHotkeyUsesWorkspaceFrontmostApplicationWhenAvailable() {
        XCTAssertFalse(AppHotkeyTopmostPolicy.isTopmost(
            targetProcessIdentifier: 21,
            workspaceFrontmostProcessIdentifier: 99,
            orderedVisibleWindowOwnerProcessIdentifiers: [21, 99]
        ))
        XCTAssertTrue(AppHotkeyTopmostPolicy.isTopmost(
            targetProcessIdentifier: 21,
            workspaceFrontmostProcessIdentifier: 21,
            orderedVisibleWindowOwnerProcessIdentifiers: [99, 21]
        ))
    }

    func testHotkeyFallsBackToVisibleWindowOrderWhenWorkspaceHasNoFrontmostApplication() {
        XCTAssertTrue(AppHotkeyTopmostPolicy.isTopmost(
            targetProcessIdentifier: 21,
            workspaceFrontmostProcessIdentifier: nil,
            orderedVisibleWindowOwnerProcessIdentifiers: [21, 99]
        ))
        XCTAssertFalse(AppHotkeyTopmostPolicy.isTopmost(
            targetProcessIdentifier: 21,
            workspaceFrontmostProcessIdentifier: nil,
            orderedVisibleWindowOwnerProcessIdentifiers: [99, 21]
        ))
    }

    func testDesktopRevealIsUsedWhenTargetOwnsEveryVisibleApplicationWindow() {
        XCTAssertTrue(ApplicationHidePolicy.shouldRevealDesktop(
            targetProcessIdentifier: 10,
            visibleWindowOwnerProcessIdentifiers: [10, 10]
        ))
    }

    func testDesktopRevealIsNotUsedWhenAnotherApplicationHasAVisibleWindow() {
        XCTAssertFalse(ApplicationHidePolicy.shouldRevealDesktop(
            targetProcessIdentifier: 10,
            visibleWindowOwnerProcessIdentifiers: [10, 20]
        ))
    }

    func testDesktopRevealIsNotUsedWhenTargetHasNoVisibleWindow() {
        XCTAssertFalse(ApplicationHidePolicy.shouldRevealDesktop(
            targetProcessIdentifier: 10,
            visibleWindowOwnerProcessIdentifiers: []
        ))
    }

    func testDesktopRevealTreatsOmniDockManagementWindowAsAnotherVisibleWindow() {
        XCTAssertFalse(ApplicationHidePolicy.shouldRevealDesktop(
            targetProcessIdentifier: 10,
            visibleWindowOwnerProcessIdentifiers: [10, 99]
        ))
    }

    func testDesktopRevealCanBeDisabledForNonDockInteractions() {
        XCTAssertFalse(ApplicationHidePolicy.shouldRevealDesktop(
            targetProcessIdentifier: 10,
            visibleWindowOwnerProcessIdentifiers: [10, 10],
            isAllowed: false
        ))
    }

    func testDesktopRevealStateRestoresTheSameApplication() {
        var state = DesktopRevealState()
        state.begin(for: 10)

        XCTAssertEqual(state.resolve(for: 10), .restore)
        XCTAssertNil(state.ownerProcessIdentifier)
    }

    func testDesktopRevealStateSwitchesToAnotherApplication() {
        var state = DesktopRevealState()
        state.begin(for: 10)

        XCTAssertEqual(
            state.resolve(for: 20),
            .switchApplication(previousOwnerProcessIdentifier: 10)
        )
        XCTAssertEqual(state.resolve(for: 20), .none)
    }

    func testHideRetryRequiresBothUnhiddenStateAndOnscreenWindow() {
        XCTAssertTrue(ApplicationHidePolicy.shouldRetryHide(
            isHidden: false,
            onscreenNormalWindowCount: 1
        ))
        XCTAssertFalse(ApplicationHidePolicy.shouldRetryHide(
            isHidden: true,
            onscreenNormalWindowCount: 1
        ))
        XCTAssertFalse(ApplicationHidePolicy.shouldRetryHide(
            isHidden: false,
            onscreenNormalWindowCount: 0
        ))
    }

    func testDesktopRevealValidationRequiresRunningUnhiddenOwnerAndNoVisibleWindows() {
        XCTAssertTrue(ApplicationHidePolicy.isDesktopRevealActive(
            isOwnerRunning: true,
            isOwnerHidden: false,
            visibleWindowOwnerProcessIdentifiers: []
        ))
        XCTAssertFalse(ApplicationHidePolicy.isDesktopRevealActive(
            isOwnerRunning: false,
            isOwnerHidden: false,
            visibleWindowOwnerProcessIdentifiers: []
        ))
        XCTAssertFalse(ApplicationHidePolicy.isDesktopRevealActive(
            isOwnerRunning: true,
            isOwnerHidden: true,
            visibleWindowOwnerProcessIdentifiers: []
        ))
        XCTAssertFalse(ApplicationHidePolicy.isDesktopRevealActive(
            isOwnerRunning: true,
            isOwnerHidden: false,
            visibleWindowOwnerProcessIdentifiers: [10]
        ))
    }

    func testDesktopRevealStateKeepsShortcutUntilResolvedOrInvalidated() {
        let shortcut = ShowDesktopShortcut(
            keyCode: 42,
            flags: [.maskCommand, .maskAlternate]
        )
        var state = DesktopRevealState()

        state.begin(for: 10, shortcut: shortcut)
        XCTAssertEqual(state.shortcut, shortcut)

        state.invalidate()
        XCTAssertNil(state.ownerProcessIdentifier)
        XCTAssertNil(state.shortcut)
    }

    func testShowDesktopShortcutResolverReadsEnabledCustomShortcut() {
        let flags: CGEventFlags = [.maskCommand, .maskAlternate, .maskSecondaryFn]

        XCTAssertEqual(
            ShowDesktopShortcutResolver.shortcut(from: showDesktopPreferences(
                enabled: true,
                keyCode: 42,
                flags: flags.rawValue
            )),
            ShowDesktopShortcut(keyCode: 42, flags: flags)
        )
    }

    func testShowDesktopShortcutResolverRejectsDisabledOrMalformedPreference() {
        XCTAssertNil(ShowDesktopShortcutResolver.shortcut(from: showDesktopPreferences(
            enabled: false,
            keyCode: 42,
            flags: 0
        )))
        XCTAssertNil(ShowDesktopShortcutResolver.shortcut(from: [
            "36": [
                "enabled": true,
                "value": [
                    "type": "standard",
                    "parameters": [65535, "not-a-key-code", 0]
                ]
            ]
        ]))
        XCTAssertNil(ShowDesktopShortcutResolver.shortcut(from: [
            "36": ["enabled": true]
        ]))
    }

    func testShowDesktopShortcutResolverRejectsUnsupportedFlagsAndNonstandardValues() {
        XCTAssertNil(ShowDesktopShortcutResolver.shortcut(from: showDesktopPreferences(
            enabled: true,
            keyCode: 42,
            flags: UInt64(1) << 31
        )))
        XCTAssertNil(ShowDesktopShortcutResolver.shortcut(from: [
            "36": [
                "enabled": true,
                "value": [
                    "type": "modifier",
                    "parameters": [65535, 42, 0]
                ]
            ]
        ]))
    }

    func testFocusMatchUsesExactIdentifierForDuplicateWindowTitles() {
        let candidates = [
            WindowFocusCandidate(index: 0, windowID: 10, title: "Start Page"),
            WindowFocusCandidate(index: 1, windowID: 20, title: "Start Page"),
            WindowFocusCandidate(index: 2, windowID: 30, title: "Start Page")
        ]

        XCTAssertEqual(
            WindowFocusMatchPolicy.matchingIndex(
                in: candidates,
                title: "Start Page",
                windowID: 20
            ),
            1
        )
    }

    func testFocusMatchUsesUniqueTitleWhenIdentifiersAreUnavailable() {
        let candidates = [
            WindowFocusCandidate(index: 0, windowID: nil, title: "First"),
            WindowFocusCandidate(index: 1, windowID: nil, title: "Second")
        ]

        XCTAssertEqual(
            WindowFocusMatchPolicy.matchingIndex(
                in: candidates,
                title: "Second",
                windowID: nil
            ),
            1
        )
    }

    func testFocusMatchDoesNotReplaceAStaleIdentifierWithAnotherWindow() {
        let candidates = [
            WindowFocusCandidate(index: 0, windowID: 10, title: "Document"),
            WindowFocusCandidate(index: 1, windowID: 20, title: "Document")
        ]

        XCTAssertNil(WindowFocusMatchPolicy.matchingIndex(
            in: candidates,
            title: "Document",
            windowID: 30
        ))
    }

    func testFocusMatchRejectsAmbiguousTitleWithoutIdentifiers() {
        let candidates = [
            WindowFocusCandidate(index: 0, windowID: nil, title: "Document"),
            WindowFocusCandidate(index: 1, windowID: nil, title: "Document")
        ]

        XCTAssertNil(WindowFocusMatchPolicy.matchingIndex(
            in: candidates,
            title: "Document",
            windowID: nil
        ))
    }

    func testFocusMatchUsesTheOnlyCandidateWhenIdentifiersAreUnavailable() {
        let candidates = [
            WindowFocusCandidate(index: 0, windowID: nil, title: nil)
        ]

        XCTAssertEqual(
            WindowFocusMatchPolicy.matchingIndex(
                in: candidates,
                title: nil,
                windowID: nil
            ),
            0
        )
    }

    func testCloseMatchUsesExactWindowIdentifier() {
        let candidates = [
            WindowCloseCandidate(index: 0, windowID: 10, title: "Document"),
            WindowCloseCandidate(index: 1, windowID: 20, title: "Document")
        ]

        XCTAssertEqual(
            WindowCloseMatchPolicy.matchingIndex(
                in: candidates,
                title: "Document",
                windowID: 20
            ),
            1
        )
    }

    func testCloseMatchDoesNotFallBackWhenWindowIdentifierIsStale() {
        let candidates = [
            WindowCloseCandidate(index: 0, windowID: 10, title: "Document")
        ]

        XCTAssertNil(WindowCloseMatchPolicy.matchingIndex(
            in: candidates,
            title: "Document",
            windowID: 20
        ))
    }

    func testCloseMatchAcceptsUniqueTitleWhenIdentifierIsUnavailable() {
        let candidates = [
            WindowCloseCandidate(index: 0, windowID: nil, title: "First"),
            WindowCloseCandidate(index: 1, windowID: nil, title: "Second")
        ]

        XCTAssertEqual(
            WindowCloseMatchPolicy.matchingIndex(
                in: candidates,
                title: "Second",
                windowID: nil
            ),
            1
        )
    }

    func testCloseMatchFallsBackToUniqueTitleWhenAXIdentifiersAreUnavailable() {
        let candidates = [
            WindowCloseCandidate(index: 0, windowID: nil, title: "First"),
            WindowCloseCandidate(index: 1, windowID: nil, title: "Second")
        ]

        XCTAssertEqual(
            WindowCloseMatchPolicy.matchingIndex(
                in: candidates,
                title: "Second",
                windowID: 99
            ),
            1
        )
    }

    func testCloseMatchUsesOnlyCandidateWhenAXIdentityIsUnavailable() {
        let candidates = [
            WindowCloseCandidate(index: 0, windowID: nil, title: nil)
        ]

        XCTAssertEqual(
            WindowCloseMatchPolicy.matchingIndex(
                in: candidates,
                title: nil,
                windowID: 99
            ),
            0
        )
    }

    func testCloseMatchRejectsAmbiguousOrEmptyTitles() {
        let candidates = [
            WindowCloseCandidate(index: 0, windowID: nil, title: "Document"),
            WindowCloseCandidate(index: 1, windowID: nil, title: "Document")
        ]

        XCTAssertNil(WindowCloseMatchPolicy.matchingIndex(
            in: candidates,
            title: "Document",
            windowID: nil
        ))
        XCTAssertNil(WindowCloseMatchPolicy.matchingIndex(
            in: candidates,
            title: nil,
            windowID: nil
        ))
    }

    func testCloseVerificationTracksExactWindowIdentifier() {
        let target = WindowCloseVerificationTarget(windowID: 20, title: "Document")
        let candidates = [
            WindowCloseCandidate(index: 0, windowID: 10, title: "Document"),
            WindowCloseCandidate(index: 1, windowID: 20, title: "Renamed")
        ]

        XCTAssertTrue(WindowCloseVerificationPolicy.targetIsPresent(target, in: candidates))
        XCTAssertFalse(WindowCloseVerificationPolicy.targetIsPresent(
            target,
            in: [WindowCloseCandidate(index: 0, windowID: 10, title: "Document")]
        ))
    }

    func testCloseVerificationUsesTitleAndSingleWindowFallbackWithoutIdentifier() {
        XCTAssertTrue(WindowCloseVerificationPolicy.targetIsPresent(
            WindowCloseVerificationTarget(windowID: nil, title: "Document"),
            in: [WindowCloseCandidate(index: 0, windowID: nil, title: "Document")]
        ))
        XCTAssertTrue(WindowCloseVerificationPolicy.targetIsPresent(
            WindowCloseVerificationTarget(windowID: nil, title: nil),
            in: [WindowCloseCandidate(index: 0, windowID: nil, title: "Anything")]
        ))
        XCTAssertFalse(WindowCloseVerificationPolicy.targetIsPresent(
            WindowCloseVerificationTarget(windowID: nil, title: nil),
            in: []
        ))
    }

    func testCloseVerificationFailsForDialogOrExhaustedWindowAndSucceedsAfterDisappearance() {
        XCTAssertEqual(WindowCloseVerificationPolicy.decision(
            targetIsPresent: false,
            blockingDialogAppeared: false,
            attemptsRemaining: 4
        ), .success)
        XCTAssertEqual(WindowCloseVerificationPolicy.decision(
            targetIsPresent: false,
            blockingDialogAppeared: true,
            attemptsRemaining: 4
        ), .failure)
        XCTAssertEqual(WindowCloseVerificationPolicy.decision(
            targetIsPresent: true,
            blockingDialogAppeared: false,
            attemptsRemaining: 1
        ), .retry)
        XCTAssertEqual(WindowCloseVerificationPolicy.decision(
            targetIsPresent: true,
            blockingDialogAppeared: false,
            attemptsRemaining: 0
        ), .failure)
    }

    func testCloseVerificationRetriesFailedAXQueryWithoutReportingSuccess() {
        XCTAssertEqual(WindowCloseVerificationPolicy.decision(
            querySucceeded: false,
            targetIsPresent: false,
            blockingDialogAppeared: false,
            attemptsRemaining: 1
        ), .retry)
        XCTAssertEqual(WindowCloseVerificationPolicy.decision(
            querySucceeded: false,
            targetIsPresent: false,
            blockingDialogAppeared: false,
            attemptsRemaining: 0
        ), .failure)
    }

    func testBulkDeduplicationUsesWindowNumberBeforeFrame() {
        let candidates = [
            BulkWindowCandidate(index: 0, windowID: 10, title: "Document", frame: frame()),
            BulkWindowCandidate(index: 1, windowID: 20, title: "Document", frame: frame()),
            BulkWindowCandidate(index: 2, windowID: 10, title: "Moved", frame: frame(x: 200))
        ]

        XCTAssertEqual(BulkWindowDeduplicationPolicy.uniqueIndices(in: candidates), [0, 1])
    }

    func testBulkDeduplicationDoesNotMergeNumberedAndFallbackWindows() {
        let candidates = [
            BulkWindowCandidate(index: 0, windowID: 10, title: "Document", frame: frame()),
            BulkWindowCandidate(index: 1, windowID: nil, title: "Document", frame: frame())
        ]

        XCTAssertEqual(BulkWindowDeduplicationPolicy.uniqueIndices(in: candidates), [0, 1])
    }

    func testBulkDeduplicationUsesTitleAndFrameOnlyWhenIdentifierIsMissing() {
        let candidates = [
            BulkWindowCandidate(index: 0, windowID: nil, title: "Document", frame: frame()),
            BulkWindowCandidate(index: 1, windowID: nil, title: "Document", frame: frame()),
            BulkWindowCandidate(index: 2, windowID: nil, title: "Other", frame: frame()),
            BulkWindowCandidate(index: 3, windowID: nil, title: "Document", frame: frame(x: 200))
        ]

        XCTAssertEqual(BulkWindowDeduplicationPolicy.uniqueIndices(in: candidates), [0, 2, 3])
    }

    func testBulkDeduplicationKeepsIncompleteFallbackIdentities() {
        let candidates = [
            BulkWindowCandidate(index: 0, windowID: nil, title: nil, frame: frame()),
            BulkWindowCandidate(index: 1, windowID: nil, title: nil, frame: frame()),
            BulkWindowCandidate(index: 2, windowID: nil, title: "Document", frame: .zero),
            BulkWindowCandidate(index: 3, windowID: nil, title: "Document", frame: .zero)
        ]

        XCTAssertEqual(BulkWindowDeduplicationPolicy.uniqueIndices(in: candidates), [0, 1, 2, 3])
    }

    private func showDesktopPreferences(
        enabled: Bool,
        keyCode: Int,
        flags: UInt64
    ) -> [String: Any] {
        [
            "36": [
                "enabled": enabled,
                "value": [
                    "type": "standard",
                    "parameters": [65535, keyCode, flags]
                ]
            ]
        ]
    }

    private func frame(x: CGFloat = 0) -> CGRect {
        CGRect(x: x, y: 20, width: 800, height: 600)
    }
}
