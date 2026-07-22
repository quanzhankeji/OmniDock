import AppKit
import Carbon.HIToolbox
import CoreGraphics

private let windowCycleEventSignature: OSType = 0x4F444154 // "ODAT"

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
                UInt32(kVK_Tab),
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

private final class WindowCycleInputMonitor {
    enum Event {
        case advance(WindowCycleDirection)
        case confirm
        case cancel
    }

    var onEvent: ((Event) -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

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
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        return true
    }

    func stop() {
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
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        case .flagsChanged:
            if !event.flags.contains(.maskAlternate) {
                DispatchQueue.main.async { [weak self] in
                    self?.onEvent?(.confirm)
                }
            }
            return Unmanaged.passUnretained(event)
        case .keyDown:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if keyCode == Int64(kVK_Escape) {
                DispatchQueue.main.async { [weak self] in
                    self?.onEvent?(.cancel)
                }
                return nil
            }
            if keyCode == Int64(kVK_Tab), event.flags.contains(.maskAlternate) {
                let direction: WindowCycleDirection = event.flags.contains(.maskShift)
                    ? .backward
                    : .forward
                DispatchQueue.main.async { [weak self] in
                    self?.onEvent?(.advance(direction))
                }
                return nil
            }
            return Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
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
    private static let maximumStaticCaptureCount = 3
    private static let initialReconciliationDelay: TimeInterval = 0.12

    private let settings: SettingsStore
    private let permissionSnapshotProvider: () -> PermissionSnapshot
    private let windowInventory: WindowInventoryService
    private let windowControlService: WindowControlService
    private let previewService: ScreenCapturePreviewService
    private let previewPanelController: PreviewPanelController
    private let registrationStatus: WindowCycleRegistrationStatusStore
    private let hotkeyRegistry: WindowCycleHotkeyRegistering
    private let onSessionActivityChanged: (Bool) -> Void
    private let inputMonitor = WindowCycleInputMonitor()

    private var session: WindowCycleSession?
    private var sessionTarget: DockAppTarget?
    private var sessionGeneration: UInt64 = 0
    private var inventoryRefreshGeneration: UInt64 = 0
    private var activeStaticCaptures: [PreviewWindowIdentity: any PreviewCaptureSession] = [:]
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
        windowControlService: WindowControlService,
        previewService: ScreenCapturePreviewService,
        previewPanelController: PreviewPanelController,
        registrationStatus: WindowCycleRegistrationStatusStore,
        hotkeyRegistry: WindowCycleHotkeyRegistering? = nil,
        permissionSnapshotProvider: (() -> PermissionSnapshot)? = nil,
        onSessionActivityChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        self.settings = settings
        self.permissionSnapshotProvider = permissionSnapshotProvider ?? {
            permissionService.snapshot()
        }
        self.windowInventory = windowInventory
        self.windowControlService = windowControlService
        self.previewService = previewService
        self.previewPanelController = previewPanelController
        self.registrationStatus = registrationStatus
        self.hotkeyRegistry = hotkeyRegistry ?? OptionTabActivationRegistry()
        self.onSessionActivityChanged = onSessionActivityChanged

        self.hotkeyRegistry.onTrigger = { [weak self] direction in
            self?.handleHotkey(direction)
        }
        inputMonitor.onEvent = { [weak self] event in
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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsChanged),
            name: SettingsStore.changedNotification,
            object: nil
        )
        reconcileRegistration()
    }

    func stop() {
        guard isStarted else {
            return
        }
        isStarted = false
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

    @objc private func settingsChanged() {
        reconcileRegistration()
    }

    private func reconcileRegistration() {
        guard WindowCycleRegistrationPolicy.shouldRegister(
            isStarted: isStarted,
            isEnabled: settings.windowCycleEnabled,
            arePreviewsEnabled: settings.showDockPreviews,
            permissions: permissionSnapshotProvider()
        ) else {
            endSession()
            hotkeyRegistry.unregister()
            return
        }

        if let status = hotkeyRegistry.register() {
            endSession()
            settings.windowCycleEnabled = false
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
        guard hotkeyRegistry.isRegistered else {
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
            settings.windowCycleEnabled = false
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
            settings.windowCycleEnabled = false
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

    private func scheduleInventoryPrewarmIfNeeded() {
        guard !hasPrewarmedInventory else {
            return
        }
        hasPrewarmedInventory = true

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }
            self.inventoryPrewarmWorkItem = nil
            guard self.isStarted, self.hotkeyRegistry.isRegistered else {
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
            activeStaticCaptures.removeValue(forKey: identity)?.stop()
            currentImages[identity] = nil
            unavailableStaticIdentities.remove(identity)
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

    private func handleInput(_ event: WindowCycleInputMonitor.Event) {
        switch event {
        case let .advance(direction):
            advanceSession(direction)
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
        let captureWindows = Array(session.staticCaptureWindows.filter { window in
            let identity = PreviewWindowIdentity(window)
            return currentImages[identity] == nil
                && activeStaticCaptures[identity] == nil
                && !unavailableStaticIdentities.contains(identity)
        }.prefix(Self.maximumStaticCaptureCount - activeStaticCaptures.count))
        let captureIdentitiesByProcess = Dictionary(grouping: captureWindows, by: \.processIdentifier)
            .mapValues { windows in
                Set(windows.map(PreviewWindowIdentity.init))
            }
        var seenProcessIdentifiers = Set<pid_t>()
        let processIdentifiers = captureWindows.compactMap { window -> pid_t? in
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
                self?.startStaticCaptures(
                    from: snapshot,
                    processIdentifier: processIdentifier,
                    captureIdentities: captureIdentitiesByProcess[processIdentifier, default: []],
                    target: target,
                    generation: generation
                )
            }
        }
    }

    private func startStaticCaptures(
        from snapshot: PreviewWindowSnapshot,
        processIdentifier: pid_t,
        captureIdentities: Set<PreviewWindowIdentity>,
        target: DockAppTarget,
        generation: UInt64
    ) {
        guard generation == sessionGeneration,
              let session,
              sessionTarget?.isSameDockTile(as: target) == true
        else {
            return
        }
        let unavailableIdentities = StaticPreviewCaptureAvailabilityPolicy.unavailableIdentities(
            requested: captureIdentities,
            available: Set(snapshot.captureWindows.keys)
        )
        unavailableStaticIdentities.formUnion(unavailableIdentities)
        let policy = PreviewCapturePolicy.adaptive(
            livePreviewsEnabled: false,
            windowCount: session.windows.count,
            powerState: .current
        )
        var didStartCapture = false
        for window in session.windows where window.processIdentifier == processIdentifier {
            guard activeStaticCaptures.count < Self.maximumStaticCaptureCount else {
                break
            }
            let identity = PreviewWindowIdentity(window)
            guard captureIdentities.contains(identity),
                  currentImages[identity] == nil,
                  activeStaticCaptures[identity] == nil,
                  let captureWindow = snapshot.captureWindows[identity],
                  let captureSession = previewService.startPreviewCaptureSession(
                    identity: identity,
                    window: captureWindow,
                    mode: .staticImage,
                    policy: policy,
                    imageHandler: { [weak self] _, image in
                        self?.acceptStaticImage(
                            image,
                            for: identity,
                            target: target,
                            generation: generation
                        )
                    },
                    errorHandler: { [weak self] _ in
                        guard let self,
                              generation == self.sessionGeneration,
                              self.sessionTarget?.isSameDockTile(as: target) == true,
                              let currentSession = self.session
                        else {
                            return
                        }
                        self.activeStaticCaptures[identity] = nil
                        self.unavailableStaticIdentities.insert(identity)
                        self.requestStaticPreviews(
                            for: currentSession,
                            target: target,
                            generation: generation
                        )
                    }
                  )
            else {
                continue
            }
            activeStaticCaptures[identity] = captureSession
            didStartCapture = true
        }

        if !unavailableIdentities.isEmpty || !didStartCapture {
            requestStaticPreviews(
                for: session,
                target: target,
                generation: generation
            )
        }
    }

    private func acceptStaticImage(
        _ image: NSImage,
        for identity: PreviewWindowIdentity,
        target: DockAppTarget,
        generation: UInt64
    ) {
        activeStaticCaptures[identity]?.stop()
        activeStaticCaptures[identity] = nil
        guard generation == sessionGeneration,
              sessionTarget?.isSameDockTile(as: target) == true,
              var session,
              let index = session.windows.firstIndex(where: { PreviewWindowIdentity($0) == identity })
        else {
            return
        }

        currentImages[identity] = image
        session.update(copy(session.windows[index], image: image), at: index)
        self.session = session
        previewPanelController.updatePreview(windowID: identity.windowID ?? 0, image: image)
        cacheImages(for: identity.processIdentifier)
        requestStaticPreviews(for: session, target: target, generation: generation)
    }

    private func removeWindow(_ window: PreviewWindowInfo) {
        removeWindow(PreviewWindowIdentity(window))
    }

    private func removeWindow(_ identity: PreviewWindowIdentity) {
        activeStaticCaptures.removeValue(forKey: identity)?.stop()
        currentImages[identity] = nil
        unavailableStaticIdentities.remove(identity)
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
        let captureIdentities = Set(activeStaticCaptures.keys.filter {
            $0.processIdentifier == processIdentifier
        }).union(currentImages.keys.filter {
            $0.processIdentifier == processIdentifier
        }).union(unavailableStaticIdentities.filter {
            $0.processIdentifier == processIdentifier
        })
        for identity in captureIdentities {
            activeStaticCaptures.removeValue(forKey: identity)?.stop()
            currentImages[identity] = nil
            unavailableStaticIdentities.remove(identity)
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
        let wasActive = session != nil || sessionTarget != nil || inputMonitor.isMonitoring
        inventoryRefreshGeneration &+= 1
        sessionGeneration &+= 1
        isAwaitingInventory = false
        stopObservingInventoryChanges()
        inputMonitor.stop()
        activeStaticCaptures.values.forEach { $0.stop() }
        activeStaticCaptures.removeAll()
        unavailableStaticIdentities.removeAll()
        currentImages.removeAll()
        session = nil
        sessionTarget = nil
        previewPanelController.hide()
        if wasActive {
            onSessionActivityChanged(false)
        }
        guard let window else {
            return
        }
        windowControlService.focusWindow(
            processIdentifier: window.processIdentifier,
            title: window.title,
            windowID: window.windowID
        )
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
        case .seed, .processInvalidated, .processActivated, .windowFocused, .activeSpaceChanged:
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
        return copy(
            window,
            image: currentImages[identity] ?? window.staticPreviewImage,
            placeholderText: window.isMinimized
                ? AppStrings.text(.previewMinimizedClickRestore)
                : AppStrings.text(.previewWindowContentUnavailable)
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
