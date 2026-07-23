import AppKit
import Carbon.HIToolbox

private let configuredAppHotkeyEventSignature: OSType = 0x4F44484B // "ODHK"

@MainActor
public final class AppHotkeyService {
    private let settings: SettingsStore
    private let permissionService: PermissionService
    private let windowControlService: WindowControlService
    private let previewService: ScreenCapturePreviewService
    private let registrationStatus: AppHotkeyRegistrationStatusStore
    private let hotkeyRegistry = CarbonHotkeyRegistry()
    private var isStarted = false

    public init(
        settings: SettingsStore,
        permissionService: PermissionService,
        windowControlService: WindowControlService,
        previewService: ScreenCapturePreviewService,
        registrationStatus: AppHotkeyRegistrationStatusStore
    ) {
        self.settings = settings
        self.permissionService = permissionService
        self.windowControlService = windowControlService
        self.previewService = previewService
        self.registrationStatus = registrationStatus
        hotkeyRegistry.onTrigger = { [weak self] binding in
            self?.performConfiguredAction(for: binding)
        }
    }

    public func start() {
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
        reconcileRegisteredShortcuts()
    }

    public func stop() {
        guard isStarted else {
            return
        }
        isStarted = false
        NotificationCenter.default.removeObserver(self)
        hotkeyRegistry.stop()
    }

    @objc private func settingsChanged(_ notification: Notification) {
        guard SettingsStore.change(in: notification).affectsAppHotkeys else {
            return
        }
        reconcileRegisteredShortcuts()
    }

    private func reconcileRegisteredShortcuts() {
        guard settings.hotkeysEnabled else {
            clearRegisteredShortcuts()
            registrationStatus.clear()
            return
        }

        var claimedShortcuts = Set<RecordedShortcut>()
        let systemShortcuts = SystemHotkeyConflictChecker.enabledSystemShortcuts()
        var registrations: [(AppHotkeyBinding, RecordedShortcut)] = []
        for binding in settings.appHotkeyBindings where binding.isEnabled {
            guard let shortcut = binding.recordedShortcut,
                  ShortcutRecorderValidation.rejectionReason(
                      for: shortcut,
                      systemShortcuts: systemShortcuts
                  ) == nil,
                  claimedShortcuts.insert(shortcut).inserted
            else {
                continue
            }

            registrations.append((binding, shortcut))
        }
        let failures = hotkeyRegistry.replaceBindings(registrations)
        registrationStatus.replaceWarnings(Dictionary(
            uniqueKeysWithValues: failures.map { ($0.binding.id, $0.message) }
        ))
    }

    private func clearRegisteredShortcuts() {
        hotkeyRegistry.unregisterAll()
    }

    private func performConfiguredAction(for binding: AppHotkeyBinding) {
        guard let url = binding.bundleURL else {
            return
        }

        guard let bundleIdentifier = binding.bundleIdentifier,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first
        else {
            openConfiguredApplication(at: url, ensuringWindowWithFallback: nil)
            return
        }

        let summary = windowControlService.interactionSummary(for: app.processIdentifier)
        let decision = AppHotkeyDecisionResolver.decision(
            isRunning: true,
            isTopmost: windowControlService.isApplicationTopmostForHotkey(
                processIdentifier: app.processIdentifier
            ),
            isHidden: app.isHidden,
            normalWindowCount: summary.normalWindowCount,
            unminimizedNormalWindowCount: summary.unminimizedNormalWindowCount,
            onscreenNormalWindowCount: summary.onscreenNormalWindowCount
        )
        switch decision {
        case .launchApplication:
            openConfiguredApplication(at: url, ensuringWindowWithFallback: nil)
        case .openApplicationWindow:
            openConfiguredApplication(at: url, ensuringWindowWithFallback: app.processIdentifier)
        case .bringApplicationToFront:
            windowControlService.bringApplicationToFront(processIdentifier: app.processIdentifier)
        case .hideApplication:
            windowControlService.hideApplication(
                processIdentifier: app.processIdentifier,
                revealDesktopWhenHiding: false,
                beforeHide: { [weak self] continuation in
                    guard let self else {
                        continuation()
                        return
                    }
                    self.captureSnapshotsBeforeHide(for: app, completion: continuation)
                }
            )
        }
    }

    private func openConfiguredApplication(at url: URL, ensuringWindowWithFallback fallbackProcessIdentifier: pid_t?) {
        let foregroundReservation = windowControlService.reserveForegroundOperation()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] app, error in
            DispatchQueue.main.async {
                if let error {
                    NSLog("OmniDock hotkey launch failed: \(error.localizedDescription)")
                }

                guard let self,
                      let processIdentifier = app?.processIdentifier ?? fallbackProcessIdentifier
                else {
                    return
                }

                guard let operationToken = self.windowControlService.beginOpenApplication(
                    processIdentifier: processIdentifier,
                    reservation: foregroundReservation
                ) else {
                    return
                }
                self.windowControlService.ensureApplicationWindow(
                    processIdentifier: processIdentifier,
                    operationToken: operationToken
                )
            }
        }
    }

    private func captureSnapshotsBeforeHide(for app: NSRunningApplication, completion: @escaping () -> Void) {
        guard settings.showDockPreviews,
              permissionService.snapshot().screenRecording
        else {
            completion()
            return
        }

        let name = app.localizedName ?? app.bundleIdentifier ?? AppStrings.text(.genericApplication)
        let target = DockAppTarget(
            processIdentifier: app.processIdentifier,
            bundleIdentifier: app.bundleIdentifier,
            localizedName: name,
            dockElementTitle: name,
            hitPoint: .zero,
            dockItemFrame: nil
        )
        previewService.captureSnapshotsBeforeHide(
            for: target,
            policy: .hiddenSnapshot(powerState: .current),
            completion: completion
        )
    }
}

@MainActor
final class CarbonHotkeyRegistry {
    typealias Registration = (binding: AppHotkeyBinding, shortcut: RecordedShortcut)

    var onTrigger: ((AppHotkeyBinding) -> Void)?

    struct RegistrationFailure: Equatable {
        let binding: AppHotkeyBinding
        let status: OSStatus

        var message: String {
            if status == eventHotKeyExistsErr {
                return AppStrings.text(.hotkeyRegistrationOccupied)
            }
            return AppStrings.text(.hotkeyRegistrationFailed)
        }
    }

    private struct RegisteredHotkey {
        let reference: EventHotKeyRef
        let binding: AppHotkeyBinding
    }

    private var handlerReference: EventHandlerRef?
    private var registeredHotkeys: [UInt32: RegisteredHotkey] = [:]
    private var nextHotkeyID: UInt32 = 1

    func replaceBindings(_ registrations: [Registration]) -> [RegistrationFailure] {
        unregisterAll()
        guard !registrations.isEmpty else {
            return []
        }

        if let status = installEventHandlerIfNeeded() {
            return registrations.map { RegistrationFailure(binding: $0.binding, status: status) }
        }

        var failures: [RegistrationFailure] = []
        for registration in registrations {
            if let failure = register(binding: registration.binding, shortcut: registration.shortcut) {
                failures.append(failure)
            }
        }
        return failures
    }

    func stop() {
        unregisterAll()
        if let handlerReference {
            RemoveEventHandler(handlerReference)
            self.handlerReference = nil
        }
    }

    func unregisterAll() {
        for registeredHotkey in registeredHotkeys.values {
            UnregisterEventHotKey(registeredHotkey.reference)
        }
        registeredHotkeys.removeAll()
    }

    private func installEventHandlerIfNeeded() -> OSStatus? {
        guard handlerReference == nil else {
            return nil
        }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var newHandler: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            carbonHotkeyEventHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &newHandler
        )

        if status == noErr {
            handlerReference = newHandler
            return nil
        } else {
            NSLog("OmniDock hotkey event handler install failed: \(status)")
            return status
        }
    }

    private func register(binding: AppHotkeyBinding, shortcut: RecordedShortcut) -> RegistrationFailure? {
        let id = nextHotkeyID
        nextHotkeyID = nextHotkeyID == UInt32.max ? 1 : nextHotkeyID + 1

        var hotkeyID = EventHotKeyID()
        hotkeyID.signature = configuredAppHotkeyEventSignature
        hotkeyID.id = id

        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(shortcut.keyCode),
            Self.carbonModifierFlags(for: shortcut.modifierFlags),
            hotkeyID,
            GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive),
            &reference
        )

        guard status == noErr, let reference else {
            NSLog("OmniDock hotkey registration failed for \(binding.appName): \(status)")
            return RegistrationFailure(binding: binding, status: status)
        }

        registeredHotkeys[id] = RegisteredHotkey(reference: reference, binding: binding)
        return nil
    }

    fileprivate func handleHotkey(id: EventHotKeyID) -> Bool {
        guard id.signature == configuredAppHotkeyEventSignature,
              let registeredHotkey = registeredHotkeys[id.id]
        else {
            return false
        }
        onTrigger?(registeredHotkey.binding)
        return true
    }

    static func carbonModifierFlags(for rawFlags: UInt) -> UInt32 {
        let flags = NSEvent.ModifierFlags(rawValue: rawFlags)
            .intersection(.deviceIndependentFlagsMask)
        var carbonFlags: UInt32 = 0
        if flags.contains(.command) {
            carbonFlags |= UInt32(cmdKey)
        }
        if flags.contains(.option) {
            carbonFlags |= UInt32(optionKey)
        }
        if flags.contains(.control) {
            carbonFlags |= UInt32(controlKey)
        }
        if flags.contains(.shift) {
            carbonFlags |= UInt32(shiftKey)
        }
        return carbonFlags
    }

}

private let carbonHotkeyEventHandler: EventHandlerUPP = { _, event, userData in
    guard let event,
          let userData
    else {
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

    let registry = Unmanaged<CarbonHotkeyRegistry>.fromOpaque(userData).takeUnretainedValue()
    Task { @MainActor in
        registry.handleHotkey(id: hotkeyID)
    }
    // The application event target is shared with other Carbon shortcuts.
    // Do not consume events whose signature belongs to another registry.
    return CarbonHotkeyEventRouting.result(
        handled: hotkeyID.signature == configuredAppHotkeyEventSignature
    )
}

enum CarbonHotkeyEventRouting {
    static func result(handled: Bool) -> OSStatus {
        handled ? noErr : OSStatus(eventNotHandledErr)
    }
}
