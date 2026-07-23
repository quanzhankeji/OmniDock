import AppKit
import ApplicationServices
import CoreGraphics

struct CmdTabApplicationCandidate: Equatable {
    let processIdentifier: pid_t
    let bundleIdentifier: String?
    let localizedName: String?
    let bundleURL: URL?
}

enum CmdTabApplicationResolutionPolicy {
    static func resolve(
        bundleIdentifier: String?,
        title: String?,
        candidates: [CmdTabApplicationCandidate]
    ) -> CmdTabApplicationCandidate? {
        if let bundleIdentifier,
           let exact = candidates.first(where: { $0.bundleIdentifier == bundleIdentifier }) {
            return exact
        }

        let normalizedTitle = normalized(title)
        guard !normalizedTitle.isEmpty else {
            return nil
        }
        let matches = candidates.filter { candidate in
            normalized(candidate.localizedName) == normalizedTitle
                || normalized(candidate.bundleURL?.deletingPathExtension().lastPathComponent) == normalizedTitle
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private static func normalized(_ value: String?) -> String {
        value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased() ?? ""
    }
}

struct CmdTabPreviewLifecycleState: Equatable {
    enum Phase: Equatable {
        case stopped
        case idle
        case discovering(UInt64)
        case observing(UInt64)
    }

    private(set) var generation: UInt64 = 0
    private(set) var phase: Phase = .stopped

    mutating func start() {
        generation &+= 1
        phase = .idle
    }

    @discardableResult
    mutating func beginDiscovery() -> UInt64? {
        guard phase != .stopped else {
            return nil
        }
        switch phase {
        case let .discovering(generation), let .observing(generation):
            return generation
        case .idle:
            self.generation &+= 1
            phase = .discovering(self.generation)
            return self.generation
        case .stopped:
            return nil
        }
    }

    mutating func beginObservation(for requestGeneration: UInt64) -> Bool {
        guard phase == .discovering(requestGeneration) else {
            return false
        }
        phase = .observing(requestGeneration)
        return true
    }

    mutating func restartDiscovery(for requestGeneration: UInt64) -> UInt64? {
        guard phase == .observing(requestGeneration) else {
            return nil
        }
        generation &+= 1
        phase = .discovering(generation)
        return generation
    }

    @discardableResult
    mutating func endInteraction() -> Bool {
        guard phase != .stopped else {
            return false
        }
        let wasActive: Bool
        switch phase {
        case .discovering, .observing:
            wasActive = true
        case .idle, .stopped:
            wasActive = false
        }
        generation &+= 1
        phase = .idle
        return wasActive
    }

    @discardableResult
    mutating func stop() -> Bool {
        let wasActive: Bool
        switch phase {
        case .discovering, .observing:
            wasActive = true
        case .idle, .stopped:
            wasActive = false
        }
        generation &+= 1
        phase = .stopped
        return wasActive
    }

    func accepts(_ requestGeneration: UInt64) -> Bool {
        switch phase {
        case .discovering(requestGeneration), .observing(requestGeneration):
            return true
        case .stopped, .idle, .discovering, .observing:
            return false
        }
    }
}

struct CmdTabSwitcherSelection {
    let application: CmdTabApplicationCandidate
    let title: String
    let accessibilityFrame: CGRect
}

struct CmdTabPreviewButtonInvocation: Equatable {
    let action: PreviewThumbnailAction
    let requestGeneration: UInt64
    let targetIdentifier: String
}

struct CmdTabPreviewPointerButtonTarget: Equatable {
    let action: PreviewThumbnailAction
    let eventTapFrame: CGRect
}

struct CmdTabPreviewPointerSnapshot: Equatable {
    let eventTapPanelFrame: CGRect
    let buttonTargets: [CmdTabPreviewPointerButtonTarget]
    let requestGeneration: UInt64
    let targetIdentifier: String
}

enum CmdTabPreviewPointerEventOutcome: Equatable {
    case passThrough
    case swallow
    case invoke(CmdTabPreviewButtonInvocation)
    case endInteraction
}

enum CmdTabPreviewPointerHoverOutcome: Equatable {
    case unchanged
    case changed(PreviewThumbnailAction?)
}

struct CmdTabPreviewPointerState {
    private var snapshot: CmdTabPreviewPointerSnapshot?
    private var pressedInvocation: CmdTabPreviewButtonInvocation?
    private var pressedButtonFrame: CGRect?
    private var hoveredAction: PreviewThumbnailAction?
    private var lastPointerLocation: CGPoint?

    var isCapturingPointer: Bool {
        pressedInvocation != nil
    }

    @discardableResult
    mutating func update(snapshot: CmdTabPreviewPointerSnapshot?) -> CmdTabPreviewPointerHoverOutcome {
        self.snapshot = snapshot
        return hoverOutcome(at: lastPointerLocation)
    }

    mutating func mouseDown(at point: CGPoint) -> CmdTabPreviewPointerEventOutcome {
        lastPointerLocation = point
        guard let snapshot else {
            return .passThrough
        }
        guard let target = snapshot.buttonTargets.first(where: {
            $0.eventTapFrame.contains(point)
        }) else {
            return snapshot.eventTapPanelFrame.contains(point) ? .passThrough : .endInteraction
        }

        pressedInvocation = CmdTabPreviewButtonInvocation(
            action: target.action,
            requestGeneration: snapshot.requestGeneration,
            targetIdentifier: snapshot.targetIdentifier
        )
        pressedButtonFrame = target.eventTapFrame
        return .swallow
    }

    mutating func mouseDragged(at point: CGPoint) -> CmdTabPreviewPointerEventOutcome {
        lastPointerLocation = point
        return isCapturingPointer
            ? CmdTabPreviewPointerEventOutcome.swallow
            : CmdTabPreviewPointerEventOutcome.passThrough
    }

    mutating func mouseUp(at point: CGPoint) -> CmdTabPreviewPointerEventOutcome {
        lastPointerLocation = point
        defer {
            pressedInvocation = nil
            pressedButtonFrame = nil
        }
        guard let pressedInvocation, let pressedButtonFrame else {
            return .passThrough
        }
        guard pressedButtonFrame.contains(point),
              let snapshot,
              snapshot.requestGeneration == pressedInvocation.requestGeneration,
              snapshot.targetIdentifier == pressedInvocation.targetIdentifier
        else {
            return .swallow
        }
        return .invoke(pressedInvocation)
    }

    mutating func mouseMoved(at point: CGPoint) -> CmdTabPreviewPointerHoverOutcome {
        lastPointerLocation = point
        return hoverOutcome(at: point)
    }

    mutating func cancelPointerCapture() {
        pressedInvocation = nil
        pressedButtonFrame = nil
    }

    private mutating func setHoveredAction(
        _ action: PreviewThumbnailAction?
    ) -> CmdTabPreviewPointerHoverOutcome {
        guard hoveredAction != action else {
            return .unchanged
        }
        hoveredAction = action
        return .changed(action)
    }

    private mutating func hoverOutcome(
        at point: CGPoint?
    ) -> CmdTabPreviewPointerHoverOutcome {
        guard let point,
              let snapshot
        else {
            return setHoveredAction(nil)
        }
        let action = snapshot.buttonTargets.first(where: {
            $0.eventTapFrame.contains(point)
        })?.action
        return setHoveredAction(action)
    }
}

@MainActor
protocol CmdTabProcessSwitcherProviding: AnyObject {
    var onSelectionChanged: (() -> Void)? { get set }
    var onDestroyed: (() -> Void)? { get set }
    func beginObserving() -> Bool
    func currentSelection() -> CmdTabSwitcherSelection?
    func stopObserving()
}

@MainActor
final class CmdTabPreviewObserver {
    var onInteractionBegan: (() -> Void)?
    var onSelectionChanged: ((DockAppTarget) -> Void)?
    var onSelectionBecameUnavailable: (() -> Void)?
    var onInteractionEnded: (() -> Void)?
    var onPreviewButtonAction: ((CmdTabPreviewButtonInvocation) -> Void)?
    var onPreviewButtonHoverChanged: ((PreviewThumbnailAction?) -> Void)?

    private let isFeatureEnabled: () -> Bool
    private let processSwitcher: any CmdTabProcessSwitcherProviding
    private let pointerEventTap = CmdTabPreviewPointerEventTap()
    private var lifecycle = CmdTabPreviewLifecycleState()
    private var globalEventMonitor: Any?
    private var localEventMonitor: Any?
    private var discoveryTimer: Timer?
    private var discoveryDeadline: Date?
    private var selectionRefreshTimer: Timer?
    private var selectionReadinessDeadline: Date?
    private var lastPublishedTarget: DockAppTarget?
    private var settingsObserver: NSObjectProtocol?
    private var permissionObserver: NSObjectProtocol?

    init(
        isFeatureEnabled: @escaping () -> Bool,
        processSwitcher: (any CmdTabProcessSwitcherProviding)? = nil
    ) {
        self.isFeatureEnabled = isFeatureEnabled
        self.processSwitcher = processSwitcher ?? SystemCmdTabProcessSwitcherProvider()
        self.processSwitcher.onSelectionChanged = { [weak self] in
            self?.processSwitcherSelectionChanged()
        }
        self.processSwitcher.onDestroyed = { [weak self] in
            self?.endInteraction()
        }
        pointerEventTap.onAction = { [weak self] invocation in
            self?.onPreviewButtonAction?(invocation)
        }
        pointerEventTap.onHoverChanged = { [weak self] action in
            self?.onPreviewButtonHoverChanged?(action)
        }
        pointerEventTap.onOutsidePrimaryPointerDown = { [weak self] in
            self?.endInteraction()
        }
    }

    func start() {
        stop()
        lifecycle.start()
        settingsObserver = NotificationCenter.default.addObserver(
            forName: SettingsStore.changedNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard SettingsStore.change(in: notification).affectsCommandTabPreview else {
                return
            }
            Task { @MainActor [weak self] in
                self?.synchronizeEventMonitoring()
            }
        }
        permissionObserver = NotificationCenter.default.addObserver(
            forName: PermissionService.changedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.synchronizeEventMonitoring()
            }
        }
        synchronizeEventMonitoring()
    }

    func stop() {
        let wasActive = lifecycle.stop()
        removeEventMonitors()
        pointerEventTap.stop()
        stopDiscovery()
        stopSelectionRefresh()
        processSwitcher.stopObserving()
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
            self.settingsObserver = nil
        }
        if let permissionObserver {
            NotificationCenter.default.removeObserver(permissionObserver)
            self.permissionObserver = nil
        }
        if wasActive {
            onInteractionEnded?()
        }
    }

    func cancelInteraction() {
        endInteraction()
    }

    func updatePreviewButtonTargets(
        _ buttonTargets: [PreviewThumbnailActionHitTarget],
        panelFrame: CGRect?,
        requestGeneration: UInt64,
        targetIdentifier: String
    ) {
        guard isFeatureEnabled(),
              let panelFrame,
              let eventTapPanelFrame = eventTapFrame(fromAppKitFrame: panelFrame)
        else {
            pointerEventTap.update(snapshot: nil)
            return
        }
        let eventTapButtonTargets = buttonTargets.compactMap { target -> CmdTabPreviewPointerButtonTarget? in
            guard let eventTapFrame = eventTapFrame(fromAppKitFrame: target.screenFrame) else {
                return nil
            }
            return CmdTabPreviewPointerButtonTarget(
                action: target.action,
                eventTapFrame: eventTapFrame
            )
        }
        guard !eventTapButtonTargets.isEmpty else {
            pointerEventTap.update(snapshot: nil)
            return
        }
        pointerEventTap.update(
            snapshot: CmdTabPreviewPointerSnapshot(
                eventTapPanelFrame: eventTapPanelFrame,
                buttonTargets: eventTapButtonTargets,
                requestGeneration: requestGeneration,
                targetIdentifier: targetIdentifier
            )
        )
    }

    private func synchronizeEventMonitoring() {
        guard isFeatureEnabled() else {
            removeEventMonitors()
            pointerEventTap.update(snapshot: nil)
            endInteraction()
            return
        }
        guard globalEventMonitor == nil, localEventMonitor == nil else {
            return
        }

        let keyboardMask: NSEvent.EventTypeMask = [.keyDown, .flagsChanged]
        let globalMask: NSEvent.EventTypeMask = keyboardMask.union([.rightMouseDown, .otherMouseDown])
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: globalMask) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handle(event)
            }
        }
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: keyboardMask) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handle(event)
            }
            return event
        }
    }

    private func removeEventMonitors() {
        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
            self.globalEventMonitor = nil
        }
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
    }

    private func handle(_ event: NSEvent) {
        guard isFeatureEnabled() else {
            synchronizeEventMonitoring()
            return
        }

        switch event.type {
        case .keyDown where event.keyCode == 48 && event.modifierFlags.contains(.command):
            beginDiscoveryIfNeeded()
        case .keyDown where event.keyCode == 53:
            endInteraction()
        case .flagsChanged where !event.modifierFlags.contains(.command):
            endInteraction()
        case .rightMouseDown, .otherMouseDown:
            endInteraction()
        default:
            break
        }
    }

    private func beginDiscoveryIfNeeded() {
        guard let generation = lifecycle.beginDiscovery() else {
            return
        }

        if case .observing = lifecycle.phase {
            _ = publishCurrentSelection()
            return
        }
        guard discoveryTimer == nil else {
            return
        }
        onInteractionBegan?()
        scheduleDiscovery(generation: generation)
    }

    private func scheduleDiscovery(generation: UInt64) {
        discoveryDeadline = Date().addingTimeInterval(1.6)
        attemptDiscovery(generation: generation)
        guard lifecycle.phase == .discovering(generation) else {
            return
        }
        let timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.attemptDiscovery(generation: generation)
            }
        }
        discoveryTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func attemptDiscovery(generation: UInt64) {
        guard lifecycle.accepts(generation),
              case .discovering = lifecycle.phase
        else {
            stopDiscovery()
            return
        }
        if processSwitcher.beginObserving() {
            guard lifecycle.beginObservation(for: generation) else {
                processSwitcher.stopObserving()
                stopDiscovery()
                return
            }
            stopDiscovery()
            startSelectionRefresh()
            selectionReadinessDeadline = Date().addingTimeInterval(0.5)
            processSwitcherSelectionChanged()
            return
        }
        if let discoveryDeadline, Date() >= discoveryDeadline {
            endInteraction()
        }
    }

    private func processSwitcherSelectionChanged() {
        if publishCurrentSelection() {
            selectionReadinessDeadline = nil
        }
    }

    @discardableResult
    private func publishCurrentSelection() -> Bool {
        guard case .observing = lifecycle.phase,
              let selection = processSwitcher.currentSelection(),
              let frame = appKitFrame(fromAccessibilityFrame: selection.accessibilityFrame)
        else {
            if lastPublishedTarget != nil {
                lastPublishedTarget = nil
                onSelectionBecameUnavailable?()
            }
            return false
        }
        let app = selection.application
        let name = app.localizedName ?? selection.title
        let target = DockAppTarget(
            processIdentifier: app.processIdentifier,
            bundleIdentifier: app.bundleIdentifier,
            localizedName: name,
            dockElementTitle: selection.title,
            hitPoint: CGPoint(x: frame.midX, y: frame.midY),
            dockItemFrame: frame,
            dockTileIdentifierOverride: "command-tab:\(app.processIdentifier)",
            previewAnchorKind: .commandTab
        )
        guard target != lastPublishedTarget else {
            return true
        }
        lastPublishedTarget = target
        onSelectionChanged?(target)
        return true
    }

    private func appKitFrame(fromAccessibilityFrame frame: CGRect) -> CGRect? {
        let screens = NSScreen.screens.compactMap { screen -> DockScreenInventoryItem? in
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber else {
                return nil
            }
            let displayID = number.uint32Value
            return DockScreenInventoryItem(
                displayIdentifier: displayID,
                appKitFrame: screen.frame,
                eventTapFrame: CGDisplayBounds(displayID)
            )
        }
        return DockScreenInventory(
            screens: screens,
            mainAppKitFrame: NSScreen.main?.frame
        ).appKitFrame(fromEventTapFrame: frame)
    }

    private func eventTapFrame(fromAppKitFrame frame: CGRect) -> CGRect? {
        let screens = NSScreen.screens.compactMap { screen -> DockScreenInventoryItem? in
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber else {
                return nil
            }
            let displayID = number.uint32Value
            return DockScreenInventoryItem(
                displayIdentifier: displayID,
                appKitFrame: screen.frame,
                eventTapFrame: CGDisplayBounds(displayID)
            )
        }
        return DockScreenInventory(
            screens: screens,
            mainAppKitFrame: NSScreen.main?.frame
        ).eventTapFrame(fromAppKitFrame: frame)
    }

    private func endInteraction() {
        let wasActive = lifecycle.endInteraction()
        stopDiscovery()
        stopSelectionRefresh()
        processSwitcher.stopObserving()
        pointerEventTap.update(snapshot: nil)
        selectionReadinessDeadline = nil
        if wasActive {
            onInteractionEnded?()
        }
    }

    private func stopDiscovery() {
        discoveryTimer?.invalidate()
        discoveryTimer = nil
        discoveryDeadline = nil
    }

    private func startSelectionRefresh() {
        guard selectionRefreshTimer == nil else {
            return
        }
        let timer = Timer.scheduledTimer(withTimeInterval: 0.10, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshCurrentSelection()
            }
        }
        selectionRefreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopSelectionRefresh() {
        selectionRefreshTimer?.invalidate()
        selectionRefreshTimer = nil
        lastPublishedTarget = nil
        selectionReadinessDeadline = nil
    }

    private func refreshCurrentSelection() {
        guard case let .observing(generation) = lifecycle.phase else {
            return
        }
        if publishCurrentSelection() {
            selectionReadinessDeadline = nil
            return
        }
        guard let selectionReadinessDeadline, Date() >= selectionReadinessDeadline,
              let discoveryGeneration = lifecycle.restartDiscovery(for: generation)
        else {
            return
        }
        processSwitcher.stopObserving()
        stopSelectionRefresh()
        scheduleDiscovery(generation: discoveryGeneration)
    }
}

private final class CmdTabPreviewPointerEventTap {
    var onAction: ((CmdTabPreviewButtonInvocation) -> Void)?
    var onOutsidePrimaryPointerDown: (() -> Void)?
    var onHoverChanged: ((PreviewThumbnailAction?) -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var state = CmdTabPreviewPointerState()
    private var stopAfterPointerRelease = false

    deinit {
        stop()
    }

    func update(snapshot: CmdTabPreviewPointerSnapshot?) {
        apply(state.update(snapshot: snapshot))
        guard snapshot != nil else {
            stopWhenPointerCaptureFinishes()
            return
        }
        startIfNeeded()
    }

    func stop() {
        apply(state.update(snapshot: nil))
        state.cancelPointerCapture()
        stopAfterPointerRelease = false
        stopImmediately()
    }

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        case .leftMouseDown:
            return apply(state.mouseDown(at: event.location), event: event)
        case .leftMouseDragged:
            return apply(state.mouseDragged(at: event.location), event: event)
        case .leftMouseUp:
            let result = apply(state.mouseUp(at: event.location), event: event)
            if stopAfterPointerRelease {
                DispatchQueue.main.async { [weak self] in
                    self?.stopImmediately()
                }
            }
            return result
        case .mouseMoved:
            apply(state.mouseMoved(at: event.location))
            return Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func startIfNeeded() {
        guard eventTap == nil else {
            return
        }

        let mask = CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseDragged.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseUp.rawValue)
            | CGEventMask(1 << CGEventType.mouseMoved.rawValue)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: cmdTabPreviewPointerEventTapCallback,
            userInfo: userInfo
        ), let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0) else {
            return
        }

        self.eventTap = eventTap
        self.runLoopSource = runLoopSource
        let runLoop = CFRunLoopGetMain()
        CFRunLoopAddSource(runLoop, runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    private func stopWhenPointerCaptureFinishes() {
        guard state.isCapturingPointer else {
            stopImmediately()
            return
        }
        stopAfterPointerRelease = true
    }

    private func stopImmediately() {
        guard let eventTap else {
            return
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        CGEvent.tapEnable(tap: eventTap, enable: false)
        CFMachPortInvalidate(eventTap)
        self.eventTap = nil
        runLoopSource = nil
        stopAfterPointerRelease = false
    }

    private func apply(
        _ outcome: CmdTabPreviewPointerEventOutcome,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        switch outcome {
        case .passThrough:
            return Unmanaged.passUnretained(event)
        case .swallow:
            return nil
        case let .invoke(invocation):
            DispatchQueue.main.async { [weak self] in
                self?.onAction?(invocation)
            }
            return nil
        case .endInteraction:
            DispatchQueue.main.async { [weak self] in
                self?.onOutsidePrimaryPointerDown?()
            }
            return Unmanaged.passUnretained(event)
        }
    }

    private func apply(_ outcome: CmdTabPreviewPointerHoverOutcome) {
        guard case let .changed(action) = outcome else {
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.onHoverChanged?(action)
        }
    }
}

private let cmdTabPreviewPointerEventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else {
        return Unmanaged.passUnretained(event)
    }
    let eventTap = Unmanaged<CmdTabPreviewPointerEventTap>
        .fromOpaque(userInfo)
        .takeUnretainedValue()
    return eventTap.handle(type: type, event: event)
}

@MainActor
private final class SystemCmdTabProcessSwitcherProvider: CmdTabProcessSwitcherProviding {
    var onSelectionChanged: (() -> Void)?
    var onDestroyed: (() -> Void)?

    private var observer: AXObserver?
    private var switcherElement: AXUIElement?
    private var observesSelectionChanges = false
    private var observesDestruction = false
    private var applicationCandidates: [CmdTabApplicationCandidate] = []

    func beginObserving() -> Bool {
        if switcherElement != nil {
            return true
        }
        guard let dockApplication = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.dock"
        }) else {
            return false
        }

        let root = AXUIElementCreateApplication(dockApplication.processIdentifier)
        applicationCandidates = runningApplicationCandidates()
        var visited = Set<CFHashCode>()
        var remainingBudget = 400
        guard let switcher = findProcessSwitcher(
            from: root,
            depth: 0,
            visited: &visited,
            remainingBudget: &remainingBudget
        ) else {
            return false
        }

        switcherElement = switcher
        guard installObserver(for: switcher, processIdentifier: dockApplication.processIdentifier) else {
            // Selection polling and keyboard/mouse lifecycle fallbacks still provide
            // a usable path when this Dock build does not expose AX notifications.
            return true
        }
        return true
    }

    func currentSelection() -> CmdTabSwitcherSelection? {
        guard let switcherElement,
              let selectedItems = elementsAttribute(
                kAXSelectedChildrenAttribute,
                from: switcherElement
              ),
              let selected = selectedItems.first
        else {
            return nil
        }

        let title = stringAttribute(kAXTitleAttribute, from: selected)
            ?? stringAttribute(kAXDescriptionAttribute, from: selected)
            ?? ""
        let selectedURL = urlAttribute(kAXURLAttribute, from: selected)
        let bundleIdentifier = selectedURL.flatMap { Bundle(url: $0)?.bundleIdentifier }
        let candidates = applicationCandidates
        let resolvedBundleIdentifier = bundleIdentifier
            ?? selectedURL.flatMap { url in
                candidates.first { $0.bundleURL?.standardizedFileURL == url.standardizedFileURL }?.bundleIdentifier
            }
        guard let application = CmdTabApplicationResolutionPolicy.resolve(
            bundleIdentifier: resolvedBundleIdentifier,
            title: title,
            candidates: candidates
        ),
        let position = pointAttribute(kAXPositionAttribute, from: selected),
        let size = sizeAttribute(kAXSizeAttribute, from: selected),
        size.width > 0,
        size.height > 0 else {
            return nil
        }
        return CmdTabSwitcherSelection(
            application: application,
            title: title.isEmpty ? (application.localizedName ?? "") : title,
            accessibilityFrame: CGRect(origin: position, size: size)
        )
    }

    func stopObserving() {
        guard let observer, let switcherElement else {
            self.observer = nil
            self.switcherElement = nil
            observesSelectionChanges = false
            observesDestruction = false
            applicationCandidates = []
            return
        }
        if observesSelectionChanges {
            AXObserverRemoveNotification(
                observer,
                switcherElement,
                kAXSelectedChildrenChangedNotification as CFString
            )
        }
        if observesDestruction {
            AXObserverRemoveNotification(
                observer,
                switcherElement,
                kAXUIElementDestroyedNotification as CFString
            )
        }
        CFRunLoopRemoveSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .commonModes
        )
        self.observer = nil
        self.switcherElement = nil
        observesSelectionChanges = false
        observesDestruction = false
        applicationCandidates = []
    }

    fileprivate func handle(notification: String, from element: AXUIElement) {
        guard let switcherElement, CFEqual(switcherElement, element) else {
            return
        }
        if notification == kAXSelectedChildrenChangedNotification {
            onSelectionChanged?()
        } else if notification == kAXUIElementDestroyedNotification {
            onDestroyed?()
        }
    }

    private func installObserver(
        for switcher: AXUIElement,
        processIdentifier: pid_t
    ) -> Bool {
        var observer: AXObserver?
        guard AXObserverCreate(processIdentifier, cmdTabAXObserverCallback, &observer) == .success,
              let observer
        else {
            return false
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let selectionError = AXObserverAddNotification(
            observer,
            switcher,
            kAXSelectedChildrenChangedNotification as CFString,
            refcon
        )
        let destructionError = AXObserverAddNotification(
            observer,
            switcher,
            kAXUIElementDestroyedNotification as CFString,
            refcon
        )
        let didRegisterSelection = selectionError == .success
            || selectionError == .notificationAlreadyRegistered
        let didRegisterDestruction = destructionError == .success
            || destructionError == .notificationAlreadyRegistered
        guard didRegisterSelection || didRegisterDestruction else {
            return false
        }

        self.observer = observer
        observesSelectionChanges = didRegisterSelection
        observesDestruction = didRegisterDestruction
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .commonModes
        )
        return true
    }

    private func findProcessSwitcher(
        from element: AXUIElement,
        depth: Int,
        visited: inout Set<CFHashCode>,
        remainingBudget: inout Int
    ) -> AXUIElement? {
        guard depth <= 12, remainingBudget > 0 else {
            return nil
        }
        remainingBudget -= 1
        let hash = CFHash(element)
        guard visited.insert(hash).inserted else {
            return nil
        }
        if stringAttribute(kAXSubroleAttribute, from: element) == "AXProcessSwitcherList"
            || stringAttribute(kAXRoleAttribute, from: element) == "AXProcessSwitcherList" {
            return element
        }
        guard let children = elementsAttribute(kAXChildrenAttribute, from: element) else {
            return nil
        }
        for child in children {
            if let match = findProcessSwitcher(
                from: child,
                depth: depth + 1,
                visited: &visited,
                remainingBudget: &remainingBudget
            ) {
                return match
            }
        }
        return nil
    }

    private func runningApplicationCandidates() -> [CmdTabApplicationCandidate] {
        NSWorkspace.shared.runningApplications.compactMap { application -> CmdTabApplicationCandidate? in
            guard application.activationPolicy == .regular else {
                return nil
            }
            return CmdTabApplicationCandidate(
                processIdentifier: application.processIdentifier,
                bundleIdentifier: application.bundleIdentifier,
                localizedName: application.localizedName,
                bundleURL: application.bundleURL
            )
        }
    }

    private func elementsAttribute(_ attribute: String, from element: AXUIElement) -> [AXUIElement]? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue) == .success else {
            return nil
        }
        return rawValue as? [AXUIElement]
    }

    private func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue) == .success else {
            return nil
        }
        return rawValue as? String
    }

    private func urlAttribute(_ attribute: String, from element: AXUIElement) -> URL? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue) == .success,
              let rawValue
        else {
            return nil
        }
        if let url = rawValue as? URL {
            return url
        }
        if let url = rawValue as? NSURL {
            return url as URL
        }
        return nil
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
        return AXValueGetValue(value, .cgPoint, &point) ? point : nil
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
        return AXValueGetValue(value, .cgSize, &size) ? size : nil
    }
}

private func cmdTabAXObserverCallback(
    observer: AXObserver,
    element: AXUIElement,
    notification: CFString,
    refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else {
        return
    }
    let provider = Unmanaged<SystemCmdTabProcessSwitcherProvider>
        .fromOpaque(refcon)
        .takeUnretainedValue()
    let notificationName = notification as String
    Task { @MainActor in
        provider.handle(notification: notificationName, from: element)
    }
}
