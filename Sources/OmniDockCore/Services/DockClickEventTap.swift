import CoreGraphics
import Foundation

enum DockClickGesturePolicy {
    static let longPressDuration: TimeInterval = 0.65
    static let dragDistance: CGFloat = 5
    private static let passthroughModifierFlags: CGEventFlags = [
        .maskShift,
        .maskControl,
        .maskAlternate,
        .maskCommand,
        .maskSecondaryFn,
        .maskAlphaShift
    ]

    static func isLongPress(elapsed: TimeInterval) -> Bool {
        elapsed >= longPressDuration
    }

    static func isDrag(from start: CGPoint, to current: CGPoint) -> Bool {
        hypot(current.x - start.x, current.y - start.y) >= dragDistance
    }

    static func isPlainPrimaryClick(flags: CGEventFlags) -> Bool {
        flags.intersection(passthroughModifierFlags).isEmpty
    }
}

struct DockEventTapRunState {
    private var nextRunIdentifier: UInt64 = 0
    private(set) var activeRunIdentifier: UInt64?

    mutating func beginRun() -> UInt64 {
        nextRunIdentifier &+= 1
        activeRunIdentifier = nextRunIdentifier
        return nextRunIdentifier
    }

    func isActive(_ runIdentifier: UInt64) -> Bool {
        activeRunIdentifier == runIdentifier
    }

    @discardableResult
    mutating func finishRun(_ runIdentifier: UInt64) -> Bool {
        guard activeRunIdentifier == runIdentifier else {
            return false
        }
        activeRunIdentifier = nil
        return true
    }
}

public final class DockClickEventTap {
    private static let syntheticEventUserData: Int64 = 0x4F_44_43_4C_49_43_4B
    private static let startupTimeout: DispatchTimeInterval = .seconds(2)

    private let settings: SettingsStore
    private let snapshotService: DockInteractionSnapshotService
    private let actionHandler: @MainActor (DockAppTarget) -> Void
    private let eventPoster: (CGEvent) -> Void
    private let controlLock = NSLock()
    private let lifecycleLock = NSLock()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var eventRunLoop: CFRunLoop?
    private var eventThread: Thread?
    private var eventThreadStopped: DispatchSemaphore?
    private var isStopRequested = false
    private var runState = DockEventTapRunState()

    // These values are confined to the event-tap thread.
    private var gestureStateMachine = DockClickGestureStateMachine()
    private var pendingMouseDownEvents: [UInt64: CGEvent] = [:]

    public init(
        settings: SettingsStore,
        dockHitTester: DockHitTester,
        shouldHandleTarget: @escaping (DockAppTarget) -> Bool = { _ in true },
        actionHandler: @escaping @MainActor (DockAppTarget) -> Void
    ) {
        self.settings = settings
        self.snapshotService = DockInteractionSnapshotService(
            dockHitTester: dockHitTester,
            shouldHandleTarget: shouldHandleTarget
        )
        self.actionHandler = actionHandler
        self.eventPoster = { event in
            event.post(tap: .cghidEventTap)
        }
    }

    init(
        settings: SettingsStore,
        snapshotService: DockInteractionSnapshotService,
        eventPoster: @escaping (CGEvent) -> Void = { event in
            event.post(tap: .cghidEventTap)
        },
        actionHandler: @escaping @MainActor (DockAppTarget) -> Void
    ) {
        self.settings = settings
        self.snapshotService = snapshotService
        self.eventPoster = eventPoster
        self.actionHandler = actionHandler
    }

    deinit {
        stop()
    }

    @discardableResult
    public func start() -> Bool {
        controlLock.lock()
        defer { controlLock.unlock() }

        guard stopEventTapAndWait() else {
            return false
        }
        guard settings.toggleAppVisibilityOnDockClick else {
            return false
        }

        snapshotService.start()
        let ready = DispatchSemaphore(value: 0)
        let stopped = DispatchSemaphore(value: 0)
        lifecycleLock.lock()
        let runIdentifier = runState.beginRun()
        lifecycleLock.unlock()
        let thread = Thread { [weak self] in
            guard let self else {
                ready.signal()
                stopped.signal()
                return
            }
            self.runEventTap(
                runIdentifier: runIdentifier,
                ready: ready,
                stopped: stopped
            )
        }
        thread.name = "OmniDock Dock Event Tap"
        thread.qualityOfService = .userInteractive

        lifecycleLock.lock()
        isStopRequested = false
        eventThread = thread
        eventThreadStopped = stopped
        lifecycleLock.unlock()
        thread.start()

        guard ready.wait(timeout: .now() + Self.startupTimeout) == .success else {
            _ = stopEventTapAndWait()
            return false
        }

        lifecycleLock.lock()
        let didStart = runState.isActive(runIdentifier)
            && eventTap != nil
            && eventRunLoop != nil
        lifecycleLock.unlock()
        if !didStart {
            _ = stopEventTapAndWait()
        }
        return didStart
    }

    public func stop() {
        controlLock.lock()
        _ = stopEventTapAndWait()
        controlLock.unlock()
    }

    private func stopEventTapAndWait() -> Bool {
        let runLoop: CFRunLoop?
        let thread: Thread?
        let stopped: DispatchSemaphore?
        let runIdentifier: UInt64?
        lifecycleLock.lock()
        isStopRequested = true
        runLoop = eventRunLoop
        thread = eventThread
        stopped = eventThreadStopped
        runIdentifier = runState.activeRunIdentifier
        lifecycleLock.unlock()

        snapshotService.stop()

        if let runLoop, let runIdentifier {
            let stopBlock = { [weak self] in
                guard let self,
                      self.isActiveRun(runIdentifier)
                else {
                    return
                }
                self.apply(self.gestureStateMachine.cancelPendingGesture())
                if let eventTap = self.eventTap {
                    CGEvent.tapEnable(tap: eventTap, enable: false)
                }
                CFRunLoopStop(runLoop)
            }

            if thread === Thread.current {
                stopBlock()
            } else {
                CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue, stopBlock)
                CFRunLoopWakeUp(runLoop)
            }
        }

        guard thread !== Thread.current else {
            return true
        }
        guard let stopped else {
            return true
        }
        return stopped.wait(timeout: .now() + Self.startupTimeout) == .success
    }

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard !isSyntheticEvent(event) else {
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            apply(gestureStateMachine.cancelPendingGesture())
            enableEventTap()
            return Unmanaged.passUnretained(event)
        case .leftMouseDown:
            return handleMouseDown(event)
        case .leftMouseDragged:
            return handleMouseDragged(event)
        case .leftMouseUp:
            return handleMouseUp(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func runEventTap(
        runIdentifier: UInt64,
        ready: DispatchSemaphore,
        stopped: DispatchSemaphore
    ) {
        let mask = CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseDragged.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseUp.rawValue)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: dockClickEventTapCallback,
            userInfo: userInfo
        ) else {
            ready.signal()
            clearEventThreadState(runIdentifier: runIdentifier)
            stopped.signal()
            return
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            ready.signal()
            clearEventThreadState(runIdentifier: runIdentifier)
            stopped.signal()
            return
        }

        let runLoop = CFRunLoopGetCurrent()
        lifecycleLock.lock()
        let isCurrentRun = runState.isActive(runIdentifier)
        if isCurrentRun {
            eventTap = tap
            runLoopSource = source
            eventRunLoop = runLoop
        }
        let shouldStopBeforeRunning = isStopRequested || !isCurrentRun
        lifecycleLock.unlock()

        guard isCurrentRun else {
            CFMachPortInvalidate(tap)
            ready.signal()
            stopped.signal()
            return
        }

        CFRunLoopAddSource(runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        ready.signal()
        if !shouldStopBeforeRunning {
            CFRunLoopRun()
        }

        apply(gestureStateMachine.cancelPendingGesture())
        CFRunLoopRemoveSource(runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: false)
        CFMachPortInvalidate(tap)
        clearEventThreadState(runIdentifier: runIdentifier)
        stopped.signal()
    }

    private func clearEventThreadState(runIdentifier: UInt64) {
        lifecycleLock.lock()
        guard runState.finishRun(runIdentifier) else {
            lifecycleLock.unlock()
            return
        }
        eventTap = nil
        runLoopSource = nil
        eventRunLoop = nil
        eventThread = nil
        eventThreadStopped = nil
        isStopRequested = false
        lifecycleLock.unlock()
    }

    private func isActiveRun(_ runIdentifier: UInt64) -> Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return runState.isActive(runIdentifier)
    }

    private func handleMouseDown(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let now = DockInteractionClock.now()
        guard DockClickGesturePolicy.isPlainPrimaryClick(flags: event.flags) else {
            let decision = gestureStateMachine.mouseDown(
                target: nil,
                point: event.location,
                timestamp: now
            )
            apply(decision)
            return Unmanaged.passUnretained(event)
        }

        let target = snapshotService.snapshotStore.target(
            atEventTapPoint: event.location,
            now: now
        )
        guard target != nil, let eventCopy = event.copy() else {
            let decision = gestureStateMachine.mouseDown(
                target: nil,
                point: event.location,
                timestamp: now
            )
            apply(decision)
            return unmanagedResult(for: decision.disposition, event: event)
        }

        let decision = gestureStateMachine.mouseDown(
            target: target,
            point: event.location,
            timestamp: now
        )
        if let sequence = decision.scheduleLongPressSequence {
            pendingMouseDownEvents[sequence] = eventCopy
        }
        apply(decision)
        return unmanagedResult(for: decision.disposition, event: event)
    }

    private func handleMouseDragged(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let decision = gestureStateMachine.mouseDragged(to: event.location)
        apply(decision)
        return unmanagedResult(for: decision.disposition, event: event)
    }

    private func handleMouseUp(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let now = DockInteractionClock.now()
        let target = snapshotService.snapshotStore.target(
            atEventTapPoint: event.location,
            now: now
        )
        let decision = gestureStateMachine.mouseUp(target: target, timestamp: now)
        apply(decision)
        return unmanagedResult(for: decision.disposition, event: event)
    }

    private func apply(_ decision: DockClickGestureDecision) {
        if let sequence = decision.replayMouseDownSequence {
            replayMouseDown(sequence: sequence)
        }
        if let sequence = decision.discardMouseDownSequence {
            pendingMouseDownEvents.removeValue(forKey: sequence)
        }
        if let sequence = decision.scheduleLongPressSequence {
            scheduleLongPressReplay(sequence: sequence)
        }
        if let target = decision.actionTarget {
            Task { @MainActor [actionHandler] in
                actionHandler(target)
            }
        }
    }

    private func scheduleLongPressReplay(sequence: UInt64) {
        DispatchQueue.global(qos: .userInteractive).asyncAfter(
            deadline: .now() + DockClickGesturePolicy.longPressDuration
        ) { [weak self] in
            self?.performOnEventThread { [weak self] in
                guard let self else {
                    return
                }
                self.apply(self.gestureStateMachine.longPressElapsed(sequence: sequence))
            }
        }
    }

    private func performOnEventThread(_ block: @escaping () -> Void) {
        lifecycleLock.lock()
        let runLoop = eventRunLoop
        lifecycleLock.unlock()
        guard let runLoop else {
            return
        }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue, block)
        CFRunLoopWakeUp(runLoop)
    }

    private func replayMouseDown(sequence: UInt64) {
        guard let event = pendingMouseDownEvents.removeValue(forKey: sequence) else {
            return
        }
        event.setIntegerValueField(.eventSourceUserData, value: Self.syntheticEventUserData)
        eventPoster(event)
    }

    private func enableEventTap() {
        guard let eventTap else {
            return
        }
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    private func unmanagedResult(
        for disposition: DockClickCurrentEventDisposition,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        switch disposition {
        case .passThrough:
            return Unmanaged.passUnretained(event)
        case .swallow:
            return nil
        }
    }

    private func isSyntheticEvent(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == Self.syntheticEventUserData
    }
}

private let dockClickEventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else {
        return Unmanaged.passUnretained(event)
    }

    let eventTap = Unmanaged<DockClickEventTap>.fromOpaque(userInfo).takeUnretainedValue()
    return eventTap.handle(type: type, event: event)
}
