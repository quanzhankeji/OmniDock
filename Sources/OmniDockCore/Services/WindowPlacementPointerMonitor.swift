import AppKit
import Carbon.HIToolbox
import CoreGraphics

enum WindowPlacementGreenButtonPolicy {
    static let refreshInterval: TimeInterval = 0.45
    static let snapshotLifetime: TimeInterval = 0.9

    static func shouldForwardNativeAction(
        modifiers _: NSEvent.ModifierFlags
    ) -> Bool {
        true
    }

    // The green-button snapshot is reused for click interception: a press is
    // only consumed when the pointer is inside a fresh snapshot of the button.
    static func shouldSuppressNativeHover(
        point: CGPoint,
        buttonFrame: CGRect?,
        expiresAt: TimeInterval?,
        now: TimeInterval
    ) -> Bool {
        (expiresAt ?? -.infinity) >= now
            && buttonFrame?.insetBy(dx: -3, dy: -3).contains(point) == true
    }
}

enum WindowPlacementDragPolicy {
    enum Interaction: Equatable {
        case pending
        case moving
        case resizing
    }

    static func interaction(
        initialFrame: CGRect,
        currentFrame: CGRect,
        threshold: CGFloat = 3
    ) -> Interaction {
        let sizeChanged = abs(currentFrame.width - initialFrame.width) >= threshold
            || abs(currentFrame.height - initialFrame.height) >= threshold
        if sizeChanged {
            return .resizing
        }
        return recognizedWindowMovement(
            initialFrame: initialFrame,
            currentFrame: currentFrame,
            threshold: threshold
        ) ? .moving : .pending
    }

    // macOS can resize a window mid-move, for example when it crosses onto a
    // smaller display. A drag session therefore keeps its first recognized
    // interaction; only a pending session may still be classified.
    static func nextInteraction(
        current: Interaction,
        initialFrame: CGRect,
        currentFrame: CGRect,
        threshold: CGFloat = 3
    ) -> Interaction {
        guard current == .pending else {
            return current
        }
        return interaction(
            initialFrame: initialFrame,
            currentFrame: currentFrame,
            threshold: threshold
        )
    }

    static func recognizedWindowMovement(
        initialFrame: CGRect,
        currentFrame: CGRect,
        threshold: CGFloat = 3
    ) -> Bool {
        hypot(
            currentFrame.minX - initialFrame.minX,
            currentFrame.minY - initialFrame.minY
        ) >= threshold
    }

    static func matchingCommand(
        at point: CGPoint,
        screen: WindowPlacementScreen,
        configuration: WindowPlacementConfiguration
    ) -> WindowPlacementCommand? {
        configuration.commands.first { command in
            guard command.isEnabled,
                  command.behavior.supportsDragActivation,
                  let activationRegion = command.activationRegion
            else {
                return false
            }
            return activationRegion.frame(in: screen.frame).contains(point)
        }
    }
}

// Escape cancels a drag, which needs a tap that can swallow the key so it never
// reaches the window underneath. Interception is therefore open only between a
// left-button press and its release: a persistent keyDown tap would route every
// keystroke on the system through this process for as long as window placement
// is enabled, which is a keylogger-shaped surface the feature does not need.
enum WindowPlacementKeyboardInterceptionPolicy {
    static func nextState(
        isIntercepting: Bool,
        eventType: CGEventType
    ) -> Bool {
        switch eventType {
        case .leftMouseDown:
            return true
        case .leftMouseUp, .mouseMoved:
            // A plain move means no button is held (a held button reports
            // .leftMouseDragged), so this also recovers from a mouse-up that
            // was missed while the tap was disabled.
            return false
        default:
            return isIntercepting
        }
    }
}

enum WindowPlacementEscapeCancellationPolicy {
    static func isAvailable(
        isEnabled: Bool,
        interaction: WindowPlacementDragPolicy.Interaction,
        hasPresentedDragRegions: Bool
    ) -> Bool {
        isEnabled
            && interaction == .moving
            && hasPresentedDragRegions
    }
}

enum WindowPlacementSizeHUDPolicy {
    static let refreshInterval: TimeInterval = 1.0 / 30.0
    static let rapidMotionRevealDelay: TimeInterval = 0.14
    private static let resizeEdgeTolerance: CGFloat = 14
    private static let motionWindow: TimeInterval = 0.1
    private static let minimumSampleInterval: TimeInterval = 1.0 / 240.0
    private static let rapidMotionMinimumDuration: TimeInterval = 0.06
    private static let settledMotionMinimumDuration: TimeInterval = 0.1
    private static let rapidMotionMinimumSamples = 3
    private static let rapidPointerSpeed: CGFloat = 1_100
    private static let settledPointerSpeed: CGFloat = 450

    struct MotionTracker {
        private struct Sample {
            let timestamp: TimeInterval
            let distance: CGFloat
            let elapsed: TimeInterval
        }

        private var samples: [Sample] = []
        private var pendingDistance: CGFloat = 0
        private var pendingElapsed: TimeInterval = 0
        private var rapidSampleCount = 0
        private var rapidDuration: TimeInterval = 0
        private var settledDuration: TimeInterval = 0
        private(set) var isRapid = false

        mutating func record(
            from start: CGPoint,
            to end: CGPoint,
            elapsed: TimeInterval,
            timestamp: TimeInterval
        ) -> Bool {
            guard elapsed > 0, elapsed <= 0.25 else {
                reset()
                return false
            }

            pendingDistance += hypot(end.x - start.x, end.y - start.y)
            pendingElapsed += elapsed
            guard pendingElapsed >= minimumSampleInterval else {
                return isRapid
            }

            samples.append(Sample(
                timestamp: timestamp,
                distance: pendingDistance,
                elapsed: pendingElapsed
            ))
            pendingDistance = 0
            pendingElapsed = 0
            samples.removeAll {
                timestamp - $0.timestamp > motionWindow
            }

            let totals = samples.reduce(into: (distance: CGFloat(0), elapsed: 0.0)) {
                result, sample in
                result.distance += sample.distance
                result.elapsed += sample.elapsed
            }
            guard totals.elapsed > 0 else {
                reset()
                return false
            }
            let speed = totals.distance / totals.elapsed

            if isRapid {
                if speed <= settledPointerSpeed {
                    settledDuration += samples.last?.elapsed ?? 0
                    if settledDuration >= settledMotionMinimumDuration {
                        reset()
                    }
                } else {
                    settledDuration = 0
                }
                return isRapid
            }

            if speed >= rapidPointerSpeed {
                rapidSampleCount += 1
                rapidDuration += samples.last?.elapsed ?? 0
                if rapidSampleCount >= rapidMotionMinimumSamples,
                   rapidDuration >= rapidMotionMinimumDuration
                {
                    isRapid = true
                    settledDuration = 0
                }
            } else {
                rapidSampleCount = 0
                rapidDuration = 0
            }
            return isRapid
        }

        mutating func reset() {
            samples.removeAll(keepingCapacity: true)
            pendingDistance = 0
            pendingElapsed = 0
            rapidSampleCount = 0
            rapidDuration = 0
            settledDuration = 0
            isRapid = false
        }
    }

    static func beginsNearResizeEdge(
        at point: CGPoint,
        windowFrame: CGRect
    ) -> Bool {
        let outerFrame = windowFrame.insetBy(
            dx: -resizeEdgeTolerance,
            dy: -resizeEdgeTolerance
        )
        let innerFrame = windowFrame.insetBy(
            dx: resizeEdgeTolerance,
            dy: resizeEdgeTolerance
        )
        return outerFrame.contains(point) && !innerFrame.contains(point)
    }

    static func shouldTrack(
        isEnabled: Bool,
        interaction: WindowPlacementDragPolicy.Interaction,
        beganNearResizeEdge: Bool
    ) -> Bool {
        isEnabled
            && interaction == .resizing
            && beganNearResizeEdge
    }

}

private final class WindowPlacementPointerState: @unchecked Sendable {
    struct GreenButtonSnapshot {
        let target: WindowPlacementTarget
        let frame: CGRect
        let expiresAt: TimeInterval
    }

    private let lock = NSLock()
    private var greenButton: GreenButtonSnapshot?
    private var greenButtonPress: GreenButtonSnapshot?
    private var dragCancellationAvailable = false
    private var dragCancellationPending = false
    private var lastPointerDispatchAt: TimeInterval = 0
    private var pendingDragPoint: CGPoint?
    private var pendingDragTimestamp: TimeInterval = 0

    func updateGreenButton(_ snapshot: GreenButtonSnapshot?) {
        lock.lock()
        greenButton = snapshot
        lock.unlock()
    }

    func greenButton(
        at point: CGPoint,
        now: TimeInterval
    ) -> GreenButtonSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard let greenButton,
              WindowPlacementGreenButtonPolicy.shouldSuppressNativeHover(
                  point: point,
                  buttonFrame: greenButton.frame,
                  expiresAt: greenButton.expiresAt,
                  now: now
              )
        else {
            return nil
        }
        return greenButton
    }

    func beginGreenButtonPress(_ snapshot: GreenButtonSnapshot) {
        lock.lock()
        greenButtonPress = snapshot
        lock.unlock()
    }

    func hasGreenButtonPress() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return greenButtonPress != nil
    }

    func cancelGreenButtonPress() {
        lock.lock()
        greenButtonPress = nil
        lock.unlock()
    }

    func setDragCancellationAvailable(_ isAvailable: Bool) {
        lock.lock()
        if !dragCancellationPending {
            dragCancellationAvailable = isAvailable
        }
        lock.unlock()
    }

    func requestDragCancellation() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard dragCancellationAvailable, !dragCancellationPending else {
            return false
        }
        dragCancellationAvailable = false
        dragCancellationPending = true
        return true
    }

    func isDragCancellationPending() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return dragCancellationPending
    }

    func resetDragCancellation() {
        lock.lock()
        dragCancellationAvailable = false
        dragCancellationPending = false
        lock.unlock()
    }

    /// Ends a green-button press. Returns the pressed snapshot when the release
    /// happened inside the button frame (a real click); otherwise returns nil
    /// (drag-away cancels the click) after clearing the press.
    func finishGreenButtonPress(at point: CGPoint) -> GreenButtonSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard let press = greenButtonPress else {
            return nil
        }
        greenButtonPress = nil
        return press.frame.insetBy(dx: -3, dy: -3).contains(point) ? press : nil
    }

    /// Coalesces drag events. While a delivery is already queued for the main
    /// actor, later events only replace the stored position; the caller is told
    /// to schedule a hop exactly once per pending position. Without this a
    /// momentarily busy main thread accumulates a backlog of hops that all
    /// flush at once and drag the size bubble through stale positions.
    func enqueueDragPoint(
        _ point: CGPoint,
        timestamp: TimeInterval
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let needsDelivery = pendingDragPoint == nil
        pendingDragPoint = point
        pendingDragTimestamp = timestamp
        return needsDelivery
    }

    func takePendingDragPoint() -> (point: CGPoint, timestamp: TimeInterval)? {
        lock.lock()
        defer { lock.unlock() }
        guard let point = pendingDragPoint else {
            return nil
        }
        pendingDragPoint = nil
        return (point, pendingDragTimestamp)
    }

    func clearPendingDragPoint() {
        lock.lock()
        pendingDragPoint = nil
        lock.unlock()
    }

    func shouldDispatchPointerMove(
        at timestamp: TimeInterval,
        minimumInterval: TimeInterval
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard timestamp - lastPointerDispatchAt >= minimumInterval else {
            return false
        }
        lastPointerDispatchAt = timestamp
        return true
    }
}

private struct WindowPlacementDragFrameRequest: @unchecked Sendable {
    let target: WindowPlacementTarget
}

private struct WindowPlacementGreenButtonQueryResult: @unchecked Sendable {
    let target: WindowPlacementTarget
    let buttonFrame: CGRect
}

private final class WindowPlacementEventTapThread: @unchecked Sendable {
    typealias Handler = (CGEventType, CGEvent) -> Unmanaged<CGEvent>?

    private static let startupTimeout: DispatchTimeInterval = .seconds(2)

    private let handler: Handler
    private let lifecycleLock = NSLock()
    private var eventTap: CFMachPort?
    private var keyboardTap: CFMachPort?
    private var keyboardSource: CFRunLoopSource?
    private var runLoop: CFRunLoop?
    private var thread: Thread?
    private var stopped: DispatchSemaphore?
    private var stopRequested = false
    private var recoveryPolicy = EventTapRecoveryPolicy()

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    @discardableResult
    func start() -> Bool {
        stop()

        let ready = DispatchSemaphore(value: 0)
        let stopped = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            self?.run(ready: ready, stopped: stopped)
        }
        thread.name = "OmniDock Window Placement Event Tap"
        thread.qualityOfService = .userInteractive

        lifecycleLock.lock()
        stopRequested = false
        self.thread = thread
        self.stopped = stopped
        lifecycleLock.unlock()
        thread.start()

        guard ready.wait(timeout: .now() + Self.startupTimeout) == .success else {
            stop()
            return false
        }
        lifecycleLock.lock()
        let didStart = eventTap != nil && runLoop != nil
        lifecycleLock.unlock()
        return didStart
    }

    func stop() {
        lifecycleLock.lock()
        stopRequested = true
        let runLoop = self.runLoop
        let stopped = self.stopped
        let thread = self.thread
        lifecycleLock.unlock()

        if let runLoop {
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [weak self] in
                guard let self else {
                    return
                }
                self.lifecycleLock.lock()
                let eventTap = self.eventTap
                self.lifecycleLock.unlock()
                if let eventTap {
                    CGEvent.tapEnable(tap: eventTap, enable: false)
                }
                CFRunLoopStop(runLoop)
            }
            CFRunLoopWakeUp(runLoop)
        }

        guard thread !== Thread.current else {
            return
        }
        _ = stopped?.wait(timeout: .now() + Self.startupTimeout)
    }

    fileprivate func process(
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        setKeyboardMonitoringEnabled(
            WindowPlacementKeyboardInterceptionPolicy.nextState(
                isIntercepting: isKeyboardMonitoringActive,
                eventType: type
            )
        )
        let result = handler(type, event)
        guard type == .tapDisabledByTimeout || type == .tapDisabledByUserInput else {
            return result
        }
        scheduleRecovery()
        return result
    }

    private var isKeyboardMonitoringActive: Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return keyboardTap != nil
    }

    // Must be called on the tap thread: it mutates that thread's run loop.
    fileprivate func setKeyboardMonitoringEnabled(_ isEnabled: Bool) {
        lifecycleLock.lock()
        let runLoop = self.runLoop
        let isActive = keyboardTap != nil
        lifecycleLock.unlock()

        guard isEnabled != isActive,
              let runLoop,
              CFRunLoopGetCurrent() === runLoop
        else {
            return
        }
        guard isEnabled else {
            teardownKeyboardTap(runLoop: runLoop)
            return
        }

        let mask = CGEventMask(1) << CGEventMask(CGEventType.keyDown.rawValue)
        guard let keyboardTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: windowPlacementEventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ),
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, keyboardTap, 0)
        else {
            return
        }
        lifecycleLock.lock()
        self.keyboardTap = keyboardTap
        self.keyboardSource = source
        lifecycleLock.unlock()
        CFRunLoopAddSource(runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: keyboardTap, enable: true)
    }

    private func teardownKeyboardTap(runLoop: CFRunLoop?) {
        lifecycleLock.lock()
        let keyboardTap = self.keyboardTap
        let keyboardSource = self.keyboardSource
        self.keyboardTap = nil
        self.keyboardSource = nil
        lifecycleLock.unlock()

        if let keyboardSource, let runLoop {
            CFRunLoopRemoveSource(runLoop, keyboardSource, .commonModes)
        }
        if let keyboardTap {
            CGEvent.tapEnable(tap: keyboardTap, enable: false)
            CFMachPortInvalidate(keyboardTap)
        }
    }

    private func run(
        ready: DispatchSemaphore,
        stopped: DispatchSemaphore
    ) {
        let mask = [
            CGEventType.mouseMoved,
            .leftMouseDown,
            .leftMouseDragged,
            .leftMouseUp
        ].reduce(CGEventMask(0)) {
            $0 | (CGEventMask(1) << CGEventMask($1.rawValue))
        }
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: windowPlacementEventTapCallback,
            userInfo: userInfo
        ),
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        else {
            ready.signal()
            clearState()
            stopped.signal()
            return
        }

        let runLoop = CFRunLoopGetCurrent()
        lifecycleLock.lock()
        self.eventTap = eventTap
        self.runLoop = runLoop
        let shouldRun = !stopRequested
        recoveryPolicy.reset()
        recoveryPolicy.didEnable(at: ProcessInfo.processInfo.systemUptime)
        lifecycleLock.unlock()

        CFRunLoopAddSource(runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        ready.signal()
        if shouldRun {
            CFRunLoopRun()
        }

        teardownKeyboardTap(runLoop: runLoop)
        CFRunLoopRemoveSource(runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: false)
        CFMachPortInvalidate(eventTap)
        clearState()
        stopped.signal()
    }

    private func scheduleRecovery() {
        lifecycleLock.lock()
        let delay = recoveryPolicy.nextDelay(
            afterFailureAt: ProcessInfo.processInfo.systemUptime
        )
        let runLoop = self.runLoop
        lifecycleLock.unlock()
        guard let delay, let runLoop else {
            NSLog("OmniDock window placement event tap recovery exhausted")
            return
        }

        DispatchQueue.global(qos: .userInteractive).asyncAfter(
            deadline: .now() + delay
        ) { [weak self] in
            guard let self else {
                return
            }
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) {
                self.lifecycleLock.lock()
                let eventTap = self.eventTap
                let shouldEnable = !self.stopRequested
                self.lifecycleLock.unlock()
                guard shouldEnable, let eventTap else {
                    return
                }
                CGEvent.tapEnable(tap: eventTap, enable: true)
                self.lifecycleLock.lock()
                let keyboardTap = self.keyboardTap
                self.lifecycleLock.unlock()
                if let keyboardTap {
                    CGEvent.tapEnable(tap: keyboardTap, enable: true)
                }
                self.lifecycleLock.lock()
                self.recoveryPolicy.didEnable(
                    at: ProcessInfo.processInfo.systemUptime
                )
                self.lifecycleLock.unlock()
            }
            CFRunLoopWakeUp(runLoop)
        }
    }

    private func clearState() {
        lifecycleLock.lock()
        eventTap = nil
        keyboardTap = nil
        keyboardSource = nil
        runLoop = nil
        thread = nil
        stopped = nil
        stopRequested = false
        recoveryPolicy.reset()
        lifecycleLock.unlock()
    }
}

@MainActor
final class WindowPlacementPointerMonitor {
    var onGreenButtonClicked: ((WindowPlacementTarget) -> Void)?
    var onDragBegan: ((
        WindowPlacementTarget,
        [WindowPlacementScreen]
    ) -> Void)?
    var onDragTargetChanged: ((
        WindowPlacementTarget,
        WindowPlacementCommand?,
        WindowPlacementScreen?
    ) -> Void)?
    var onDragCancelled: (() -> Void)?
    var onDragCompleted: ((
        WindowPlacementTarget,
        WindowPlacementCommand,
        WindowPlacementScreen
    ) -> Void)?
    var onDragSizeChanged: ((CGSize, CGPoint) -> Void)?
    var onDragSizePointMoved: ((CGPoint) -> Void)?
    var onDragSizeSuspended: (() -> Void)?
    var onDragSizeHidden: (() -> Void)?

    private struct DragSession {
        let id = UUID()
        let target: WindowPlacementTarget
        let originalFrame: CGRect
        let beganNearResizeEdge: Bool
        var interaction: WindowPlacementDragPolicy.Interaction = .pending
        var hasPresentedDragRegions = false
        var activeCommand: WindowPlacementCommand?
        var activeScreen: WindowPlacementScreen?
        var lastInspectionAt: TimeInterval = 0
        var lastPointerPoint: CGPoint
        var lastPointerTimestamp: TimeInterval
        var sizeHUDMotionTracker = WindowPlacementSizeHUDPolicy.MotionTracker()
        var isSizeHUDVisible = false
    }

    private let pointerState = WindowPlacementPointerState()
    private let accessibilityQueue = DispatchQueue(
        label: "com.quanzhankeji.OmniDock.window-placement-accessibility",
        qos: .userInteractive
    )
    private var configuration = WindowPlacementConfiguration.default
    private lazy var eventTapThread = WindowPlacementEventTapThread {
        [weak self] type, event in
        self?.process(type: type, event: event)
            ?? Unmanaged.passUnretained(event)
    }
    private var isEventTapRunning = false
    private var dragSession: DragSession?
    private var greenButtonRefreshTimer: Timer?
    private var lastGreenButtonRefreshAt: TimeInterval = 0
    private var isGreenButtonQueryInFlight = false
    // Kept apart from `accessibilityQueue`: the green-button probe walks the
    // same application that is being resized, and sharing one serial queue
    // would let it delay every size measurement behind it.
    private let dragFrameQueue = DispatchQueue(
        label: "com.quanzhankeji.OmniDock.window-placement-drag-frame",
        qos: .userInteractive
    )
    private var isDragFrameQueryInFlight = false
    private var sizeHUDRevealWorkItem: DispatchWorkItem?

    func start(configuration: WindowPlacementConfiguration) {
        self.configuration = configuration
        if !configuration.allowsEscapeToCancelDrag {
            pointerState.setDragCancellationAvailable(false)
        }
        guard !isEventTapRunning else {
            updateGreenButtonRefresh()
            return
        }
        isEventTapRunning = eventTapThread.start()
        guard isEventTapRunning else {
            return
        }
        updateGreenButtonRefresh()
    }

    func stop() {
        stopGreenButtonRefresh()
        cancelSizeHUDReveal()
        dragSession = nil
        lastGreenButtonRefreshAt = 0
        pointerState.clearPendingDragPoint()
        pointerState.cancelGreenButtonPress()
        pointerState.resetDragCancellation()
        pointerState.updateGreenButton(nil)
        eventTapThread.stop()
        isEventTapRunning = false
        onDragCancelled?()
    }

    fileprivate nonisolated func process(
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        let point = event.location
        let timestamp = ProcessInfo.processInfo.systemUptime

        switch type {
        case .mouseMoved:
            guard pointerState.shouldDispatchPointerMove(
                at: timestamp,
                minimumInterval: 0.008
            ) else {
                return Unmanaged.passUnretained(event)
            }
            Task { @MainActor [weak self] in
                self?.handlePointerMoved(at: point)
            }
        case .leftMouseDown:
            // Replace the native green-button action with our own toggle:
            // consume the press so the system never sees the click.
            if let snapshot = pointerState.greenButton(
                at: point,
                now: timestamp
            ) {
                pointerState.beginGreenButtonPress(snapshot)
                return nil
            }
            Task { @MainActor [weak self] in
                self?.beginDragCandidate(at: point, timestamp: timestamp)
            }
        case .leftMouseDragged:
            if pointerState.hasGreenButtonPress() {
                return nil
            }
            if pointerState.isDragCancellationPending() {
                return Unmanaged.passUnretained(event)
            }
            if pointerState.enqueueDragPoint(point, timestamp: timestamp) {
                Task { @MainActor [weak self] in
                    self?.drainPendingDrag()
                }
            }
        case .leftMouseUp:
            if let snapshot = pointerState.finishGreenButtonPress(at: point) {
                Task { @MainActor [weak self] in
                    self?.onGreenButtonClicked?(snapshot.target)
                }
                return nil
            }
            Task { @MainActor [weak self] in
                self?.finishDrag()
            }
        case .keyDown:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            guard keyCode == Int64(kVK_Escape),
                  pointerState.requestDragCancellation()
            else {
                break
            }
            Task { @MainActor [weak self] in
                self?.cancelDragFromEscape()
            }
            return nil
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    private func drainPendingDrag() {
        guard let pending = pointerState.takePendingDragPoint() else {
            return
        }
        updateDrag(at: pending.point, timestamp: pending.timestamp)
    }

    private func handlePointerMoved(at point: CGPoint) {
        let now = ProcessInfo.processInfo.systemUptime
        if configuration.showsGreenButtonPalette,
           now - lastGreenButtonRefreshAt >= 0.15 {
            refreshFocusedGreenButton(now: now)
        }
    }

    private func updateGreenButtonRefresh() {
        guard configuration.showsGreenButtonPalette else {
            stopGreenButtonRefresh()
            pointerState.updateGreenButton(nil)
            return
        }
        guard greenButtonRefreshTimer == nil else {
            refreshFocusedGreenButton()
            return
        }
        let timer = Timer(
            timeInterval: WindowPlacementGreenButtonPolicy.refreshInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshFocusedGreenButton()
            }
        }
        greenButtonRefreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        refreshFocusedGreenButton()
    }

    private func stopGreenButtonRefresh() {
        greenButtonRefreshTimer?.invalidate()
        greenButtonRefreshTimer = nil
    }

    private func refreshFocusedGreenButton(
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        lastGreenButtonRefreshAt = now
        guard configuration.showsGreenButtonPalette else {
            pointerState.updateGreenButton(nil)
            return
        }
        // The probe issues a dozen accessibility round trips to the frontmost
        // application, which during a drag is the window being resized. The
        // snapshot is not consulted mid-drag, so skipping it keeps that
        // application free to answer the measurement queries instead.
        guard dragSession == nil, !isGreenButtonQueryInFlight else {
            return
        }
        isGreenButtonQueryInFlight = true
        accessibilityQueue.async { [weak self] in
            let result = WindowPlacementAccessibility.focusedGreenButtonTarget().map {
                WindowPlacementGreenButtonQueryResult(
                    target: $0.target,
                    buttonFrame: $0.buttonFrame
                )
            }
            Task { @MainActor [weak self] in
                self?.finishGreenButtonQuery(result, now: now)
            }
        }
    }

    private func finishGreenButtonQuery(
        _ result: WindowPlacementGreenButtonQueryResult?,
        now: TimeInterval
    ) {
        isGreenButtonQueryInFlight = false
        guard configuration.showsGreenButtonPalette, let result else {
            pointerState.updateGreenButton(nil)
            return
        }
        let snapshot = WindowPlacementPointerState.GreenButtonSnapshot(
            target: result.target,
            frame: result.buttonFrame,
            expiresAt: now
                + WindowPlacementGreenButtonPolicy.snapshotLifetime
        )
        pointerState.updateGreenButton(snapshot)
    }

    private func beginDragCandidate(
        at point: CGPoint,
        timestamp: TimeInterval
    ) {
        cancelSizeHUDReveal()
        pointerState.clearPendingDragPoint()
        pointerState.resetDragCancellation()
        onDragSizeHidden?()
        guard configuration.observesWindowDragging,
              let target = WindowPlacementAccessibility.window(at: point)
        else {
            dragSession = nil
            return
        }
        dragSession = DragSession(
            target: target,
            originalFrame: target.frame,
            beganNearResizeEdge: WindowPlacementSizeHUDPolicy.beginsNearResizeEdge(
                at: point,
                windowFrame: target.frame
            ),
            lastPointerPoint: point,
            lastPointerTimestamp: timestamp
        )
    }

    private func updateDrag(at point: CGPoint, timestamp: TimeInterval) {
        guard var session = dragSession else {
            return
        }

        let shouldHideSizeHUD = session.sizeHUDMotionTracker.record(
            from: session.lastPointerPoint,
            to: point,
            elapsed: timestamp - session.lastPointerTimestamp,
            timestamp: timestamp
        )
        session.lastPointerPoint = point
        session.lastPointerTimestamp = timestamp

        if WindowPlacementSizeHUDPolicy.shouldTrack(
            isEnabled: configuration.showsSizeOnDrag,
            interaction: session.interaction,
            beganNearResizeEdge: session.beganNearResizeEdge
        ) {
            if shouldHideSizeHUD {
                hideSizeHUD(in: &session)
                dragSession = session
                scheduleSizeHUDReveal(for: session.id)
                return
            }
        }

        // The bubble follows the pointer on every event; only the measurement
        // it prints is sampled on the slower inspection cadence. Keeping the
        // two apart is what stops window queries from gating how smoothly the
        // bubble tracks the cursor.
        if session.isSizeHUDVisible {
            onDragSizePointMoved?(point)
        }

        let inspectionInterval = session.interaction == .resizing
            ? WindowPlacementSizeHUDPolicy.refreshInterval
            : 0.05
        guard timestamp - session.lastInspectionAt >= inspectionInterval else {
            dragSession = session
            return
        }
        session.lastInspectionAt = timestamp

        // A recognized resize can no longer be reclassified, so its frame is
        // sampled off the main thread. The window being resized is busy laying
        // itself out, and a synchronous accessibility round trip to it would
        // stall every queued pointer event behind it.
        if session.interaction == .resizing {
            pointerState.setDragCancellationAvailable(false)
            guard WindowPlacementSizeHUDPolicy.shouldTrack(
                isEnabled: configuration.showsSizeOnDrag,
                interaction: session.interaction,
                beganNearResizeEdge: session.beganNearResizeEdge
            ) else {
                hideSizeHUD(in: &session)
                cancelSizeHUDReveal()
                dragSession = session
                return
            }
            cancelSizeHUDReveal()
            dragSession = session
            requestResizeFrameSample(for: session)
            return
        }

        guard let currentFrame = WindowPlacementAccessibility.currentFrame(
            of: session.target
        ) else {
            dragSession = nil
            cancelSizeHUDReveal()
            pointerState.clearPendingDragPoint()
            pointerState.resetDragCancellation()
            onDragCancelled?()
            return
        }

        session.interaction = WindowPlacementDragPolicy.nextInteraction(
            current: session.interaction,
            initialFrame: session.originalFrame,
            currentFrame: currentFrame
        )

        if session.interaction == .resizing {
            pointerState.setDragCancellationAvailable(false)
            guard WindowPlacementSizeHUDPolicy.shouldTrack(
                isEnabled: configuration.showsSizeOnDrag,
                interaction: session.interaction,
                beganNearResizeEdge: session.beganNearResizeEdge
            ) else {
                hideSizeHUD(in: &session)
                cancelSizeHUDReveal()
                dragSession = session
                return
            }
            cancelSizeHUDReveal()
            session.isSizeHUDVisible = true
            dragSession = session
            onDragSizeChanged?(currentFrame.size, point)
            return
        }

        hideSizeHUD(in: &session)
        cancelSizeHUDReveal()
        guard session.interaction == .moving else {
            pointerState.setDragCancellationAvailable(false)
            dragSession = session
            return
        }

        let screens = WindowPlacementScreens.current()
        if !session.hasPresentedDragRegions {
            session.hasPresentedDragRegions = true
            onDragBegan?(session.target, screens)
        }
        pointerState.setDragCancellationAvailable(
            WindowPlacementEscapeCancellationPolicy.isAvailable(
                isEnabled: configuration.allowsEscapeToCancelDrag,
                interaction: session.interaction,
                hasPresentedDragRegions: session.hasPresentedDragRegions
            )
        )
        let screen = WindowPlacementScreens.screen(
            containing: point,
            in: screens
        )
        let command = screen.flatMap {
            WindowPlacementDragPolicy.matchingCommand(
                at: point,
                screen: $0,
                configuration: configuration
            )
        }
        let activeScreen = command == nil ? nil : screen

        if command?.id != session.activeCommand?.id
            || activeScreen?.displayID != session.activeScreen?.displayID {
            session.activeCommand = command
            session.activeScreen = activeScreen
            onDragTargetChanged?(
                session.target,
                command,
                activeScreen
            )
        }
        dragSession = session
    }

    private func finishDrag() {
        cancelSizeHUDReveal()
        pointerState.clearPendingDragPoint()
        if pointerState.isDragCancellationPending() {
            dragSession = nil
            pointerState.resetDragCancellation()
            onDragCancelled?()
            return
        }
        pointerState.resetDragCancellation()
        guard let session = dragSession else {
            return
        }
        dragSession = nil
        guard session.interaction == .moving,
              let command = session.activeCommand,
              let screen = session.activeScreen
        else {
            onDragCancelled?()
            return
        }
        onDragCompleted?(session.target, command, screen)
    }

    private func cancelDragFromEscape() {
        guard let session = dragSession,
              WindowPlacementEscapeCancellationPolicy.isAvailable(
                  isEnabled: configuration.allowsEscapeToCancelDrag,
                  interaction: session.interaction,
                  hasPresentedDragRegions: session.hasPresentedDragRegions
              )
        else {
            pointerState.resetDragCancellation()
            return
        }
        dragSession = nil
        cancelSizeHUDReveal()
        pointerState.clearPendingDragPoint()
        pointerState.resetDragCancellation()
        onDragCancelled?()
    }

    private func hideSizeHUD(in session: inout DragSession) {
        guard session.isSizeHUDVisible else {
            return
        }
        session.isSizeHUDVisible = false
        onDragSizeSuspended?()
    }

    private func scheduleSizeHUDReveal(for sessionID: UUID) {
        sizeHUDRevealWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.revealSizeHUD(for: sessionID)
            }
        }
        sizeHUDRevealWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + WindowPlacementSizeHUDPolicy.rapidMotionRevealDelay,
            execute: workItem
        )
    }

    private func revealSizeHUD(for sessionID: UUID) {
        sizeHUDRevealWorkItem = nil
        guard var session = dragSession,
              session.id == sessionID,
              WindowPlacementSizeHUDPolicy.shouldTrack(
                  isEnabled: configuration.showsSizeOnDrag,
                  interaction: session.interaction,
                  beganNearResizeEdge: session.beganNearResizeEdge
              )
        else {
            return
        }
        session.lastInspectionAt = ProcessInfo.processInfo.systemUptime
        session.sizeHUDMotionTracker.reset()
        dragSession = session
        requestResizeFrameSample(for: session)
    }

    private func requestResizeFrameSample(for session: DragSession) {
        guard !isDragFrameQueryInFlight else {
            return
        }
        isDragFrameQueryInFlight = true
        let sessionID = session.id
        let request = WindowPlacementDragFrameRequest(target: session.target)
        dragFrameQueue.async { [weak self] in
            let frame = WindowPlacementAccessibility.currentFrame(
                of: request.target
            )
            // Main-thread work for this gesture is funnelled through the
            // main actor so a measurement can never overtake a pointer
            // position that was queued ahead of it. Mixing executors let a
            // late sample reposition the bubble to a stale point and be
            // corrected one event later, which reads as a jitter.
            Task { @MainActor [weak self] in
                self?.finishResizeFrameSample(frame, sessionID: sessionID)
            }
        }
    }

    /// A missing frame here is treated as a dropped sample rather than a lost
    /// window: an application that is mid-resize can miss a single query, and
    /// tearing the session down would leave the bubble frozen for the rest of
    /// the drag. The gesture still ends on mouse up.
    private func finishResizeFrameSample(
        _ frame: CGRect?,
        sessionID: UUID
    ) {
        isDragFrameQueryInFlight = false
        guard var session = dragSession,
              session.id == sessionID,
              session.interaction == .resizing,
              !session.sizeHUDMotionTracker.isRapid,
              sizeHUDRevealWorkItem == nil,
              WindowPlacementSizeHUDPolicy.shouldTrack(
                  isEnabled: configuration.showsSizeOnDrag,
                  interaction: session.interaction,
                  beganNearResizeEdge: session.beganNearResizeEdge
              ),
              let frame
        else {
            return
        }
        session.isSizeHUDVisible = true
        dragSession = session
        // Pair the measurement with the newest pointer position rather than the
        // one that requested it, so a late sample never snaps the bubble back.
        onDragSizeChanged?(frame.size, session.lastPointerPoint)
    }

    private func cancelSizeHUDReveal() {
        sizeHUDRevealWorkItem?.cancel()
        sizeHUDRevealWorkItem = nil
    }

}

private let windowPlacementEventTapCallback: CGEventTapCallBack = {
    _, type, event, userInfo in
    guard let userInfo else {
        return Unmanaged.passUnretained(event)
    }
    let eventTapThread = Unmanaged<WindowPlacementEventTapThread>
        .fromOpaque(userInfo)
        .takeUnretainedValue()
    return eventTapThread.process(type: type, event: event)
}
