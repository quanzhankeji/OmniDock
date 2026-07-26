import AppKit
import CoreGraphics

enum WindowPlacementGreenButtonPolicy {
    static let refreshInterval: TimeInterval = 0.45
    static let snapshotLifetime: TimeInterval = 0.9

    static func shouldConsume(
        point: CGPoint,
        flags: CGEventFlags,
        buttonFrame: CGRect?,
        expiresAt: TimeInterval?,
        now: TimeInterval
    ) -> Bool {
        flags.contains(.maskAlternate)
            && (expiresAt ?? -.infinity) >= now
            && buttonFrame?.contains(point) == true
    }

    static func shouldForwardNativeAction(
        modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        !modifiers.contains(.option)
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
    private var consumesGreenClick = false

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

    func beginGreenClick(
        at point: CGPoint,
        flags: CGEventFlags,
        now: TimeInterval
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let greenButton,
              WindowPlacementGreenButtonPolicy.shouldConsume(
                  point: point,
                  flags: flags,
                  buttonFrame: greenButton.frame,
                  expiresAt: greenButton.expiresAt,
                  now: now
              )
        else {
            consumesGreenClick = false
            return false
        }
        consumesGreenClick = true
        return true
    }

    func finishGreenClick() -> GreenButtonSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard consumesGreenClick else {
            return nil
        }
        consumesGreenClick = false
        return greenButton
    }

    func cancelGreenClick() {
        lock.lock()
        consumesGreenClick = false
        lock.unlock()
    }
}

@MainActor
final class WindowPlacementPointerMonitor {
    var onGreenButtonClick: ((WindowPlacementTarget, CGRect) -> Void)?
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
        var isMovingWindow = false
        var hasPresentedDragRegions = false
        var activeCommand: WindowPlacementCommand?
        var activeScreen: WindowPlacementScreen?
        var lastInspectionAt: TimeInterval = 0
    }

    private let pointerState = WindowPlacementPointerState()
    private var configuration = WindowPlacementConfiguration.default
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var dragSession: DragSession?
    private var greenButtonRefreshTimer: Timer?
    private var lastGreenButtonRefreshAt: TimeInterval = 0
    private var greenButtonHoverTracker =
        WindowPlacementGreenButtonHoverTracker()

    func start(configuration: WindowPlacementConfiguration) {
        self.configuration = configuration
        guard eventTap == nil else {
            updateGreenButtonRefresh()
            return
        }

        let mask = [
            CGEventType.mouseMoved,
            .leftMouseDown,
            .leftMouseDragged,
            .leftMouseUp
        ].reduce(CGEventMask(0)) {
            $0 | (CGEventMask(1) << CGEventMask($1.rawValue))
        }
        let opaqueSelf = Unmanaged.passUnretained(self).toOpaque()
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: windowPlacementPointerCallback,
            userInfo: opaqueSelf
        ) else {
            return
        }
        self.eventTap = eventTap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        updateGreenButtonRefresh()
    }

    func stop() {
        stopGreenButtonRefresh()
        dragSession = nil
        lastGreenButtonRefreshAt = 0
        greenButtonHoverTracker.leftButton()
        pointerState.updateGreenButton(nil)
        pointerState.cancelGreenClick()
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
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
            if pointerState.beginGreenClick(
                at: point,
                flags: event.flags,
                now: timestamp
            ) {
                return nil
            }
            Task { @MainActor [weak self] in
                self?.beginDragCandidate(at: point)
            }
        case .leftMouseDragged:
            Task { @MainActor [weak self] in
                self?.updateDrag(at: point, timestamp: timestamp)
            }
        case .leftMouseUp:
            if let snapshot = pointerState.finishGreenClick() {
                Task { @MainActor [weak self] in
                    self?.onGreenButtonClick?(snapshot.target, snapshot.frame)
                }
                return nil
            }
            Task { @MainActor [weak self] in
                self?.finishDrag()
            }
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            Task { @MainActor [weak self] in
                self?.reenableEventTap()
            }
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    private func reenableEventTap() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: true)
        }
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
        guard configuration.showsGreenButtonPalette,
              let result = WindowPlacementAccessibility
                .focusedGreenButtonTarget()
        else {
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

        if !session.isMovingWindow {
            guard WindowPlacementDragPolicy.recognizedWindowMovement(
                initialFrame: session.originalFrame,
                currentFrame: currentFrame
            ) else {
                dragSession = session
                return
            }
            session.isMovingWindow = true
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
        guard session.isMovingWindow,
              let command = session.activeCommand,
              let screen = session.activeScreen
        else {
            onDragCancelled?()
            return
        }
        onDragCompleted?(session.target, command, screen)
    }

}

private let windowPlacementPointerCallback: CGEventTapCallBack = {
    _, type, event, userInfo in
    guard let userInfo else {
        return Unmanaged.passUnretained(event)
    }
    let monitor = Unmanaged<WindowPlacementPointerMonitor>
        .fromOpaque(userInfo)
        .takeUnretainedValue()
    return monitor.process(type: type, event: event)
}
