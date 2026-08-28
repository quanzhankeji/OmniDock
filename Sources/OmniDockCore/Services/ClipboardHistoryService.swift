import AppKit
import Carbon.HIToolbox
import CoreGraphics

enum ClipboardHistoryShortcut {
    static let defaultShortcut = RecordedShortcut(
        keyCode: kVK_ANSI_C,
        modifierFlags: NSEvent.ModifierFlags([.command, .shift]).rawValue
    )
}

enum ClipboardAutoPasteReadiness: Equatable {
    case ready
    case targetUnavailable
    case secureInputActive
}

enum ClipboardAutoPasteStep: Equatable {
    case paste
    case wait
    case cancel
}

// A synthetic Command-V goes to whichever application owns keyboard focus when
// it is posted, not to the one the palette was opened over. Activation is
// asynchronous, so pasting on a fixed delay can deliver clipboard content -
// frequently a password or token - into an unintended application. These rules
// keep the paste tied to the intended target and abandon it otherwise; the
// entry is already on the pasteboard, so the user can still paste manually.
enum ClipboardAutoPastePolicy {
    static let activationTimeout: TimeInterval = 0.6
    static let activationPollInterval: TimeInterval = 0.02

    static func readiness(
        hasTarget: Bool,
        isTargetTerminated: Bool,
        isSecureInputEnabled: Bool
    ) -> ClipboardAutoPasteReadiness {
        guard hasTarget, !isTargetTerminated else {
            return .targetUnavailable
        }
        // Secure input suppresses synthetic key events, so the paste would be
        // silently dropped. Say so instead of appearing to do nothing.
        guard !isSecureInputEnabled else {
            return .secureInputActive
        }
        return .ready
    }

    static func step(
        frontmostProcessIdentifier: pid_t?,
        targetProcessIdentifier: pid_t,
        isTargetTerminated: Bool,
        isSecureInputEnabled: Bool,
        now: Date,
        deadline: Date
    ) -> ClipboardAutoPasteStep {
        guard !isTargetTerminated, !isSecureInputEnabled else {
            return .cancel
        }
        guard frontmostProcessIdentifier == targetProcessIdentifier else {
            return now < deadline ? .wait : .cancel
        }
        return .paste
    }
}

@MainActor
final class ClipboardHistoryRegistrationStatus {
    static let changedNotification = Notification.Name("OmniDockClipboardHistoryRegistrationChanged")

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
protocol ClipboardHistoryHotkeyRegistering: AnyObject {
    var onTrigger: (() -> Void)? { get set }
    func register(_ shortcut: RecordedShortcut) -> OSStatus?
    func unregister()
    func stop()
}

@MainActor
final class ClipboardHistoryService {
    static let changedNotification = Notification.Name("OmniDockClipboardHistoryChanged")
    static let maximumEntryBytes = 32 * 1_024 * 1_024
    static let maximumTotalBytes = 256 * 1_024 * 1_024

    private let settings: SettingsStore
    private let permissionService: PermissionService
    private let store: ClipboardHistoryPersisting
    private let panelController: ClipboardPaletteController
    private let registrationStatus: ClipboardHistoryRegistrationStatus
    private let hotkeyRegistry: ClipboardHistoryHotkeyRegistering
    private let pasteboard: NSPasteboard
    private let monitoringActivity = RuntimeActivityLease()
    private let captureQueue = DispatchQueue(
        label: "com.quanzhankeji.OmniDock.clipboard-capture",
        qos: .utility
    )
    private var monitor: Timer?
    private var lastObservedChangeCount = 0
    private var selfWrittenChangeCount: Int?
    private var captureGeneration = 0
    private var isStarted = false
    private var registeredShortcut: RecordedShortcut?
    private var records: [ClipboardHistoryRecord]
    private var recordsRevision: UInt64 = 0

    var isMonitoring: Bool {
        monitor != nil
    }

    var isPanelVisible: Bool {
        panelController.isVisible
    }

    init(
        settings: SettingsStore,
        permissionService: PermissionService,
        store: ClipboardHistoryPersisting,
        panelController: ClipboardPaletteController,
        registrationStatus: ClipboardHistoryRegistrationStatus,
        hotkeyRegistry: ClipboardHistoryHotkeyRegistering? = nil,
        pasteboard: NSPasteboard = .general
    ) {
        self.settings = settings
        self.permissionService = permissionService
        self.store = store
        self.panelController = panelController
        self.registrationStatus = registrationStatus
        self.hotkeyRegistry = hotkeyRegistry ?? ClipboardHistoryHotkeyRegistry()
        self.pasteboard = pasteboard
        records = store.records()

        self.hotkeyRegistry.onTrigger = { [weak self] in
            self?.togglePanel()
        }
        panelController.onChoose = { [weak self] id, autoPaste, sourceApplication in
            self?.choose(id: id, autoPaste: autoPaste, sourceApplication: sourceApplication)
        }
        panelController.onDelete = { [weak self] id in
            self?.delete(id: id)
        }
        panelController.onPreviewRequest = { [weak self] id in
            self?.previewContent(id: id)
        }
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
        reconcileState()
    }

    func stop() {
        guard isStarted else {
            return
        }
        isStarted = false
        NotificationCenter.default.removeObserver(self)
        stopMonitoring()
        hotkeyRegistry.stop()
        registeredShortcut = nil
        panelController.hide()
    }

    func snapshot() -> ClipboardHistorySnapshot {
        ClipboardHistorySnapshot(
            records: records,
            warning: store.warning ?? registrationStatus.warning,
            revision: recordsRevision
        )
    }

    func previewContent(id: UUID) -> ClipboardHistoryPreviewContent? {
        guard let record = records.first(where: { $0.id == id }),
              let payload = store.payload(for: id)
        else {
            return nil
        }
        return ClipboardHistoryCodec.previewContent(record: record, payload: payload)
    }

    func copy(id: UUID) {
        choose(id: id, autoPaste: false, sourceApplication: nil)
    }

    func delete(id: UUID) {
        store.delete(id: id)
        refreshRecords()
    }

    func clear() {
        store.removeAll()
        refreshRecords()
    }

    @objc private func settingsChanged(_ notification: Notification) {
        let change = SettingsStore.change(in: notification)
        guard change.affectsClipboardHistory || change == .hotkeyBindings else {
            return
        }
        if change.affectsClipboardHistory {
            store.prune(
                limit: settings.clipboardHistoryLimit,
                maximumTotalBytes: Self.maximumTotalBytes
            )
            refreshRecords()
        }
        reconcileState()
    }

    private func reconcileState() {
        guard isStarted, settings.clipboardHistoryEnabled else {
            stopMonitoring()
            unregisterHotkeyIfNeeded()
            registrationStatus.setWarning(nil)
            panelController.hide()
            return
        }

        let shortcut = settings.clipboardHistoryShortcut
        // Defensive guard: the recorder already enforces this, but a corrupted
        // stored value must never leave us with a modifier-free global hotkey.
        if let reason = ShortcutRecorderValidation.minimumModifierRejectionReason(
            for: shortcut
        ) {
            settings.clipboardHistoryEnabled = false
            registrationStatus.setWarning(reason)
            return
        }

        if registeredShortcut != shortcut {
            unregisterHotkeyIfNeeded()
            if let status = hotkeyRegistry.register(shortcut) {
                let warning = status == eventHotKeyExistsErr
                    ? AppStrings.text(.clipboardShortcutConflict)
                    : AppStrings.text(.hotkeyRegistrationFailed)
                settings.clipboardHistoryEnabled = false
                registrationStatus.setWarning(warning)
                return
            }
            registeredShortcut = shortcut
        }

        registrationStatus.setWarning(nil)
        startMonitoring()
    }

    private func startMonitoring() {
        guard monitor == nil else {
            return
        }
        lastObservedChangeCount = pasteboard.changeCount
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollPasteboard()
            }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        monitor = timer
        monitoringActivity.begin(reason: "Monitor clipboard changes")
    }

    private func stopMonitoring() {
        monitor?.invalidate()
        monitor = nil
        monitoringActivity.end()
        selfWrittenChangeCount = nil
        captureGeneration += 1
    }

    private func unregisterHotkeyIfNeeded() {
        guard registeredShortcut != nil else {
            return
        }
        hotkeyRegistry.unregister()
        registeredShortcut = nil
    }

    private func pollPasteboard() {
        let changeCount = pasteboard.changeCount
        guard changeCount != lastObservedChangeCount else {
            return
        }
        lastObservedChangeCount = changeCount
        if selfWrittenChangeCount == changeCount {
            selfWrittenChangeCount = nil
            return
        }

        guard let payload = ClipboardHistoryCodec.payload(from: pasteboard) else {
            return
        }
        // Encoding, hashing, and thumbnail rendering can take a visible beat
        // for large payloads, so they run off the main run loop. The serial
        // queue preserves capture order, and the generation check drops
        // results that finish after monitoring stopped.
        let generation = captureGeneration
        let sourceApplication = NSWorkspace.shared.frontmostApplication
        let capturedAt = Date()
        let maximumPayloadBytes = Self.maximumEntryBytes
        captureQueue.async { [weak self] in
            guard let processed = ClipboardHistoryCodec.processedCapture(
                from: payload,
                maximumPayloadBytes: maximumPayloadBytes
            ) else {
                return
            }
            Task { @MainActor [weak self] in
                self?.finishCapture(
                    processed,
                    sourceApplication: sourceApplication,
                    capturedAt: capturedAt,
                    generation: generation
                )
            }
        }
    }

    private func finishCapture(
        _ processed: ClipboardHistoryCodec.ProcessedCapture,
        sourceApplication: NSRunningApplication?,
        capturedAt: Date,
        generation: Int
    ) {
        guard generation == captureGeneration else {
            return
        }
        let candidate = ClipboardHistoryCodec.candidate(
            from: processed,
            sourceApplication: sourceApplication,
            capturedAt: capturedAt
        )
        _ = store.store(
            candidate,
            limit: settings.clipboardHistoryLimit,
            maximumTotalBytes: Self.maximumTotalBytes
        )
        refreshRecords()
    }

    private func togglePanel() {
        panelController.toggle(
            records: records,
            warning: store.warning,
            sourceApplication: NSWorkspace.shared.frontmostApplication
        )
    }

    private func choose(
        id: UUID,
        autoPaste: Bool,
        sourceApplication: NSRunningApplication?
    ) {
        guard let payload = store.payload(for: id),
              ClipboardHistoryCodec.write(
                  payload,
                  to: pasteboard,
                  sourceIdentifier: Bundle.main.bundleIdentifier ?? "com.quanzhankeji.OmniDock"
              )
        else {
            panelController.showTransientMessage(AppStrings.text(.clipboardCopyFailed))
            return
        }

        lastObservedChangeCount = pasteboard.changeCount
        selfWrittenChangeCount = lastObservedChangeCount
        store.markCopied(id: id, at: Date())
        refreshRecords()

        guard autoPaste else {
            panelController.hide()
            return
        }
        guard permissionService.snapshot().accessibility else {
            panelController.showTransientMessage(
                AppStrings.text(.clipboardPasteNeedsAccessibility),
                hideAfter: 1.2
            )
            return
        }

        switch ClipboardAutoPastePolicy.readiness(
            hasTarget: sourceApplication != nil,
            isTargetTerminated: sourceApplication?.isTerminated ?? true,
            isSecureInputEnabled: Self.isSecureInputEnabled()
        ) {
        case .ready:
            guard let targetApplication = sourceApplication else {
                return
            }
            panelController.hide()
            targetApplication.activate(options: [.activateIgnoringOtherApps])
            pasteWhenTargetBecomesFrontmost(
                targetApplication,
                deadline: Date().addingTimeInterval(
                    ClipboardAutoPastePolicy.activationTimeout
                )
            )
        case .targetUnavailable:
            panelController.showTransientMessage(
                AppStrings.text(.clipboardPasteTargetUnavailable),
                hideAfter: 1.2
            )
        case .secureInputActive:
            panelController.showTransientMessage(
                AppStrings.text(.clipboardPasteSecureInputActive),
                hideAfter: 1.2
            )
        }
    }

    private func pasteWhenTargetBecomesFrontmost(
        _ target: NSRunningApplication,
        deadline: Date
    ) {
        switch ClipboardAutoPastePolicy.step(
            frontmostProcessIdentifier: NSWorkspace.shared
                .frontmostApplication?
                .processIdentifier,
            targetProcessIdentifier: target.processIdentifier,
            isTargetTerminated: target.isTerminated,
            isSecureInputEnabled: Self.isSecureInputEnabled(),
            now: Date(),
            deadline: deadline
        ) {
        case .paste:
            Self.postPasteShortcut()
        case .wait:
            DispatchQueue.main.asyncAfter(
                deadline: .now() + ClipboardAutoPastePolicy.activationPollInterval
            ) { [weak self] in
                self?.pasteWhenTargetBecomesFrontmost(target, deadline: deadline)
            }
        case .cancel:
            // The palette is already hidden and the entry is on the pasteboard,
            // so the user can paste manually where they intended.
            break
        }
    }

    private static func isSecureInputEnabled() -> Bool {
        IsSecureEventInputEnabled()
    }

    private func refreshRecords() {
        records = store.records()
        recordsRevision &+= 1
        panelController.update(records: records, warning: store.warning)
        NotificationCenter.default.post(name: Self.changedNotification, object: self)
    }

    private static func postPasteShortcut() {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: CGKeyCode(kVK_ANSI_V),
                  keyDown: true
              ),
              let keyUp = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: CGKeyCode(kVK_ANSI_V),
                  keyDown: false
              )
        else {
            return
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cgAnnotatedSessionEventTap)
        keyUp.post(tap: .cgAnnotatedSessionEventTap)
    }
}

private let clipboardHistoryHotkeySignature: OSType = 0x4F444342 // "ODCB"

@MainActor
private final class ClipboardHistoryHotkeyRegistry: ClipboardHistoryHotkeyRegistering {
    var onTrigger: (() -> Void)?

    private var eventHandlerReference: EventHandlerRef?
    private var hotkeyReference: EventHotKeyRef?

    func register(_ shortcut: RecordedShortcut) -> OSStatus? {
        if hotkeyReference != nil {
            return nil
        }
        if let status = installHandlerIfNeeded() {
            return status
        }

        let hotkeyID = EventHotKeyID(signature: clipboardHistoryHotkeySignature, id: 1)
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(shortcut.keyCode),
            CarbonHotkeyRegistry.carbonModifierFlags(for: shortcut.modifierFlags),
            hotkeyID,
            GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive),
            &reference
        )
        guard status == noErr, let reference else {
            return status
        }
        hotkeyReference = reference
        return nil
    }

    func unregister() {
        if let hotkeyReference {
            UnregisterEventHotKey(hotkeyReference)
            self.hotkeyReference = nil
        }
    }

    func stop() {
        unregister()
        if let eventHandlerReference {
            RemoveEventHandler(eventHandlerReference)
            self.eventHandlerReference = nil
        }
    }

    fileprivate func handle(id: EventHotKeyID) -> Bool {
        guard id.signature == clipboardHistoryHotkeySignature, id.id == 1 else {
            return false
        }
        onTrigger?()
        return true
    }

    private func installHandlerIfNeeded() -> OSStatus? {
        guard eventHandlerReference == nil else {
            return nil
        }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var reference: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            clipboardHistoryEventHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &reference
        )
        guard status == noErr else {
            return status
        }
        eventHandlerReference = reference
        return nil
    }
}

private let clipboardHistoryEventHandler: EventHandlerUPP = { _, event, userData in
    guard let event, let userData else {
        return OSStatus(eventNotHandledErr)
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
    guard hotkeyID.signature == clipboardHistoryHotkeySignature else {
        return OSStatus(eventNotHandledErr)
    }
    let registry = Unmanaged<ClipboardHistoryHotkeyRegistry>
        .fromOpaque(userData)
        .takeUnretainedValue()
    Task { @MainActor in
        _ = registry.handle(id: hotkeyID)
    }
    return noErr
}
