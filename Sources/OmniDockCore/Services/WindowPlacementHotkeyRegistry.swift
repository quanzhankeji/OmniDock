import AppKit
import Carbon.HIToolbox

private let windowPlacementEventSignature: OSType = 0x4F445750 // "ODWP"

@MainActor
final class WindowPlacementRegistrationStatusStore {
    static let changedNotification = Notification.Name(
        "OmniDockWindowPlacementRegistrationChanged"
    )

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
final class WindowPlacementHotkeyRegistry {
    var onTrigger: ((UUID) -> Void)?

    private struct RegisteredHotkey {
        let reference: EventHotKeyRef
        let commandID: UUID
    }

    private var handlerReference: EventHandlerRef?
    private var registeredHotkeys: [UInt32: RegisteredHotkey] = [:]
    private var nextIdentifier: UInt32 = 1

    func replace(_ registrations: [(UUID, RecordedShortcut)]) -> OSStatus? {
        unregisterAll()
        guard !registrations.isEmpty else {
            return nil
        }
        if let status = installEventHandlerIfNeeded() {
            return status
        }

        for registration in registrations {
            let identifier = nextIdentifier
            nextIdentifier = nextIdentifier == UInt32.max ? 1 : nextIdentifier + 1
            let hotkeyID = EventHotKeyID(
                signature: windowPlacementEventSignature,
                id: identifier
            )
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(
                UInt32(registration.1.keyCode),
                CarbonHotkeyRegistry.carbonModifierFlags(
                    for: registration.1.modifierFlags
                ),
                hotkeyID,
                GetApplicationEventTarget(),
                OptionBits(kEventHotKeyExclusive),
                &reference
            )
            guard status == noErr, let reference else {
                unregisterAll()
                return status
            }
            registeredHotkeys[identifier] = RegisteredHotkey(
                reference: reference,
                commandID: registration.0
            )
        }
        return nil
    }

    func stop() {
        unregisterAll()
        if let handlerReference {
            RemoveEventHandler(handlerReference)
            self.handlerReference = nil
        }
    }

    func unregisterAll() {
        registeredHotkeys.values.forEach {
            UnregisterEventHotKey($0.reference)
        }
        registeredHotkeys.removeAll()
    }

    fileprivate func handle(_ hotkeyID: EventHotKeyID) {
        guard hotkeyID.signature == windowPlacementEventSignature,
              let commandID = registeredHotkeys[hotkeyID.id]?.commandID
        else {
            return
        }
        onTrigger?(commandID)
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
            windowPlacementHotkeyHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &newHandler
        )
        guard status == noErr else {
            return status
        }
        handlerReference = newHandler
        return nil
    }
}

private let windowPlacementHotkeyHandler: EventHandlerUPP = { _, event, userData in
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
    guard status == noErr,
          hotkeyID.signature == windowPlacementEventSignature
    else {
        return OSStatus(eventNotHandledErr)
    }
    let registry = Unmanaged<WindowPlacementHotkeyRegistry>
        .fromOpaque(userData)
        .takeUnretainedValue()
    Task { @MainActor in
        registry.handle(hotkeyID)
    }
    return noErr
}
