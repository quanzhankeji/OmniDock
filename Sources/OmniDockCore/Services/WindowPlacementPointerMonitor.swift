import AppKit
import CoreGraphics

enum WindowPlacementGreenButtonPolicy {
    static let refreshInterval: TimeInterval = 0.45
    static let snapshotLifetime: TimeInterval = 0.9

    static func shouldForwardNativeAction(
        modifiers _: NSEvent.ModifierFlags
    ) -> Bool {
        true
    }

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

struct WindowPlacementGreenButtonHoverTracker {
    private var targetIdentifier: WindowPlacementRuntimeIdentifier?
    private var buttonFrame: CGRect?

    mutating func entered(
        targetIdentifier: WindowPlacementRuntimeIdentifier,
        buttonFrame: CGRect
    ) -> Bool {
        guard self.targetIdentifier != targetIdentifier
                || self.buttonFrame != buttonFrame
        else {
            return false
        }
        self.targetIdentifier = targetIdentifier
        self.buttonFrame = buttonFrame
        return true
    }

    mutating func leftButton() {
        targetIdentifier = nil
        buttonFrame = nil
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

private final class WindowPlacementPointerState: @unchecked Sendable {
    struct GreenButtonSnapshot {
        let target: WindowPlacementTarget
        let frame: CGRect
        let expiresAt: TimeInterval
    }

    private let lock = NSLock()
    private var greenButton: GreenButtonSnapshot?
    private var lastPointerDispatchAt: TimeInterval = 0

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
        let result = handler(type, event)
        guard type == .tapDisabledByTimeout || type == .tapDisabledByUserInput else {
            return result
        }
        scheduleRecovery()
        return result
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
    var onGreenButtonHover: ((WindowPlacementTarget, CGRect) -> Void)?
    var onPointerMoved: ((CGPoint) -> Void)?
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

    private struct DragSession {
        let target: WindowPlacementTarget
        let originalFrame: CGRect
        var interaction: WindowPlacementDragPolicy.Interaction = .pending
        var hasPresentedDragRegions = false
        var activeCommand: WindowPlacementCommand?
        var activeScreen: WindowPlacementScreen?
        var lastInspectionAt: TimeInterval = 0
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
    private var greenButtonHoverTracker =
        WindowPlacementGreenButtonHoverTracker()

    func start(configuration: WindowPlacementConfiguration) {
        self.configuration = configuration
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
        dragSession = nil
        lastGreenButtonRefreshAt = 0
        greenButtonHoverTracker.leftButton()
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
            if let snapshot = pointerState.greenButton(
                at: point,
                now: timestamp
            ) {
                Task { @MainActor [weak self] in
                    self?.handleProtectedGreenButtonHover(
                        snapshot,
                        at: point
                    )
                }
                return nil
            }
            Task { @MainActor [weak self] in
                self?.handlePointerMoved(at: point)
            }
        case .leftMouseDown:
            Task { @MainActor [weak self] in
                self?.beginDragCandidate(at: point)
            }
        case .leftMouseDragged:
            Task { @MainActor [weak self] in
                self?.updateDrag(at: point, timestamp: timestamp)
            }
        case .leftMouseUp:
            Task { @MainActor [weak self] in
                self?.finishDrag()
            }
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    private func handlePointerMoved(at point: CGPoint) {
        greenButtonHoverTracker.leftButton()
        onPointerMoved?(point)
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
            greenButtonHoverTracker.leftButton()
            pointerState.updateGreenButton(nil)
            return
        }
        guard !isGreenButtonQueryInFlight else {
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
            DispatchQueue.main.async { [weak self] in
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
            greenButtonHoverTracker.leftButton()
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

        let pointer = DisplayCoordinateConverter.eventTapPoint(
            fromAppKitPoint: NSEvent.mouseLocation
        )
        if WindowPlacementGreenButtonPolicy.shouldSuppressNativeHover(
            point: pointer,
            buttonFrame: result.buttonFrame,
            expiresAt: snapshot.expiresAt,
            now: now
        ) {
            handleProtectedGreenButtonHover(snapshot, at: pointer)
        }
    }

    private func handleProtectedGreenButtonHover(
        _ snapshot: WindowPlacementPointerState.GreenButtonSnapshot,
        at point: CGPoint
    ) {
        onPointerMoved?(point)
        if greenButtonHoverTracker.entered(
            targetIdentifier: snapshot.target.runtimeIdentifier,
            buttonFrame: snapshot.frame
        ) {
            onGreenButtonHover?(snapshot.target, snapshot.frame)
        }
    }

    private func beginDragCandidate(at point: CGPoint) {
        guard configuration.observesWindowDragging,
              let target = WindowPlacementAccessibility.window(at: point)
        else {
            dragSession = nil
            return
        }
        dragSession = DragSession(
            target: target,
            originalFrame: target.frame
        )
    }

    private func updateDrag(at point: CGPoint, timestamp: TimeInterval) {
        guard var session = dragSession,
              timestamp - session.lastInspectionAt >= 0.05
        else {
            return
        }
        session.lastInspectionAt = timestamp
        guard let currentFrame = WindowPlacementAccessibility.currentFrame(
            of: session.target
        ) else {
            dragSession = nil
            onDragCancelled?()
            return
        }

        session.interaction = WindowPlacementDragPolicy.nextInteraction(
            current: session.interaction,
            initialFrame: session.originalFrame,
            currentFrame: currentFrame
        )
        guard session.interaction == .moving else {
            dragSession = session
            return
        }

        let screens = WindowPlacementScreens.current()
        if !session.hasPresentedDragRegions {
            session.hasPresentedDragRegions = true
            onDragBegan?(session.target, screens)
        }
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
