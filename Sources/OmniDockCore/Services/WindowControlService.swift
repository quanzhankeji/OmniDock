import AppKit
import ApplicationServices
import CoreGraphics

public struct WindowInteractionSummary {
    public let normalWindowCount: Int
    public let unminimizedNormalWindowCount: Int
    public let minimizedNormalWindowCount: Int
    public let onscreenNormalWindowCount: Int

    public var hasVisibleNormalWindow: Bool {
        unminimizedNormalWindowCount > 0 && onscreenNormalWindowCount > 0
    }
}

public struct WindowTileInteractionSummary {
    public let isTopmost: Bool
    public let visibleWindowCount: Int

    public var hasVisibleWindow: Bool {
        visibleWindowCount > 0
    }
}

private struct RememberedWindowTarget: Equatable {
    let title: String?
    let windowID: CGWindowID?
    let applicationLaunchDate: Date?
}

private struct PendingWindowClose {
    let processIdentifier: pid_t
    let targetElement: AXUIElement
    let verificationTarget: WindowCloseVerificationTarget
    let blockingDialogsBeforeClose: [AXUIElement]
}

private struct AXWindowQueryResult {
    let windows: [AXUIElement]
    let succeeded: Bool
}

private final class ApplicationQuitCompletionState {
    private var didFinish = false
    private let completion: (Bool) -> Void
    var terminationObserver: NSObjectProtocol?

    init(completion: @escaping (Bool) -> Void) {
        self.completion = completion
    }

    func finish(_ didTerminate: Bool) {
        guard !didFinish else {
            return
        }
        didFinish = true
        if let terminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(terminationObserver)
            self.terminationObserver = nil
        }
        completion(didTerminate)
    }
}

public final class WindowControlService {
    private static let closeVerificationInterval: TimeInterval = 0.1
    private static let closeVerificationAttempts = 8
    private static let quitVerificationTimeout: TimeInterval = 1.5

    private var rememberedWindowTargets: [pid_t: RememberedWindowTarget] = [:]
    private let operationTracker = WindowOperationGenerationTracker()
    private let closeVerificationQueue = DispatchQueue(
        label: "com.quanzhankeji.OmniDock.window-close-verification",
        qos: .userInitiated
    )
    private var desktopRevealState = DesktopRevealState()

    public init() {}

    public func interactionSummary(for processIdentifier: pid_t) -> WindowInteractionSummary {
        let appElement = AXUIElementCreateApplication(processIdentifier)
        var normalWindowCount = 0
        var unminimizedNormalWindowCount = 0
        var minimizedNormalWindowCount = 0

        for window in windows(for: appElement) {
            let role = stringAttribute(kAXRoleAttribute, from: window)
            let subrole = stringAttribute(kAXSubroleAttribute, from: window)
            guard WindowFiltering.isNormalAXWindow(role: role, subrole: subrole) else {
                continue
            }

            normalWindowCount += 1
            if boolAttribute(kAXMinimizedAttribute, from: window) ?? false {
                minimizedNormalWindowCount += 1
            } else {
                unminimizedNormalWindowCount += 1
            }
        }

        return WindowInteractionSummary(
            normalWindowCount: normalWindowCount,
            unminimizedNormalWindowCount: unminimizedNormalWindowCount,
            minimizedNormalWindowCount: minimizedNormalWindowCount,
            onscreenNormalWindowCount: onscreenNormalWindowCount(for: processIdentifier)
        )
    }

    func hasNormalWindow(processIdentifier: pid_t) -> Bool {
        let appElement = AXUIElementCreateApplication(processIdentifier)
        return windows(for: appElement).contains { window in
            WindowFiltering.isNormalAXWindow(
                role: stringAttribute(kAXRoleAttribute, from: window),
                subrole: stringAttribute(kAXSubroleAttribute, from: window)
            )
        }
    }

    public func isApplicationTopmost(processIdentifier: pid_t) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier
    }

    func isApplicationDisplacedByDesktopReveal(processIdentifier: pid_t) -> Bool {
        guard desktopRevealState.ownerProcessIdentifier == processIdentifier else {
            return false
        }
        guard isDesktopRevealActive(ownerProcessIdentifier: processIdentifier) else {
            desktopRevealState.invalidate()
            return false
        }
        return true
    }

    public func windowTileInteractionSummary(for target: DockAppTarget) -> WindowTileInteractionSummary {
        windowTileInteractionSummary(for: target.processIdentifier)
    }

    public func windowTileInteractionSummary(for processIdentifier: pid_t) -> WindowTileInteractionSummary {
        let summary = interactionSummary(for: processIdentifier)
        return WindowTileInteractionSummary(
            isTopmost: isApplicationTopmost(processIdentifier: processIdentifier),
            visibleWindowCount: summary.onscreenNormalWindowCount
        )
    }

    public func shouldInterceptWindowTileClick(target: DockAppTarget) -> Bool {
        shouldInterceptWindowTileClick(processIdentifier: target.processIdentifier)
    }

    public func shouldInterceptWindowTileClick(processIdentifier: pid_t) -> Bool {
        guard let application = NSRunningApplication(processIdentifier: processIdentifier) else {
            return false
        }
        let summary = interactionSummary(for: processIdentifier)
        return WindowFiltering.shouldInterceptDockClick(
            isTopmost: isApplicationTopmost(processIdentifier: processIdentifier),
            isHidden: application.isHidden,
            unminimizedNormalWindowCount: summary.unminimizedNormalWindowCount,
            onscreenNormalWindowCount: summary.onscreenNormalWindowCount
        )
    }

    public func toggleWindowTileApplication(target: DockAppTarget) {
        _ = toggleApplicationDockTile(target: target)
    }

    public func toggleWindowTileApplication(processIdentifier: pid_t) {
        _ = toggleRunningApplication(processIdentifier: processIdentifier)
    }

    @discardableResult
    public func toggleApplicationDockTile(
        target: DockAppTarget,
        prefersMinimizeInsteadOfHide: Bool = false,
        beforeHide: ((@escaping () -> Void) -> Void)? = nil
    ) -> DockIconClickAction? {
        toggleRunningApplication(
            processIdentifier: target.processIdentifier,
            prefersMinimizeInsteadOfHide: prefersMinimizeInsteadOfHide,
            beforeHide: beforeHide
        )
    }

    @discardableResult
    public func toggleRunningApplication(
        processIdentifier: pid_t,
        prefersMinimizeInsteadOfHide: Bool = false,
        beforeHide: ((@escaping () -> Void) -> Void)? = nil
    ) -> DockIconClickAction? {
        switch resolvePendingDesktopReveal(for: processIdentifier) {
        case .restore:
            _ = operationTracker.begin(.bring, for: processIdentifier)
            return .bringApplicationToFront
        case .switchApplication:
            bringApplicationToFront(processIdentifier: processIdentifier)
            return .bringApplicationToFront
        case .none:
            break
        }

        if operationTracker.hasPendingHide(for: processIdentifier) {
            bringApplicationToFront(processIdentifier: processIdentifier)
            return .bringApplicationToFront
        }

        guard let app = NSRunningApplication(processIdentifier: processIdentifier) else {
            return nil
        }

        let summary = interactionSummary(for: processIdentifier)
        let action = WindowFiltering.dockIconClickAction(
            isTopmost: isApplicationTopmost(processIdentifier: processIdentifier),
            isHidden: app.isHidden,
            unminimizedNormalWindowCount: summary.unminimizedNormalWindowCount,
            onscreenNormalWindowCount: summary.onscreenNormalWindowCount,
            prefersMinimizeInsteadOfHide: prefersMinimizeInsteadOfHide
        )
        if action == .hideApplication, let beforeHide {
            performAfterPendingHideCapture(
                processIdentifier: processIdentifier,
                beforeHide: beforeHide
            ) { [weak self] in
                self?.performDockIconClickAction(action, processIdentifier: processIdentifier)
            }
        } else {
            performDockIconClickAction(action, processIdentifier: processIdentifier)
        }
        return action
    }

    public func performDockIconClickAction(_ action: DockIconClickAction, processIdentifier: pid_t) {
        switch action {
        case .bringApplicationToFront:
            bringApplicationToFront(processIdentifier: processIdentifier)
        case .hideApplication:
            hideApplication(processIdentifier: processIdentifier)
        case .minimizeApplicationWindows:
            minimizeApplicationWindows(processIdentifier: processIdentifier)
        }
    }

    public func hideApplication(processIdentifier: pid_t) {
        let token = operationTracker.begin(.hide, for: processIdentifier)
        hideApplication(processIdentifier: processIdentifier, token: token)
    }

    private func hideApplication(processIdentifier: pid_t, token: WindowOperationToken) {
        guard token.processIdentifier == processIdentifier,
              operationTracker.isForegroundCurrent(token),
              let app = NSRunningApplication(processIdentifier: processIdentifier)
        else {
            return
        }

        let onscreenOwnerProcessIdentifiers = onscreenNormalWindowOwnerProcessIdentifiers()
        let shouldRevealDesktop = ApplicationHidePolicy.shouldRevealDesktop(
            targetProcessIdentifier: processIdentifier,
            visibleWindowOwnerProcessIdentifiers: onscreenOwnerProcessIdentifiers
        )
        if shouldRevealDesktop {
            if let shortcut = revealDesktopUsingCurrentShortcut() {
                desktopRevealState.begin(for: processIdentifier, shortcut: shortcut)
                return
            }
        }

        _ = app.hide()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self,
                  self.operationTracker.isForegroundCurrent(token),
                  let application = NSRunningApplication(processIdentifier: processIdentifier)
            else {
                return
            }
            let onscreenWindowCount = self.onscreenNormalWindowCount(for: processIdentifier)
            guard ApplicationHidePolicy.shouldRetryHide(
                isHidden: application.isHidden,
                onscreenNormalWindowCount: onscreenWindowCount
            ) else {
                return
            }

            let appElement = AXUIElementCreateApplication(processIdentifier)
            self.pressHideMenuItemIfAvailable(
                appElement: appElement,
                operationToken: token
            )
            if self.onscreenNormalWindowCount(for: processIdentifier) > 0 {
                self.hideApplicationUsingAccessibility(appElement: appElement)
            }
        }
    }

    private func resolvePendingDesktopReveal(
        for processIdentifier: pid_t
    ) -> DesktopRevealResolution {
        guard let ownerProcessIdentifier = desktopRevealState.ownerProcessIdentifier else {
            return .none
        }
        guard isDesktopRevealActive(ownerProcessIdentifier: ownerProcessIdentifier) else {
            desktopRevealState.invalidate()
            return .none
        }

        let revealShortcut = desktopRevealState.shortcut
        let resolution = desktopRevealState.resolve(for: processIdentifier)
        switch resolution {
        case .none:
            break
        case .restore:
            guard let revealShortcut,
                  ShowDesktopShortcutResolver.currentShortcut() == revealShortcut,
                  postShowDesktopShortcut(revealShortcut)
            else {
                return .none
            }
        case let .switchApplication(previousOwnerProcessIdentifier):
            _ = NSRunningApplication(processIdentifier: previousOwnerProcessIdentifier)?.hide()
        }
        return resolution
    }

    private func isDesktopRevealActive(ownerProcessIdentifier: pid_t) -> Bool {
        let owner = NSRunningApplication(processIdentifier: ownerProcessIdentifier)
        return ApplicationHidePolicy.isDesktopRevealActive(
            isOwnerRunning: owner != nil,
            isOwnerHidden: owner?.isHidden ?? true,
            visibleWindowOwnerProcessIdentifiers: onscreenNormalWindowOwnerProcessIdentifiers()
        )
    }

    private func revealDesktopUsingCurrentShortcut() -> ShowDesktopShortcut? {
        guard let shortcut = ShowDesktopShortcutResolver.currentShortcut(),
              postShowDesktopShortcut(shortcut)
        else {
            return nil
        }
        return shortcut
    }

    private func postShowDesktopShortcut(_ shortcut: ShowDesktopShortcut) -> Bool {
        guard CGPreflightPostEventAccess() else {
            return false
        }

        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(
            keyboardEventSource: source,
            virtualKey: shortcut.keyCode,
            keyDown: true
        )
        let keyUp = CGEvent(
            keyboardEventSource: source,
            virtualKey: shortcut.keyCode,
            keyDown: false
        )
        guard let keyDown, let keyUp else {
            return false
        }
        keyDown.flags = shortcut.flags
        keyUp.flags = shortcut.flags
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    public func minimizeApplicationWindows(processIdentifier: pid_t) {
        let token = operationTracker.begin(.minimize, for: processIdentifier)
        minimizeApplicationWindows(processIdentifier: processIdentifier, token: token)
    }

    private func minimizeApplicationWindows(processIdentifier: pid_t, token: WindowOperationToken) {
        guard token.processIdentifier == processIdentifier,
              operationTracker.isForegroundCurrent(token)
        else {
            return
        }

        let beforeOnscreenCount = onscreenNormalWindowCount(for: processIdentifier)
        let appElement = AXUIElementCreateApplication(processIdentifier)
        let normalWindows = normalWindows(in: windows(for: appElement))
        for window in normalWindows {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self,
                  self.operationTracker.isForegroundCurrent(token)
            else {
                return
            }
            let afterOnscreenCount = self.onscreenNormalWindowCount(for: processIdentifier)
            guard WindowFiltering.shouldFallbackToHideAfterMinimize(
                beforeOnscreenNormalWindowCount: beforeOnscreenCount,
                afterOnscreenNormalWindowCount: afterOnscreenCount
            ) else {
                return
            }
            self.hideApplication(processIdentifier: processIdentifier, token: token)
        }
    }

    private func performAfterPendingHideCapture(
        processIdentifier: pid_t,
        beforeHide: (@escaping () -> Void) -> Void,
        action: @escaping () -> Void
    ) {
        let token = operationTracker.beginPendingHide(for: processIdentifier)
        beforeHide { [weak self] in
            guard let self,
                  self.operationTracker.consumePendingHide(token)
            else {
                return
            }
            action()
        }
    }

    public func bringApplicationToFront(processIdentifier: pid_t) {
        let token = operationTracker.begin(.bring, for: processIdentifier)
        bringApplicationToFront(processIdentifier: processIdentifier, token: token)
    }

    private func bringApplicationToFront(processIdentifier: pid_t, token: WindowOperationToken) {
        guard token.processIdentifier == processIdentifier,
              operationTracker.isForegroundCurrent(token)
        else {
            return
        }
        guard let app = NSRunningApplication(processIdentifier: processIdentifier) else {
            rememberedWindowTargets.removeValue(forKey: processIdentifier)
            return
        }

        if resolvePendingDesktopReveal(for: processIdentifier) == .restore {
            return
        }

        let appElement = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetAttributeValue(appElement, kAXHiddenAttribute as CFString, kCFBooleanFalse)
        app.unhide()
        let focusCandidates = normalWindowCandidates(in: windows(for: appElement))
        let independentWindows = deduplicatedIndependentWindows(focusCandidates)
        for window in independentWindows {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }

        makeFrontmost(app, appElement: appElement, allWindows: true)
        if let rememberedTarget = rememberedWindowTargets[processIdentifier] {
            restoreRememberedWindow(
                rememberedTarget,
                for: app,
                operationToken: token,
                attemptsRemaining: 2
            )
        }
    }

    public func ensureApplicationWindow(processIdentifier: pid_t) {
        let token = beginOpenApplication(processIdentifier: processIdentifier)
        ensureApplicationWindow(processIdentifier: processIdentifier, operationToken: token)
    }

    func beginOpenApplication(processIdentifier: pid_t) -> WindowOperationToken {
        operationTracker.begin(.open, for: processIdentifier)
    }

    func reserveForegroundOperation() -> WindowForegroundOperationReservation {
        operationTracker.reserveForegroundOperation(
            frontmostProcessIdentifier: NSWorkspace.shared.frontmostApplication?.processIdentifier
        )
    }

    func beginOpenApplication(
        processIdentifier: pid_t,
        reservation: WindowForegroundOperationReservation
    ) -> WindowOperationToken? {
        operationTracker.begin(
            .open,
            for: processIdentifier,
            reservation: reservation,
            currentFrontmostProcessIdentifier: NSWorkspace.shared.frontmostApplication?.processIdentifier
        )
    }

    func ensureApplicationWindow(
        processIdentifier: pid_t,
        operationToken: WindowOperationToken
    ) {
        guard operationToken.processIdentifier == processIdentifier,
              operationToken.intent == .open,
              operationTracker.isForegroundCurrent(operationToken),
              NSRunningApplication(processIdentifier: processIdentifier) != nil
        else {
            return
        }

        bringApplicationToFront(processIdentifier: processIdentifier, token: operationToken)
        ensureApplicationWindow(
            processIdentifier: processIdentifier,
            operationToken: operationToken,
            attemptsRemaining: 2
        )
    }

    private func ensureApplicationWindow(
        processIdentifier: pid_t,
        operationToken: WindowOperationToken,
        attemptsRemaining: Int
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self,
                  self.operationTracker.isForegroundCurrent(
                      operationToken,
                      currentFrontmostProcessIdentifier: NSWorkspace.shared
                          .frontmostApplication?.processIdentifier
                  )
            else {
                return
            }

            let summary = self.interactionSummary(for: processIdentifier)
            guard summary.normalWindowCount == 0 else {
                self.bringApplicationToFront(
                    processIdentifier: processIdentifier,
                    token: operationToken
                )
                return
            }

            let appElement = AXUIElementCreateApplication(processIdentifier)
            if self.pressNewWindowMenuItemIfAvailable(
                appElement: appElement,
                operationToken: operationToken
            ) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [weak self] in
                    guard let self,
                          self.operationTracker.isForegroundCurrent(
                              operationToken,
                              currentFrontmostProcessIdentifier: NSWorkspace.shared
                                  .frontmostApplication?.processIdentifier
                          )
                    else {
                        return
                    }
                    self.bringApplicationToFront(
                        processIdentifier: processIdentifier,
                        token: operationToken
                    )
                }
            } else if attemptsRemaining > 0 {
                self.ensureApplicationWindow(
                    processIdentifier: processIdentifier,
                    operationToken: operationToken,
                    attemptsRemaining: attemptsRemaining - 1
                )
            }
        }
    }

    private func hideApplicationUsingAccessibility(appElement: AXUIElement) {
        AXUIElementSetAttributeValue(appElement, kAXHiddenAttribute as CFString, kCFBooleanTrue)
    }

    @discardableResult
    private func pressHideMenuItemIfAvailable(
        appElement: AXUIElement,
        operationToken: WindowOperationToken
    ) -> Bool {
        guard operationTracker.isForegroundCurrent(operationToken) else {
            return false
        }
        AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)

        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXMenuBarAttribute as CFString, &rawValue) == .success,
              let rawValue,
              CFGetTypeID(rawValue) == AXUIElementGetTypeID(),
              let hideItem = hideMenuItem(in: rawValue as! AXUIElement)
        else {
            return false
        }

        guard operationTracker.isForegroundCurrent(operationToken) else {
            return false
        }
        return AXUIElementPerformAction(hideItem, kAXPressAction as CFString) == .success
    }

    private func hideMenuItem(in element: AXUIElement, depth: Int = 0) -> AXUIElement? {
        guard depth <= 6 else {
            return nil
        }

        let commandCharacter = stringAttribute(kAXMenuItemCmdCharAttribute, from: element)?.uppercased()
        let commandModifiers = intAttribute(kAXMenuItemCmdModifiersAttribute, from: element)
        if commandCharacter == "H", commandModifiers == 0 {
            return element
        }

        let title = DockTitleMatcher.normalized(stringAttribute(kAXTitleAttribute, from: element))
        if title.hasPrefix("hide "), !title.contains("others") {
            return element
        }

        for child in children(of: element) {
            if let match = hideMenuItem(in: child, depth: depth + 1) {
                return match
            }
        }
        return nil
    }

    @discardableResult
    private func pressNewWindowMenuItemIfAvailable(
        appElement: AXUIElement,
        operationToken: WindowOperationToken
    ) -> Bool {
        guard operationTracker.isForegroundCurrent(operationToken) else {
            return false
        }
        AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)

        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXMenuBarAttribute as CFString, &rawValue) == .success,
              let rawValue,
              CFGetTypeID(rawValue) == AXUIElementGetTypeID(),
              let newWindowItem = newWindowMenuItem(in: rawValue as! AXUIElement)?.element
        else {
            return false
        }

        guard operationTracker.isForegroundCurrent(operationToken) else {
            return false
        }
        return AXUIElementPerformAction(newWindowItem, kAXPressAction as CFString) == .success
    }

    private func newWindowMenuItem(in element: AXUIElement, depth: Int = 0) -> NewWindowMenuItemSearchResult? {
        guard depth <= 6 else {
            return nil
        }

        var best: NewWindowMenuItemSearchResult?
        let isEnabled = boolAttribute(kAXEnabledAttribute, from: element) ?? true
        if isEnabled,
           let match = NewWindowMenuItemPolicy.match(
               title: stringAttribute(kAXTitleAttribute, from: element),
               commandCharacter: stringAttribute(kAXMenuItemCmdCharAttribute, from: element),
               commandModifiers: intAttribute(kAXMenuItemCmdModifiersAttribute, from: element)
           ) {
            best = NewWindowMenuItemSearchResult(element: element, match: match)
        }

        for child in children(of: element) {
            guard let candidate = newWindowMenuItem(in: child, depth: depth + 1) else {
                continue
            }
            if best == nil || candidate.match.rawValue < best!.match.rawValue {
                best = candidate
            }
        }
        return best
    }

    public func focusWindow(processIdentifier: pid_t, title: String?, windowID: CGWindowID?) {
        let token = operationTracker.begin(.focus, for: processIdentifier)
        let desktopRevealResolution = resolvePendingDesktopReveal(for: processIdentifier)
        if desktopRevealResolution == .restore {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                self?.focusWindow(
                    processIdentifier: processIdentifier,
                    title: title,
                    windowID: windowID,
                    operationToken: token,
                    settlePassesRemaining: 2
                )
            }
            return
        }
        focusWindow(
            processIdentifier: processIdentifier,
            title: title,
            windowID: windowID,
            operationToken: token,
            settlePassesRemaining: 2
        )
    }

    public func closeWindow(
        processIdentifier: pid_t,
        title: String?,
        windowID: CGWindowID?,
        completion: @escaping (Bool) -> Void
    ) {
        guard let pendingClose = beginWindowClose(
            processIdentifier: processIdentifier,
            title: title,
            windowID: windowID
        ) else {
            DispatchQueue.main.async {
                completion(false)
            }
            return
        }

        verifyWindowClose(
            pendingClose,
            attemptsRemaining: Self.closeVerificationAttempts - 1,
            completion: completion
        )
    }

    @discardableResult
    public func quitApplication(
        processIdentifier: pid_t,
        completion: @escaping (Bool) -> Void
    ) -> Bool {
        _ = operationTracker.begin(.quit, for: processIdentifier)
        guard let application = NSRunningApplication(processIdentifier: processIdentifier) else {
            DispatchQueue.main.async {
                completion(true)
            }
            return true
        }
        guard application.terminate() else {
            return false
        }

        let completionState = ApplicationQuitCompletionState(completion: completion)
        completionState.terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let terminatedApplication = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication,
                  terminatedApplication.processIdentifier == processIdentifier
            else {
                return
            }
            completionState.finish(true)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.quitVerificationTimeout) {
            completionState.finish(
                NSRunningApplication(processIdentifier: processIdentifier) == nil
            )
        }
        return true
    }

    private func beginWindowClose(
        processIdentifier: pid_t,
        title: String?,
        windowID: CGWindowID?
    ) -> PendingWindowClose? {
        _ = operationTracker.begin(.close, for: processIdentifier)
        let appElement = AXUIElementCreateApplication(processIdentifier)
        let allWindows = windows(for: appElement)
        let normalWindows = normalWindowCandidates(in: allWindows)
        guard let target = strictWindowMatch(in: normalWindows, title: title, windowID: windowID) else {
            return nil
        }
        let resolvedTitle = stringAttribute(kAXTitleAttribute, from: target)
        let resolvedWindowID = intAttribute("AXWindowNumber", from: target).map(CGWindowID.init)
        let blockingDialogsBeforeClose = blockingDialogs(in: allWindows)
        guard pressCloseButton(for: target) else {
            return nil
        }

        return PendingWindowClose(
            processIdentifier: processIdentifier,
            targetElement: target,
            verificationTarget: WindowCloseVerificationTarget(
                windowID: resolvedWindowID,
                title: resolvedTitle
            ),
            blockingDialogsBeforeClose: blockingDialogsBeforeClose
        )
    }

    private func verifyWindowClose(
        _ pendingClose: PendingWindowClose,
        attemptsRemaining: Int,
        completion: @escaping (Bool) -> Void
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.closeVerificationInterval) { [weak self] in
            guard let self else {
                completion(false)
                return
            }
            self.closeVerificationQueue.async { [weak self] in
                let decision = self?.closeVerificationDecision(
                    for: pendingClose,
                    attemptsRemaining: attemptsRemaining
                )
                DispatchQueue.main.async { [weak self] in
                    guard let self, let decision else {
                        completion(false)
                        return
                    }
                    switch decision {
                    case .success:
                        self.finishSuccessfulWindowClose(pendingClose)
                        completion(true)
                    case .failure:
                        completion(false)
                    case .retry:
                        self.verifyWindowClose(
                            pendingClose,
                            attemptsRemaining: attemptsRemaining - 1,
                            completion: completion
                        )
                    }
                }
            }
        }
    }

    private func closeVerificationDecision(
        for pendingClose: PendingWindowClose,
        attemptsRemaining: Int
    ) -> WindowCloseVerificationDecision {
        let appElement = AXUIElementCreateApplication(pendingClose.processIdentifier)
        let queryResult = queryWindows(for: appElement)
        guard queryResult.succeeded else {
            return WindowCloseVerificationPolicy.decision(
                querySucceeded: false,
                targetIsPresent: true,
                blockingDialogAppeared: false,
                attemptsRemaining: attemptsRemaining
            )
        }
        let allWindows = queryResult.windows
        let normalWindows = normalWindowCandidates(in: allWindows)
        let candidates = normalWindows.enumerated().map { index, window in
            WindowCloseCandidate(
                index: index,
                windowID: intAttribute("AXWindowNumber", from: window).map(CGWindowID.init),
                title: stringAttribute(kAXTitleAttribute, from: window)
            )
        }
        let targetElementStillPresent = allWindows.contains {
            CFEqual($0, pendingClose.targetElement)
        }
        let targetIsPresent = targetElementStillPresent
            || WindowCloseVerificationPolicy.targetIsPresent(
                pendingClose.verificationTarget,
                in: candidates
            )
        let blockingDialogAppeared = blockingDialogs(in: allWindows).contains { dialog in
            !pendingClose.blockingDialogsBeforeClose.contains { previousDialog in
                CFEqual(dialog, previousDialog)
            }
        }

        return WindowCloseVerificationPolicy.decision(
            querySucceeded: true,
            targetIsPresent: targetIsPresent,
            blockingDialogAppeared: blockingDialogAppeared,
            attemptsRemaining: attemptsRemaining
        )
    }

    private func finishSuccessfulWindowClose(_ pendingClose: PendingWindowClose) {
        forgetRememberedWindow(
            processIdentifier: pendingClose.processIdentifier,
            title: pendingClose.verificationTarget.title,
            windowID: pendingClose.verificationTarget.windowID
        )
    }

    private func focusWindow(
        processIdentifier: pid_t,
        title: String?,
        windowID: CGWindowID?,
        operationToken: WindowOperationToken,
        settlePassesRemaining: Int
    ) {
        guard operationToken.processIdentifier == processIdentifier,
              operationTracker.isForegroundCurrent(operationToken)
        else {
            return
        }
        guard let app = NSRunningApplication(processIdentifier: processIdentifier) else {
            rememberedWindowTargets.removeValue(forKey: processIdentifier)
            return
        }

        let appElement = AXUIElementCreateApplication(processIdentifier)
        let candidates = normalWindowCandidates(in: windows(for: appElement))
        if let target = focusWindowMatch(
            in: candidates,
            title: title,
            windowID: windowID
        ) {
            if focusTargetWindow(
                target,
                app: app,
                appElement: appElement,
                fallbackTitle: title,
                fallbackWindowID: windowID
            ) {
                return
            }
        } else {
            activateApplicationForWindowFocus(app, appElement: appElement)
        }

        guard settlePassesRemaining > 0 else {
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self,
                  self.operationTracker.isForegroundCurrent(operationToken)
            else {
                return
            }
            self.focusWindow(
                processIdentifier: processIdentifier,
                title: title,
                windowID: windowID,
                operationToken: operationToken,
                settlePassesRemaining: settlePassesRemaining - 1
            )
        }
    }

    private func focusWindowMatch(
        in windows: [AXUIElement],
        title: String?,
        windowID: CGWindowID?
    ) -> AXUIElement? {
        let candidates = windows.enumerated().map { index, window in
            WindowFocusCandidate(
                index: index,
                windowID: intAttribute("AXWindowNumber", from: window).map(CGWindowID.init),
                title: stringAttribute(kAXTitleAttribute, from: window)
            )
        }
        guard let index = WindowFocusMatchPolicy.matchingIndex(
            in: candidates,
            title: title,
            windowID: windowID
        ), windows.indices.contains(index) else {
            return nil
        }
        return windows[index]
    }

    private func restoreRememberedWindow(
        _ rememberedTarget: RememberedWindowTarget,
        for app: NSRunningApplication,
        operationToken: WindowOperationToken,
        attemptsRemaining: Int
    ) {
        let processIdentifier = app.processIdentifier
        guard operationTracker.isForegroundCurrent(operationToken),
              rememberedWindowTargets[processIdentifier] == rememberedTarget
        else {
            return
        }
        guard app.launchDate == rememberedTarget.applicationLaunchDate else {
            rememberedWindowTargets.removeValue(forKey: processIdentifier)
            return
        }

        let appElement = AXUIElementCreateApplication(processIdentifier)
        let candidates = normalWindowCandidates(in: windows(for: appElement))
        if let target = focusWindowMatch(
            in: candidates,
            title: rememberedTarget.title,
            windowID: rememberedTarget.windowID
        ) {
            AXUIElementSetAttributeValue(target, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            if AXUIElementPerformAction(target, kAXRaiseAction as CFString) == .success {
                return
            }
        }

        guard attemptsRemaining > 0 else {
            if rememberedWindowTargets[processIdentifier] == rememberedTarget {
                rememberedWindowTargets.removeValue(forKey: processIdentifier)
            }
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self,
                  let app = NSRunningApplication(processIdentifier: processIdentifier),
                  self.operationTracker.isForegroundCurrent(operationToken)
            else {
                return
            }
            self.restoreRememberedWindow(
                rememberedTarget,
                for: app,
                operationToken: operationToken,
                attemptsRemaining: attemptsRemaining - 1
            )
        }
    }

    private func forgetRememberedWindow(
        processIdentifier: pid_t,
        title: String?,
        windowID: CGWindowID?
    ) {
        guard let rememberedTarget = rememberedWindowTargets[processIdentifier] else {
            return
        }
        if let rememberedWindowID = rememberedTarget.windowID {
            if rememberedWindowID == windowID {
                rememberedWindowTargets.removeValue(forKey: processIdentifier)
            } else if windowID == nil,
                      DockTitleMatcher.normalized(rememberedTarget.title) == DockTitleMatcher.normalized(title) {
                rememberedWindowTargets.removeValue(forKey: processIdentifier)
            }
            return
        }
        guard windowID == nil,
              DockTitleMatcher.normalized(rememberedTarget.title) == DockTitleMatcher.normalized(title)
        else {
            return
        }
        rememberedWindowTargets.removeValue(forKey: processIdentifier)
    }

    private func strictWindowMatch(
        in windows: [AXUIElement],
        title: String?,
        windowID: CGWindowID?
    ) -> AXUIElement? {
        let candidates = windows.enumerated().map { index, window in
            WindowCloseCandidate(
                index: index,
                windowID: intAttribute("AXWindowNumber", from: window).map(CGWindowID.init),
                title: stringAttribute(kAXTitleAttribute, from: window)
            )
        }
        guard let index = WindowCloseMatchPolicy.matchingIndex(
            in: candidates,
            title: title,
            windowID: windowID
        ), windows.indices.contains(index) else {
            return nil
        }
        return windows[index]
    }

    private func normalWindows(in windows: [AXUIElement]) -> [AXUIElement] {
        deduplicatedIndependentWindows(normalWindowCandidates(in: windows))
    }

    private func normalWindowCandidates(in windows: [AXUIElement]) -> [AXUIElement] {
        windows.filter { window in
            let role = stringAttribute(kAXRoleAttribute, from: window)
            let subrole = stringAttribute(kAXSubroleAttribute, from: window)
            return WindowFiltering.isNormalAXWindow(role: role, subrole: subrole)
        }
    }

    private func deduplicatedIndependentWindows(_ windows: [AXUIElement]) -> [AXUIElement] {
        let candidates = windows.enumerated().map { index, window in
            BulkWindowCandidate(
                index: index,
                windowID: intAttribute("AXWindowNumber", from: window).map { CGWindowID($0) },
                title: stringAttribute(kAXTitleAttribute, from: window),
                frame: windowFrame(from: window)
            )
        }
        return BulkWindowDeduplicationPolicy.uniqueIndices(in: candidates).compactMap { index in
            windows.indices.contains(index) ? windows[index] : nil
        }
    }

    @discardableResult
    private func focusTargetWindow(
        _ target: AXUIElement,
        app: NSRunningApplication,
        appElement: AXUIElement,
        fallbackTitle: String?,
        fallbackWindowID: CGWindowID?
    ) -> Bool {
        AXUIElementSetAttributeValue(target, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        activateApplicationForWindowFocus(app, appElement: appElement)
        guard raiseAndFocus(target, appElement: appElement) else {
            return false
        }
        rememberedWindowTargets[app.processIdentifier] = RememberedWindowTarget(
            title: stringAttribute(kAXTitleAttribute, from: target) ?? fallbackTitle,
            windowID: intAttribute("AXWindowNumber", from: target).map { CGWindowID($0) } ?? fallbackWindowID,
            applicationLaunchDate: app.launchDate
        )
        return true
    }

    private func activateApplicationForWindowFocus(
        _ app: NSRunningApplication,
        appElement: AXUIElement
    ) {
        AXUIElementSetAttributeValue(appElement, kAXHiddenAttribute as CFString, kCFBooleanFalse)
        app.unhide()
        makeFrontmost(app, appElement: appElement, allWindows: false)
    }

    @discardableResult
    private func raiseAndFocus(_ target: AXUIElement, appElement: AXUIElement) -> Bool {
        AXUIElementSetAttributeValue(target, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(target, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, target)
        return AXUIElementPerformAction(target, kAXRaiseAction as CFString) == .success
    }

    private func pressCloseButton(for window: AXUIElement) -> Bool {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &rawValue) == .success,
              let rawValue,
              CFGetTypeID(rawValue) == AXUIElementGetTypeID()
        else {
            return false
        }
        let closeButton = rawValue as! AXUIElement
        return AXUIElementPerformAction(closeButton, kAXPressAction as CFString) == .success
    }

    private func blockingDialogs(in windows: [AXUIElement]) -> [AXUIElement] {
        windows.flatMap { blockingDialogs(in: $0, depth: 0) }
    }

    private func blockingDialogs(in element: AXUIElement, depth: Int) -> [AXUIElement] {
        let role = stringAttribute(kAXRoleAttribute, from: element)
        let subrole = stringAttribute(kAXSubroleAttribute, from: element)
        let isBlockingDialog = role == kAXSheetRole
            || subrole == kAXDialogSubrole
            || subrole == kAXSystemDialogSubrole
            || boolAttribute(kAXModalAttribute, from: element) == true
        if isBlockingDialog {
            return [element]
        }
        guard depth < 3 else {
            return []
        }
        return children(of: element).flatMap {
            blockingDialogs(in: $0, depth: depth + 1)
        }
    }

    private func activate(_ app: NSRunningApplication, allWindows: Bool) {
        app.activate(options: WindowActivationPolicy.options(allWindows: allWindows))
    }

    private func makeFrontmost(_ app: NSRunningApplication, appElement: AXUIElement, allWindows: Bool) {
        AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        activate(app, allWindows: allWindows)
    }

    private func windows(for appElement: AXUIElement) -> [AXUIElement] {
        queryWindows(for: appElement).windows
    }

    private func queryWindows(for appElement: AXUIElement) -> AXWindowQueryResult {
        var rawValue: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &rawValue)
        guard error == .success, let windows = rawValue as? [AXUIElement] else {
            return AXWindowQueryResult(windows: [], succeeded: false)
        }
        return AXWindowQueryResult(windows: windows, succeeded: true)
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &rawValue) == .success,
              let children = rawValue as? [AXUIElement]
        else {
            return []
        }
        return children
    }

    private func onscreenNormalWindowCount(for processIdentifier: pid_t) -> Int {
        guard let rawWindows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID),
              let windows = rawWindows as? [[String: Any]]
        else {
            return 0
        }

        return windows.filter { window in
            guard let ownerPID = intWindowValue(kCGWindowOwnerPID, from: window).map(pid_t.init),
                  ownerPID == processIdentifier
            else {
                return false
            }

            let layer = intWindowValue(kCGWindowLayer, from: window) ?? -1
            let isOnScreen = boolWindowValue(kCGWindowIsOnscreen, from: window) ?? true
            let frame = windowFrame(from: window)
            return WindowFiltering.shouldIncludeShareableWindow(
                layer: layer,
                isOnScreen: isOnScreen,
                frame: frame
            )
        }.count
    }

    private func onscreenNormalWindowOwnerProcessIdentifiers() -> [pid_t] {
        guard let rawWindows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ), let windows = rawWindows as? [[String: Any]] else {
            return []
        }

        return windows.compactMap { window in
            guard let processIdentifier = intWindowValue(kCGWindowOwnerPID, from: window).map(pid_t.init),
                  let application = NSRunningApplication(processIdentifier: processIdentifier),
                  !application.isHidden,
                  WindowFiltering.shouldIncludeShareableWindow(
                    layer: intWindowValue(kCGWindowLayer, from: window) ?? -1,
                    isOnScreen: boolWindowValue(kCGWindowIsOnscreen, from: window) ?? true,
                    frame: windowFrame(from: window)
                  )
            else {
                return nil
            }
            return processIdentifier
        }
    }

    private func intWindowValue(_ key: CFString, from window: [String: Any]) -> Int? {
        CGWindowDictionary.intValue(key, from: window)
    }

    private func boolWindowValue(_ key: CFString, from window: [String: Any]) -> Bool? {
        CGWindowDictionary.boolValue(key, from: window)
    }

    private func windowFrame(from window: [String: Any]) -> CGRect {
        CGWindowDictionary.frame(from: window)
    }

    private func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue) == .success else {
            return nil
        }
        return rawValue as? String
    }

    private func intAttribute(_ attribute: String, from element: AXUIElement) -> Int? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue) == .success else {
            return nil
        }
        if let number = rawValue as? NSNumber {
            return number.intValue
        }
        return rawValue as? Int
    }

    private func boolAttribute(_ attribute: String, from element: AXUIElement) -> Bool? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue) == .success else {
            return nil
        }
        return rawValue as? Bool
    }

    private func windowFrame(from element: AXUIElement) -> CGRect {
        let origin = pointAttribute(kAXPositionAttribute, from: element) ?? .zero
        let size = sizeAttribute(kAXSizeAttribute, from: element) ?? .zero
        return CGRect(origin: origin, size: size)
    }

    private func pointAttribute(_ attribute: String, from element: AXUIElement) -> CGPoint? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue) == .success,
              let rawValue,
              CFGetTypeID(rawValue) == AXValueGetTypeID()
        else {
            return nil
        }

        let value = rawValue as! AXValue
        var point = CGPoint.zero
        guard AXValueGetValue(value, .cgPoint, &point) else {
            return nil
        }
        return point
    }

    private func sizeAttribute(_ attribute: String, from element: AXUIElement) -> CGSize? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue) == .success,
              let rawValue,
              CFGetTypeID(rawValue) == AXValueGetTypeID()
        else {
            return nil
        }

        let value = rawValue as! AXValue
        var size = CGSize.zero
        guard AXValueGetValue(value, .cgSize, &size) else {
            return nil
        }
        return size
    }
}
