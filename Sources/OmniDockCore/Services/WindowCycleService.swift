import AppKit
import Carbon.HIToolbox
import CoreGraphics
import ScreenCaptureKit

private let windowCycleEventSignature: OSType = 0x4F444154 // "ODAT"

enum WindowCycleShortcut {
    static let recorded = RecordedShortcut(
        keyCode: kVK_Tab,
        modifierFlags: NSEvent.ModifierFlags.option.rawValue
    )
}

enum WindowCycleDirection: Equatable {
    case forward
    case backward
}

enum WindowCycleRegistrationPolicy {
    static func shouldRegister(
        isStarted: Bool,
        isEnabled: Bool,
        arePreviewsEnabled: Bool,
        permissions: PermissionSnapshot
    ) -> Bool {
        isStarted
            && isEnabled
            && arePreviewsEnabled
            && PermissionFeatureGate.isSatisfied(
                for: .windowCycle,
                in: permissions
            )
    }
}

struct WindowCycleSession {
    private(set) var windows: [PreviewWindowInfo]
    private(set) var selectedIndex: Int

    init(
        windows: [PreviewWindowInfo],
        frontmostProcessIdentifier: pid_t?,
        frontmostWindowIdentity: PreviewWindowIdentity? = nil,
        initialDirection: WindowCycleDirection
    ) {
        self.windows = windows
        selectedIndex = Self.initialIndex(
            in: windows,
            frontmostProcessIdentifier: frontmostProcessIdentifier,
            frontmostWindowIdentity: frontmostWindowIdentity,
            direction: initialDirection
        )
    }

    var selectedWindow: PreviewWindowInfo? {
        guard windows.indices.contains(selectedIndex) else {
            return nil
        }
        return windows[selectedIndex]
    }

    var capturePriorityWindows: [PreviewWindowInfo] {
        guard windows.indices.contains(selectedIndex) else {
            return []
        }
        let offsets = [0, 1, -1]
        var seenIndices = Set<Int>()
        return offsets.compactMap { offset in
            let index = (selectedIndex + offset + windows.count) % windows.count
            guard seenIndices.insert(index).inserted else {
                return nil
            }
            return windows[index]
        }
    }

    // Keep the current choice responsive, then finish the rest of the visible
    // inventory in MRU order while the user continues holding Option.
    var staticCaptureWindows: [PreviewWindowInfo] {
        let priority = capturePriorityWindows
        var identities = Set(priority.map(PreviewWindowIdentity.init))
        return priority + windows.filter { window in
            identities.insert(PreviewWindowIdentity(window)).inserted
        }
    }

    mutating func advance(_ direction: WindowCycleDirection) {
        guard !windows.isEmpty else {
            return
        }
        switch direction {
        case .forward:
            selectedIndex = (selectedIndex + 1) % windows.count
        case .backward:
            selectedIndex = (selectedIndex - 1 + windows.count) % windows.count
        }
    }

    mutating func move(_ direction: WindowCycleNavigation, columnCount: Int) {
        guard windows.indices.contains(selectedIndex) else { return }
        let columns = min(windows.count, max(1, columnCount))
        let row = selectedIndex / columns
        let column = selectedIndex % columns
        switch direction {
        case .left:
            if column > 0 { selectedIndex -= 1 }
        case .right:
            if column < columns - 1, selectedIndex + 1 < windows.count { selectedIndex += 1 }
        case .up:
            if row > 0 { selectedIndex -= columns }
        case .down:
            if (row + 1) * columns < windows.count {
                selectedIndex = min(selectedIndex + columns, windows.count - 1)
            }
        }
    }

    mutating func update(_ window: PreviewWindowInfo, at index: Int) {
        guard windows.indices.contains(index) else {
            return
        }
        windows[index] = window
    }

    mutating func replaceWindows(_ replacement: [PreviewWindowInfo]) {
        let selectedIdentity = selectedWindow.map(PreviewWindowIdentity.init)
        windows = replacement
        guard !windows.isEmpty else {
            selectedIndex = 0
            return
        }

        if let selectedIdentity,
           let replacementIndex = windows.firstIndex(where: {
               PreviewWindowIdentity($0) == selectedIdentity
           }) {
            selectedIndex = replacementIndex
        } else {
            selectedIndex = min(selectedIndex, windows.count - 1)
        }
    }

    @discardableResult
    mutating func remove(_ identity: PreviewWindowIdentity) -> Bool {
        guard let index = windows.firstIndex(where: { PreviewWindowIdentity($0) == identity }) else {
            return false
        }
        windows.remove(at: index)
        guard !windows.isEmpty else {
            selectedIndex = 0
            return true
        }
        if index < selectedIndex {
            selectedIndex -= 1
        } else if selectedIndex >= windows.count {
            selectedIndex = windows.count - 1
        }
        return true
    }

    @discardableResult
    mutating func remove(processIdentifier: pid_t) -> Bool {
        let removedIdentities = windows
            .filter { $0.processIdentifier == processIdentifier }
            .map(PreviewWindowIdentity.init)
        guard !removedIdentities.isEmpty else {
            return false
        }
        removedIdentities.forEach { _ = remove($0) }
        return true
    }

    private static func initialIndex(
        in windows: [PreviewWindowInfo],
        frontmostProcessIdentifier: pid_t?,
        frontmostWindowIdentity: PreviewWindowIdentity?,
        direction: WindowCycleDirection
    ) -> Int {
        guard windows.count > 1 else {
            return 0
        }

        let frontmostIndex = frontmostWindowIdentity.flatMap { identity in
            windows.firstIndex { PreviewWindowIdentity($0) == identity }
        } ?? windows.firstIndex { window in
            window.processIdentifier == frontmostProcessIdentifier
        }

        guard let frontmostIndex else {
            return direction == .forward ? 0 : windows.count - 1
        }

        switch direction {
        case .forward:
            return (frontmostIndex + 1) % windows.count
        case .backward:
            return (frontmostIndex - 1 + windows.count) % windows.count
        }
    }
}

@MainActor
final class WindowCycleRegistrationStatusStore {
    static let changedNotification = Notification.Name("OmniDockWindowCycleRegistrationChanged")

    private(set) var warning: String?

    func setWarning(_ warning: String?) {
        guard self.warning != warning else {
            return
        }
        self.warning = warning
        NotificationCenter.default.post(name: Self.changedNotification, object: self)
    }
}

@MainActor
protocol WindowCycleHotkeyRegistering: AnyObject {
    var onTrigger: ((WindowCycleDirection) -> Void)? { get set }
    var isRegistered: Bool { get }
    func register() -> OSStatus?
    func unregister()
}

@MainActor
private final class OptionTabActivationRegistry: WindowCycleHotkeyRegistering {
    var onTrigger: ((WindowCycleDirection) -> Void)?

    private struct RegisteredHotkey {
        let reference: EventHotKeyRef
        let direction: WindowCycleDirection
    }

    private var handlerReference: EventHandlerRef?
    private var registeredHotkeys: [UInt32: RegisteredHotkey] = [:]

    var isRegistered: Bool {
        registeredHotkeys.count == 2
    }

    func register() -> OSStatus? {
        guard !isRegistered else {
            return nil
        }
        unregister()
        guard let status = installHandlerIfNeeded() else {
            return registerHotkeys()
        }
        return status
    }

    func unregister() {
        registeredHotkeys.values.forEach { UnregisterEventHotKey($0.reference) }
        registeredHotkeys.removeAll()
        if let handlerReference {
            RemoveEventHandler(handlerReference)
            self.handlerReference = nil
        }
    }

    fileprivate func handle(_ hotkeyID: EventHotKeyID) -> Bool {
        guard hotkeyID.signature == windowCycleEventSignature,
              let registeredHotkey = registeredHotkeys[hotkeyID.id]
        else {
            return false
        }
        onTrigger?(registeredHotkey.direction)
        return true
    }

    private func installHandlerIfNeeded() -> OSStatus? {
        guard handlerReference == nil else {
            return nil
        }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var handler: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            optionTabActivationEventHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler
        )
        guard status == noErr else {
            return status
        }
        handlerReference = handler
        return nil
    }

    private func registerHotkeys() -> OSStatus? {
        let registrations: [(UInt32, WindowCycleDirection, UInt32)] = [
            (1, .forward, UInt32(optionKey)),
            (2, .backward, UInt32(optionKey | shiftKey))
        ]
        for (identifier, direction, modifiers) in registrations {
            let hotkeyID = EventHotKeyID(signature: windowCycleEventSignature, id: identifier)
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(
                UInt32(WindowCycleShortcut.recorded.keyCode),
                modifiers,
                hotkeyID,
                GetApplicationEventTarget(),
                OptionBits(kEventHotKeyExclusive),
                &reference
            )
            guard status == noErr, let reference else {
                unregister()
                return status
            }
            registeredHotkeys[identifier] = RegisteredHotkey(
                reference: reference,
                direction: direction
            )
        }
        return nil
    }
}

private let optionTabActivationEventHandler: EventHandlerUPP = { _, event, userData in
    guard let event, let userData else {
        return noErr
    }
    var hotkeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotkeyID
    )
    guard status == noErr else {
        return status
    }
    let registry = Unmanaged<OptionTabActivationRegistry>.fromOpaque(userData).takeUnretainedValue()
    Task { @MainActor in
        registry.handle(hotkeyID)
    }
    // Let the configured per-application shortcut registry receive its own
    // events when both registries are attached to the application target.
    return CarbonHotkeyEventRouting.result(
        handled: hotkeyID.signature == windowCycleEventSignature
    )
}

private final class WindowCycleInputMonitor: WindowCycleInputMonitoring {
    var onEvent: ((WindowCycleInputAction) -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var inputState = WindowCycleInputState()

    var isMonitoring: Bool {
        eventTap != nil
    }

    func start() -> Bool {
        guard eventTap == nil else {
            return true
        }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: windowCycleEventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ), let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0) else {
            return false
        }

        self.eventTap = eventTap
        self.runLoopSource = runLoopSource
        inputState.begin()
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        return true
    }

    func stop() {
        inputState.end()
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
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard let action = inputState.action(
            type: type, keyCode: event.getIntegerValueField(.keyboardEventKeycode), flags: event.flags
        ) else {
            return Unmanaged.passUnretained(event)
        }
        let generation = inputState.generation
        DispatchQueue.main.async { [weak self] in
            // A queued key must not act on a later switcher session.
            guard let self, self.inputState.accepts(generation: generation) else { return }
            self.onEvent?(action)
        }
        return type == .keyDown ? nil : Unmanaged.passUnretained(event)
    }
}

private let windowCycleEventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else {
        return Unmanaged.passUnretained(event)
    }
    let monitor = Unmanaged<WindowCycleInputMonitor>
        .fromOpaque(userInfo)
        .takeUnretainedValue()
    return monitor.handle(type: type, event: event)
}

@MainActor
final class WindowCycleService {
    private static let initialReconciliationDelay: TimeInterval = 0.12

    private let settings: SettingsStore
    private let permissionSnapshotProvider: () -> PermissionSnapshot
    private var lastScreenRecordingPermission: Bool?
    private let windowInventory: WindowInventoryService
    private let previewService: ScreenCapturePreviewService
    private let previewPanelController: PreviewPanelController
    private let registrationStatus: WindowCycleRegistrationStatusStore
    private let hotkeyRegistry: WindowCycleHotkeyRegistering
    private let onSessionActivityChanged: (Bool) -> Void
    private let inputMonitor: WindowCycleInputMonitoring
    private let workspaceNotificationCenter: NotificationCenter
    private let applicationNotificationCenter: NotificationCenter
    private lazy var workspaceMonitor = PreviewWorkspaceMonitor(
        notificationCenter: workspaceNotificationCenter,
        applicationNotificationCenter: applicationNotificationCenter,
        onDisplayConfigurationChanged: { [weak self] in self?.displayConfigurationChanged() }
    ) { [weak self] suspended in
        self?.workspaceSuspensionChanged(suspended)
    }

    private var session: WindowCycleSession?
    private var sessionTarget: DockAppTarget?
    private var sessionGeneration: UInt64 = 0
    private var inventoryRefreshGeneration: UInt64 = 0
    // Sessions are the registry's to start, reuse and stop, the same way the
    // Dock previews and the Command-Tab switcher run theirs. What stays here is
    // the material it reconciles against: the window each identity captures
    // from, and the ones ScreenCaptureKit never offered.
    private let captureSessionRegistry = PreviewCaptureSessionRegistry()
    private var captureWindows: [PreviewWindowIdentity: SCWindow] = [:]
    // Cached stills seed currentImages, so that cannot tell a card that has
    // been captured from one that is merely showing something.
    private var capturedIdentities = Set<PreviewWindowIdentity>()
    private var unavailableStaticIdentities = Set<PreviewWindowIdentity>()
    private var currentImages: [PreviewWindowIdentity: NSImage] = [:]
    private var inventoryChangeObserverIdentifier: UUID?
    private var inventoryPrewarmWorkItem: DispatchWorkItem?
    private var hasPrewarmedInventory = false
    private var isAwaitingInventory = false
    private var isStarted = false

    init(
        settings: SettingsStore,
        permissionService: PermissionService,
        windowInventory: WindowInventoryService,
        previewService: ScreenCapturePreviewService,
        previewPanelController: PreviewPanelController,
        registrationStatus: WindowCycleRegistrationStatusStore,
        hotkeyRegistry: WindowCycleHotkeyRegistering? = nil,
        inputMonitor: WindowCycleInputMonitoring? = nil,
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        applicationNotificationCenter: NotificationCenter = .default,
        permissionSnapshotProvider: (() -> PermissionSnapshot)? = nil,
        onSessionActivityChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        self.settings = settings
        self.permissionSnapshotProvider = permissionSnapshotProvider ?? {
            permissionService.snapshot()
        }
        self.windowInventory = windowInventory
        self.previewService = previewService
        self.previewPanelController = previewPanelController
        self.registrationStatus = registrationStatus
        self.hotkeyRegistry = hotkeyRegistry ?? OptionTabActivationRegistry()
        self.inputMonitor = inputMonitor ?? WindowCycleInputMonitor()
        self.workspaceNotificationCenter = workspaceNotificationCenter
        self.applicationNotificationCenter = applicationNotificationCenter
        self.onSessionActivityChanged = onSessionActivityChanged

        self.hotkeyRegistry.onTrigger = { [weak self] direction in
            self?.handleHotkey(direction)
        }
        self.inputMonitor.onEvent = { [weak self] event in
            self?.handleInput(event)
        }
        previewPanelController.setPresentationHandler(
            for: .windowCycle,
            onLifecycleEndRequested: { [weak self] in
                self?.endSession()
            },
            onWindowClosed: { [weak self] window in
                self?.removeWindow(window)
            },
            onApplicationQuitRequested: { [weak self] processIdentifier in
                self?.removeApplication(processIdentifier)
            }
        )
    }

    func start() {
        guard !isStarted else {
            return
        }
        isStarted = true
        workspaceMonitor.start()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsChanged),
            name: SettingsStore.changedNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(permissionsChanged),
            name: PermissionService.changedNotification, object: nil
        )
        refreshRegistration()
    }

    func stop() {
        guard isStarted else {
            return
        }
        isStarted = false
        workspaceMonitor.stop()
        NotificationCenter.default.removeObserver(self)
        inventoryPrewarmWorkItem?.cancel()
        inventoryPrewarmWorkItem = nil
        hasPrewarmedInventory = false
        endSession()
        hotkeyRegistry.unregister()
        registrationStatus.setWarning(nil)
    }

    func refreshRegistration() {
        reconcileRegistration()
        let recording = permissionSnapshotProvider().screenRecording
        defer { lastScreenRecordingPermission = recording }
        guard recording != lastScreenRecordingPermission,
              var session, let target = sessionTarget else { return }
        sessionGeneration &+= 1
        captureSessionRegistry.stopAll()
        captureWindows.removeAll()
        currentImages.removeAll()
        capturedIdentities.removeAll()
        unavailableStaticIdentities.removeAll()
        for (index, window) in session.windows.enumerated() {
            session.update(copy(window, image: nil), at: index)
        }
        self.session = session
        updatePresentation(for: session)
        requestStaticPreviews(for: session, target: target, generation: sessionGeneration)
    }

    @objc private func permissionsChanged() {
        refreshRegistration()
    }

    var isHotkeyRegistered: Bool {
        hotkeyRegistry.isRegistered
    }

    var isSessionActive: Bool {
        session != nil
    }

    var isInputMonitoring: Bool {
        inputMonitor.isMonitoring
    }

    @objc private func settingsChanged(_ notification: Notification) {
        guard SettingsStore.change(in: notification).affectsWindowCycle else {
            return
        }
        reconcileRegistration()
    }

    private var canRun: Bool {
        !workspaceMonitor.isSuspended && WindowCycleRegistrationPolicy.shouldRegister(
            isStarted: isStarted,
            isEnabled: settings.windowCycleEnabled,
            arePreviewsEnabled: settings.showDockPreviews,
            permissions: permissionSnapshotProvider()
        )
    }

    private func workspaceSuspensionChanged(_ suspended: Bool) {
        if suspended {
            previewPanelController.cancelPendingWindowFocus()
            inventoryPrewarmWorkItem?.cancel()
            inventoryPrewarmWorkItem = nil
            hasPrewarmedInventory = false
        }
        refreshRegistration()
    }

    private func displayConfigurationChanged() {
        previewPanelController.cancelPendingWindowFocus()
        endSession()
        inventoryPrewarmWorkItem?.cancel()
        inventoryPrewarmWorkItem = nil
        hasPrewarmedInventory = false
    }

    private func reconcileRegistration() {
        guard canRun else {
            endSession()
            hotkeyRegistry.unregister()
            registrationStatus.setWarning(nil)
            return
        }

        if let status = hotkeyRegistry.register() {
            endSession()
            hotkeyRegistry.unregister()
            registrationStatus.setWarning(registrationMessage(for: status))
        } else {
            registrationStatus.setWarning(nil)
            scheduleInventoryPrewarmIfNeeded()
        }
    }

    private func registrationMessage(for status: OSStatus) -> String {
        if status == eventHotKeyExistsErr {
            return AppStrings.text(.settingsWindowCycleUnavailable)
        }
        return AppStrings.text(.settingsWindowCycleUnavailable)
    }

    private func handleHotkey(_ direction: WindowCycleDirection) {
        guard canRun, hotkeyRegistry.isRegistered else {
            return
        }
        guard session != nil else {
            beginSession(direction: direction)
            return
        }
        advanceSession(direction)
    }

    private func beginSession(direction: WindowCycleDirection) {
        guard !isAwaitingInventory else {
            return
        }
        previewPanelController.cancelPendingWindowFocus()
        inventoryRefreshGeneration &+= 1
        let refreshGeneration = inventoryRefreshGeneration
        let records = windowInventory.allWindows()

        if startSession(with: records, direction: direction) {
            scheduleInventoryReconciliation(
                direction: direction,
                refreshGeneration: refreshGeneration,
                startsSessionWhenReady: false,
                delay: Self.initialReconciliationDelay
            )
            return
        }

        guard inputMonitor.start() else {
            registrationStatus.setWarning(AppStrings.text(.settingsWindowCycleUnavailable))
            return
        }
        isAwaitingInventory = true
        scheduleInventoryReconciliation(
            direction: direction,
            refreshGeneration: refreshGeneration,
            startsSessionWhenReady: true
        )
    }

    @discardableResult
    private func startSession(
        with records: [WindowInventoryRecord],
        direction: WindowCycleDirection
    ) -> Bool {
        guard canRun else { return false }
        let windows = records.map { $0.makePreviewWindowInfo() }
        let frontmostProcessIdentifier = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let frontmostWindowIdentity = records.first(where: {
            $0.processIdentifier == frontmostProcessIdentifier
        })?.identity
        let newSession = WindowCycleSession(
            windows: windows,
            frontmostProcessIdentifier: frontmostProcessIdentifier,
            frontmostWindowIdentity: frontmostWindowIdentity,
            initialDirection: direction
        )
        guard newSession.selectedWindow != nil else {
            return false
        }
        guard inputMonitor.start() else {
            registrationStatus.setWarning(AppStrings.text(.settingsWindowCycleUnavailable))
            return false
        }

        sessionGeneration &+= 1
        session = newSession
        currentImages = cachedImages(for: newSession.windows)
        unavailableStaticIdentities.removeAll()
        let decoratedWindows = newSession.windows.map { decoratedWindow(from: $0) }
        let target = makeSessionTarget(generation: sessionGeneration)
        sessionTarget = target
        observeInventoryChanges()
        onSessionActivityChanged(true)
        previewPanelController.show(target: target, windows: decoratedWindows, message: nil)
        previewPanelController.setSelectedWindow(newSession.selectedWindow)
        requestStaticPreviews(for: newSession, target: target, generation: sessionGeneration)
        return true
    }

    private func refreshInventoryForNextSession() {
        hasPrewarmedInventory = false
        scheduleInventoryPrewarmIfNeeded()
    }

    private func scheduleInventoryPrewarmIfNeeded() {
        guard canRun, !hasPrewarmedInventory else {
            return
        }
        hasPrewarmedInventory = true

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }
            self.inventoryPrewarmWorkItem = nil
            guard self.canRun, self.hotkeyRegistry.isRegistered else {
                self.hasPrewarmedInventory = false
                return
            }
            _ = self.windowInventory.reconcileSwitcherWindows()
        }
        inventoryPrewarmWorkItem = workItem
        // Seed metadata on the next run-loop turn, before the user can normally
        // invoke Option-Tab. Image capture stays on demand.
        DispatchQueue.main.async(execute: workItem)
    }

    private func scheduleInventoryReconciliation(
        direction: WindowCycleDirection,
        refreshGeneration: UInt64,
        startsSessionWhenReady: Bool,
        delay: TimeInterval = 0
    ) {
        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.runInventoryReconciliation(
                    direction: direction,
                    refreshGeneration: refreshGeneration,
                    startsSessionWhenReady: startsSessionWhenReady
                )
            }
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.runInventoryReconciliation(
                    direction: direction,
                    refreshGeneration: refreshGeneration,
                    startsSessionWhenReady: startsSessionWhenReady
                )
            }
        }
    }

    private func runInventoryReconciliation(
        direction: WindowCycleDirection,
        refreshGeneration: UInt64,
        startsSessionWhenReady: Bool
    ) {
        guard refreshGeneration == inventoryRefreshGeneration,
              hotkeyRegistry.isRegistered
        else {
            return
        }

        let records = windowInventory.reconcileSwitcherWindows()
        guard refreshGeneration == inventoryRefreshGeneration else {
            return
        }

        if startsSessionWhenReady {
            guard session == nil else {
                return
            }
            isAwaitingInventory = false
            guard startSession(with: records, direction: direction) else {
                endSession()
                return
            }
            return
        }

        applyReconciledWindows(records)
    }

    private func applyReconciledWindows(_ records: [WindowInventoryRecord]) {
        guard var session,
              let target = sessionTarget
        else {
            return
        }

        let replacement = records.map { $0.makePreviewWindowInfo() }
        // A single empty AX/WindowServer reconciliation can be transient. Keep
        // the current cards until a concrete window-removal event arrives.
        guard !replacement.isEmpty else {
            return
        }

        let replacementIdentities = Set(replacement.map(PreviewWindowIdentity.init))
        let removedIdentities = Set(session.windows.map(PreviewWindowIdentity.init))
            .subtracting(replacementIdentities)
        for identity in removedIdentities {
            forgetCapture(identity)
        }

        session.replaceWindows(replacement)
        self.session = session

        let cached = cachedImages(for: session.windows)
        for (identity, image) in cached where currentImages[identity] == nil {
            currentImages[identity] = image
        }

        updatePresentation(for: session)
        requestStaticPreviews(for: session, target: target, generation: sessionGeneration)
    }

    private func advanceSession(_ direction: WindowCycleDirection) {
        guard var session else {
            return
        }
        session.advance(direction)
        self.session = session
        previewPanelController.setSelectedWindow(session.selectedWindow)
        guard let target = sessionTarget else {
            return
        }
        requestStaticPreviews(for: session, target: target, generation: sessionGeneration)
    }

    private func moveSession(_ direction: WindowCycleNavigation) {
        guard var session, let target = sessionTarget else { return }
        let previousIndex = session.selectedIndex
        session.move(direction, columnCount: previewPanelController.windowCycleColumnCount)
        guard session.selectedIndex != previousIndex else { return }
        self.session = session
        previewPanelController.setSelectedWindow(session.selectedWindow)
        requestStaticPreviews(for: session, target: target, generation: sessionGeneration)
    }

    private func handleInput(_ event: WindowCycleInputAction) {
        guard canRun else {
            endSession()
            return
        }
        switch event {
        case let .advance(direction):
            advanceSession(direction)
        case let .move(direction):
            moveSession(direction)
        case .confirm:
            endSession(focusing: session?.selectedWindow)
        case .cancel:
            endSession()
        }
    }

    private func requestStaticPreviews(
        for session: WindowCycleSession,
        target: DockAppTarget,
        generation: UInt64
    ) {
        guard canRun, permissionSnapshotProvider().screenRecording else { return }
        // A window needs a snapshot when nothing has been captured from it yet.
        // Holding a picture is not the same thing: the session starts with
        // cached stills so the cards are not blank, and treating those as
        // finished left every one of them frozen at the cached frame.
        //
        // With live previews off a cached still is all a card will ever show,
        // so there is nothing to gain from capturing again.
        let reusesCachedImages = !settings.liveDockPreviewsEnabled
        let pending = session.staticCaptureWindows.filter { window in
            let identity = PreviewWindowIdentity(window)
            return !(reusesCachedImages && currentImages[identity] != nil)
                && captureWindows[identity] == nil
                && !unavailableStaticIdentities.contains(identity)
        }
        let captureIdentitiesByProcess = Dictionary(grouping: pending, by: \.processIdentifier)
            .mapValues { windows in
                Set(windows.map(PreviewWindowIdentity.init))
            }
        var seenProcessIdentifiers = Set<pid_t>()
        let processIdentifiers = pending.compactMap { window -> pid_t? in
            seenProcessIdentifiers.insert(window.processIdentifier).inserted
                ? window.processIdentifier
                : nil
        }

        for processIdentifier in processIdentifiers {
            let appName = session.windows.first(where: { $0.processIdentifier == processIdentifier })?.appName
                ?? AppStrings.text(.genericApplication)
            let applicationTarget = DockAppTarget(
                processIdentifier: processIdentifier,
                bundleIdentifier: NSRunningApplication(processIdentifier: processIdentifier)?.bundleIdentifier,
                localizedName: appName,
                dockElementTitle: appName,
                hitPoint: target.hitPoint,
                dockTileIdentifierOverride: target.dockTileIdentifier,
                previewAnchorKind: .windowCycle
            )
            previewService.loadWindows(for: applicationTarget) { [weak self] snapshot in
                self?.adoptCaptureWindows(
                    from: snapshot,
                    requested: captureIdentitiesByProcess[processIdentifier, default: []],
                    target: target,
                    generation: generation
                )
            }
        }
    }

    private func adoptCaptureWindows(
        from snapshot: PreviewWindowSnapshot,
        requested: Set<PreviewWindowIdentity>,
        target: DockAppTarget,
        generation: UInt64
    ) {
        guard canRun, permissionSnapshotProvider().screenRecording,
              generation == sessionGeneration,
              session != nil,
              sessionTarget?.isSameDockTile(as: target) == true
        else {
            return
        }
        unavailableStaticIdentities.formUnion(
            StaticPreviewCaptureAvailabilityPolicy.unavailableIdentities(
                requested: requested,
                available: Set(snapshot.captureWindows.keys)
            )
        )
        for (identity, window) in snapshot.captureWindows {
            captureWindows[identity] = window
        }
        reconcileCaptureSessions(target: target, generation: generation)
    }

    private func reconcileCaptureSessions(target: DockAppTarget, generation: UInt64) {
        guard canRun, permissionSnapshotProvider().screenRecording, let session else {
            captureSessionRegistry.stopAll()
            return
        }
        // The queue order carries the selection and its neighbours first, so
        // handing it over whole lets the registry spend its slots on the cards
        // about to be looked at.
        let ordered = session.staticCaptureWindows.map(PreviewWindowIdentity.init)
        let available = Set(captureWindows.keys).subtracting(unavailableStaticIdentities)
        // Same switch the Dock and Command-Tab previews follow.
        let policy = PreviewCapturePolicy.adaptive(
            livePreviewsEnabled: settings.liveDockPreviewsEnabled,
            windowCount: session.windows.count,
            powerState: .current,
            requestedLiveStreamCount: settings.livePreviewWindowLimit
        )

        captureSessionRegistry.reconcile(
            orderedIdentities: ordered,
            availableIdentities: available,
            sourceSizes: captureWindows.mapValues { $0.frame.size },
            policy: policy
        ) { [weak self] identity, mode, sessionPolicy in
            guard let self,
                  let window = self.captureWindows[identity]
            else {
                return nil
            }
            return self.previewService.startPreviewCaptureSession(
                identity: identity,
                window: window,
                mode: mode,
                policy: sessionPolicy,
                imageHandler: { [weak self] _, image in
                    self?.acceptCapturedImage(
                        image,
                        for: identity,
                        target: target,
                        generation: generation
                    )
                },
                errorHandler: { [weak self] _ in
                    self?.handleCaptureFailure(
                        for: identity,
                        target: target,
                        generation: generation
                    )
                }
            )
        }
    }

    private func handleCaptureFailure(
        for identity: PreviewWindowIdentity,
        target: DockAppTarget,
        generation: UInt64
    ) {
        guard generation == sessionGeneration,
              sessionTarget?.isSameDockTile(as: target) == true
        else {
            return
        }
        captureSessionRegistry.remove(identity)
        // Marked unavailable rather than retried: the queue holds every other
        // window, and one that cannot be captured must not hold up the rest.
        unavailableStaticIdentities.insert(identity)
        reconcileCaptureSessions(target: target, generation: generation)
    }

    private func acceptCapturedImage(
        _ image: NSImage,
        for identity: PreviewWindowIdentity,
        target: DockAppTarget,
        generation: UInt64
    ) {
        // The session is not stopped here. A still capture finishes on its own
        // and the registry clears it; stopping a live one would end it at its
        // first frame, which is the very thing this shows.
        guard canRun, permissionSnapshotProvider().screenRecording,
              generation == sessionGeneration,
              sessionTarget?.isSameDockTile(as: target) == true,
              var session,
              let index = session.windows.firstIndex(where: { PreviewWindowIdentity($0) == identity })
        else {
            return
        }

        let isFirstImage = capturedIdentities.insert(identity).inserted
        currentImages[identity] = image
        session.update(copy(session.windows[index], image: image), at: index)
        self.session = session
        previewPanelController.updatePreview(windowID: identity.windowID ?? 0, image: image)
        cacheImages(for: identity.processIdentifier)

        // Only once a window first has something to show. A live capture
        // arrives many times a second, and chasing the queue on every frame
        // would spend the whole session reconciling.
        guard isFirstImage else {
            return
        }
        requestStaticPreviews(for: session, target: target, generation: generation)
        reconcileCaptureSessions(target: target, generation: generation)
    }

    private func forgetCapture(_ identity: PreviewWindowIdentity) {
        captureSessionRegistry.remove(identity)
        captureWindows[identity] = nil
        capturedIdentities.remove(identity)
        currentImages[identity] = nil
        unavailableStaticIdentities.remove(identity)
    }

    private func removeWindow(_ window: PreviewWindowInfo) {
        removeWindow(PreviewWindowIdentity(window))
    }

    private func removeWindow(_ identity: PreviewWindowIdentity) {
        forgetCapture(identity)
        guard var session else {
            return
        }
        guard session.remove(identity) else {
            return
        }
        self.session = session
        guard !session.windows.isEmpty else {
            endSession()
            return
        }
        updatePresentation(for: session)
    }

    private func removeApplication(_ processIdentifier: pid_t) {
        let captureIdentities = Set(captureWindows.keys.filter {
            $0.processIdentifier == processIdentifier
        }).union(currentImages.keys.filter {
            $0.processIdentifier == processIdentifier
        }).union(unavailableStaticIdentities.filter {
            $0.processIdentifier == processIdentifier
        })
        for identity in captureIdentities {
            forgetCapture(identity)
        }
        guard var session else {
            return
        }
        _ = session.remove(processIdentifier: processIdentifier)
        self.session = session
        if session.windows.isEmpty {
            endSession()
        } else {
            updatePresentation(for: session)
        }
    }

    private func endSession(focusing window: PreviewWindowInfo? = nil) {
        let feedbackTarget = sessionTarget
        let wasActive = session != nil || sessionTarget != nil || inputMonitor.isMonitoring
        inventoryRefreshGeneration &+= 1
        sessionGeneration &+= 1
        isAwaitingInventory = false
        stopObservingInventoryChanges()
        inputMonitor.stop()
        captureSessionRegistry.stopAll()
        captureWindows.removeAll()
        capturedIdentities.removeAll()
        unavailableStaticIdentities.removeAll()
        currentImages.removeAll()
        session = nil
        sessionTarget = nil
        if wasActive {
            previewPanelController.hide()
            onSessionActivityChanged(false)
            // Warmed once at registration, the inventory is as old as the last
            // launch by the time anyone reaches for the switcher, so it opens
            // on windows that have since closed, moved or resized. Warm it
            // again now the panel is down and nothing is waiting on it.
            refreshInventoryForNextSession()
        }
        guard canRun, let window else {
            return
        }
        previewPanelController.focusWindowAfterPreviewDismissal(window, feedbackTarget: feedbackTarget)
    }

    private func observeInventoryChanges() {
        stopObservingInventoryChanges()
        inventoryChangeObserverIdentifier = windowInventory.observeChanges { [weak self] event in
            self?.handleInventoryChange(event)
        }
    }

    private func stopObservingInventoryChanges() {
        guard let inventoryChangeObserverIdentifier else {
            return
        }
        windowInventory.removeChangeObserver(inventoryChangeObserverIdentifier)
        self.inventoryChangeObserverIdentifier = nil
    }

    private func handleInventoryChange(_ event: WindowInventoryEvent) {
        switch event {
        case let .windowRemoved(identity):
            removeWindow(identity)
        case let .processLaunched(processIdentifier), let .processTerminated(processIdentifier):
            removeApplication(processIdentifier)
        case .seed, .processInvalidated, .processActivated, .windowFocused, .activeSpaceChanged, .displayConfigurationChanged:
            break
        }
    }

    private func updatePresentation(for session: WindowCycleSession) {
        guard let target = sessionTarget else {
            return
        }
        let windows = session.windows.map { decoratedWindow(from: $0) }
        previewPanelController.update(target: target, windows: windows, message: nil)
        previewPanelController.setSelectedWindow(session.selectedWindow)
    }

    private func cachedImages(for windows: [PreviewWindowInfo]) -> [PreviewWindowIdentity: NSImage] {
        Dictionary(uniqueKeysWithValues: windows.compactMap { window in
            let identity = PreviewWindowIdentity(window)
            let cachedWindow = previewService.cachedSnapshotWindows(for: window.processIdentifier)
                .first(where: { PreviewWindowIdentity($0) == identity })
            guard let image = cachedWindow?.staticPreviewImage else {
                return nil
            }
            return (identity, image)
        })
    }

    private func decoratedWindow(from window: PreviewWindowInfo) -> PreviewWindowInfo {
        let identity = PreviewWindowIdentity(window)
        let hasRecording = permissionSnapshotProvider().screenRecording
        return copy(
            window,
            image: hasRecording ? currentImages[identity] ?? window.staticPreviewImage : nil,
            placeholderText: window.isMinimized
                ? AppStrings.text(.previewMinimizedClickRestore)
                : AppStrings.text(hasRecording ? .previewWindowContentUnavailable : .previewMetadataOnly)
        )
    }

    private func cacheImages(for processIdentifier: pid_t) {
        guard let session else {
            return
        }
        let windows = session.windows.filter { window in
            window.processIdentifier == processIdentifier
                && currentImages[PreviewWindowIdentity(window)] != nil
        }.map { window in
            copy(window, image: currentImages[PreviewWindowIdentity(window)], placeholderText: nil)
        }
        guard !windows.isEmpty else {
            return
        }
        previewService.storeCachedSnapshotWindows(windows, for: processIdentifier)
    }

    private func makeSessionTarget(generation: UInt64) -> DockAppTarget {
        let screenFrame = NSScreen.main?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
        return DockAppTarget(
            processIdentifier: getpid(),
            bundleIdentifier: Bundle.main.bundleIdentifier,
            localizedName: "OmniDock",
            dockElementTitle: "OmniDock",
            hitPoint: CGPoint(x: screenFrame.midX, y: screenFrame.midY),
            dockTileIdentifierOverride: "window-cycle:\(generation)",
            previewAnchorKind: .windowCycle
        )
    }

    private func copy(
        _ window: PreviewWindowInfo,
        image: NSImage?,
        placeholderText: String? = nil
    ) -> PreviewWindowInfo {
        PreviewWindowInfo(
            id: window.id,
            windowID: window.windowID,
            processIdentifier: window.processIdentifier,
            appName: window.appName,
            title: window.title,
            frame: window.frame,
            isMinimized: window.isMinimized,
            isApplicationHidden: window.isApplicationHidden,
            isFullScreen: window.isFullScreen,
            staticPreviewImage: image,
            placeholderText: placeholderText
        )
    }
}

enum StaticPreviewCaptureAvailabilityPolicy {
    static func unavailableIdentities(
        requested: Set<PreviewWindowIdentity>,
        available: Set<PreviewWindowIdentity>
    ) -> Set<PreviewWindowIdentity> {
        requested.subtracting(available)
    }
}

private func fourCharacterCode(_ string: String) -> OSType {
    string.utf8.reduce(0) { result, character in
        (result << 8) + OSType(character)
    }
}
