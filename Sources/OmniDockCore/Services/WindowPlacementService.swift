import AppKit
import Carbon.HIToolbox

enum WindowPlacementShortcutPolicy {
    static func reservedShortcuts(in settings: SettingsStore) -> Set<RecordedShortcut> {
        var shortcuts = Set(
            settings.appHotkeyBindings.compactMap { binding in
                binding.isEnabled ? binding.recordedShortcut : nil
            }
        )
        if settings.clipboardHistoryEnabled {
            shortcuts.insert(ClipboardHistoryShortcut.recorded)
        }
        if settings.windowCycleEnabled {
            shortcuts.insert(WindowCycleShortcut.recorded)
        }
        return shortcuts
    }

    static func rejectionReason(
        for shortcut: RecordedShortcut,
        commandID: UUID,
        configuration: WindowPlacementConfiguration,
        settings: SettingsStore,
        systemShortcuts: Set<RecordedShortcut> = SystemHotkeyConflictChecker.enabledSystemShortcuts()
    ) -> String? {
        if let reason = ShortcutRecorderValidation.rejectionReason(
            for: shortcut,
            systemShortcuts: systemShortcuts
        ) {
            return reason
        }
        if reservedShortcuts(in: settings).contains(shortcut) {
            return AppStrings.text(.windowPlacementShortcutConflict)
        }
        if configuration.commands.contains(where: {
            $0.id != commandID
                && $0.isEnabled
                && $0.shortcut == shortcut
        }) {
            return AppStrings.text(.hotkeyDuplicate)
        }
        return nil
    }
}

enum WindowPlacementRestoreFramePolicy {
    // Restore entries are keyed by pid + CGWindowID, so entries from an
    // exited process must be dropped: a later process could otherwise
    // inherit a dead window's remembered frame.
    static func prunedAfterTermination<Value>(
        _ frames: [WindowPlacementRuntimeIdentifier: Value],
        processIdentifier: pid_t
    ) -> [WindowPlacementRuntimeIdentifier: Value] {
        frames.filter { $0.key.processIdentifier != processIdentifier }
    }
}

@MainActor
final class WindowPlacementService {
    private struct RestoreEntry {
        let originalFrame: CGRect
        var lastAppliedFrame: CGRect
    }

    private let settings: SettingsStore
    private let permissionService: PermissionService
    private let registrationStatus: WindowPlacementRegistrationStatusStore
    private let hotkeyRegistry: WindowPlacementHotkeyRegistry
    private let paletteController: WindowPlacementPaletteController
    private let pointerMonitor: WindowPlacementPointerMonitor
    private var restoreFrames: [WindowPlacementRuntimeIdentifier: RestoreEntry] = [:]
    private var terminationObserver: NSObjectProtocol?
    private var isStarted = false

    init(
        settings: SettingsStore,
        permissionService: PermissionService,
        registrationStatus: WindowPlacementRegistrationStatusStore,
        onOpenSettings: @escaping () -> Void
    ) {
        self.settings = settings
        self.permissionService = permissionService
        self.registrationStatus = registrationStatus
        hotkeyRegistry = WindowPlacementHotkeyRegistry()
        paletteController = WindowPlacementPaletteController()
        pointerMonitor = WindowPlacementPointerMonitor()

        hotkeyRegistry.onTrigger = { [weak self] commandID in
            self?.perform(commandID: commandID)
        }
        pointerMonitor.onGreenButtonHover = { [weak self] target, anchor in
            self?.showPalette(for: target, anchor: anchor)
        }
        pointerMonitor.onPointerMoved = { [weak self] point in
            self?.paletteController.pointerMoved(toEventTapPoint: point)
        }
        pointerMonitor.onDragBegan = { [weak self] target, screens in
            guard let self else {
                return
            }
            self.paletteController.showDragRegions(
                commands: self.settings
                    .windowPlacementConfiguration.commands,
                screens: screens,
                for: target
            )
        }
        pointerMonitor.onDragTargetChanged = {
            [weak self] _, command, screen in
            self?.paletteController.updateDragRegionHighlight(
                commandID: command?.id,
                displayID: screen?.displayID
            )
        }
        pointerMonitor.onDragCancelled = { [weak self] in
            self?.paletteController.hideDragRegions()
        }
        pointerMonitor.onDragCompleted = { [weak self] target, command, screen in
            self?.paletteController.hideDragRegions()
            _ = self?.apply(command, to: target, preferredScreen: screen)
        }
        paletteController.onChoose = { [weak self] commandID, target in
            self?.perform(commandID: commandID, target: target)
        }
        paletteController.onOpenSettings = onOpenSettings
    }

    func start() {
        guard !isStarted else {
            return
        }
        isStarted = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsChanged(_:)),
            name: SettingsStore.changedNotification,
            object: settings
        )
        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
            else {
                return
            }
            let processIdentifier = application.processIdentifier
            Task { @MainActor [weak self] in
                self?.pruneRestoreFrames(terminatedProcessIdentifier: processIdentifier)
            }
        }
        refresh()
    }

    func stop() {
        guard isStarted else {
            return
        }
        isStarted = false
        NotificationCenter.default.removeObserver(self)
        if let terminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(terminationObserver)
            self.terminationObserver = nil
        }
        hotkeyRegistry.stop()
        pointerMonitor.stop()
        paletteController.hide()
        restoreFrames.removeAll()
    }

    func refresh() {
        guard isStarted else {
            return
        }
        let configuration = settings.windowPlacementConfiguration
        let permissions = permissionService.snapshot()
        guard configuration.isEnabled,
              PermissionFeatureGate.isSatisfied(
                  for: .windowPlacement,
                  in: permissions
              )
        else {
            hotkeyRegistry.unregisterAll()
            pointerMonitor.stop()
            paletteController.hide()
            registrationStatus.setWarning(nil)
            return
        }

        let systemShortcuts = SystemHotkeyConflictChecker.enabledSystemShortcuts()
        let registrations = configuration.commands.compactMap { command
            -> (UUID, RecordedShortcut)? in
            guard command.isEnabled, let shortcut = command.shortcut else {
                return nil
            }
            guard WindowPlacementShortcutPolicy.rejectionReason(
                for: shortcut,
                commandID: command.id,
                configuration: configuration,
                settings: settings,
                systemShortcuts: systemShortcuts
            ) == nil else {
                return nil
            }
            return (command.id, shortcut)
        }
        if let status = hotkeyRegistry.replace(registrations) {
            registrationStatus.setWarning(
                status == eventHotKeyExistsErr
                    ? AppStrings.text(.hotkeyRegistrationOccupied)
                    : AppStrings.text(.hotkeyRegistrationFailed)
            )
        } else {
            registrationStatus.setWarning(nil)
        }

        if configuration.showsGreenButtonPalette
            || configuration.observesWindowDragging {
            pointerMonitor.start(configuration: configuration)
        } else {
            pointerMonitor.stop()
        }
    }

    @discardableResult
    func perform(commandID: UUID) -> WindowPlacementExecutionResult {
        guard let target = WindowPlacementAccessibility.focusedWindow() else {
            return .noWindow
        }
        return perform(commandID: commandID, target: target)
    }

    @discardableResult
    func perform(
        commandID: UUID,
        target: WindowPlacementTarget
    ) -> WindowPlacementExecutionResult {
        guard let command = settings.windowPlacementConfiguration.commands.first(
            where: { $0.id == commandID && $0.isEnabled }
        ) else {
            return .unsupportedWindow
        }
        return apply(command, to: target)
    }

    @discardableResult
    private func apply(
        _ command: WindowPlacementCommand,
        to target: WindowPlacementTarget,
        preferredScreen: WindowPlacementScreen? = nil
    ) -> WindowPlacementExecutionResult {
        guard !target.isFullScreen,
              target.canMove,
              command.behavior == .center
                || command.behavior == .restore
                || target.canResize
        else {
            return .unsupportedWindow
        }

        let screens = WindowPlacementScreens.current()
        guard let currentScreen = WindowPlacementScreens.screen(
            withLargestIntersection: target.frame,
            in: screens
        ) else {
            return .noTargetScreen
        }
        let destinationScreen = preferredScreen
            ?? WindowPlacementScreens.adjacent(
                to: currentScreen,
                direction: command.behavior,
                in: screens
            )
            ?? currentScreen

        let identifier = target.runtimeIdentifier
        if let entry = restoreFrames[identifier],
           !framesAreEquivalent(target.frame, entry.lastAppliedFrame),
           command.behavior != .restore {
            restoreFrames.removeValue(forKey: identifier)
        }
        let restoreFrame = restoreFrames[identifier]?.originalFrame
        if command.behavior == .restore, restoreFrame == nil {
            return .noRestoreFrame
        }
        if command.behavior != .restore, restoreFrames[identifier] == nil {
            restoreFrames[identifier] = RestoreEntry(
                originalFrame: target.frame,
                lastAppliedFrame: target.frame
            )
        }

        let placementVisibleFrame = preferredScreen?.visibleFrame
            ?? currentScreen.visibleFrame
        guard let targetFrame = WindowPlacementGeometry.targetFrame(
            for: command,
            currentFrame: target.frame,
            visibleFrame: placementVisibleFrame,
            adjacentVisibleFrame: destinationScreen.visibleFrame,
            restoreFrame: restoreFrame
        ) else {
            return .noTargetScreen
        }
        guard let appliedFrame = WindowPlacementAccessibility.setFrame(
            targetFrame,
            for: target
        ) else {
            return .accessibilityFailure
        }
        if command.behavior == .restore {
            restoreFrames.removeValue(forKey: identifier)
        } else if var entry = restoreFrames[identifier] {
            entry.lastAppliedFrame = appliedFrame
            restoreFrames[identifier] = entry
        }
        return .applied(appliedFrame)
    }

    private func pruneRestoreFrames(terminatedProcessIdentifier: pid_t) {
        restoreFrames = WindowPlacementRestoreFramePolicy.prunedAfterTermination(
            restoreFrames,
            processIdentifier: terminatedProcessIdentifier
        )
    }

    private func framesAreEquivalent(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= 3
            && abs(lhs.minY - rhs.minY) <= 3
            && abs(lhs.width - rhs.width) <= 3
            && abs(lhs.height - rhs.height) <= 3
    }

    private func showPalette(
        for target: WindowPlacementTarget,
        anchor: CGRect
    ) {
        let commands = settings.windowPlacementConfiguration.commands.filter {
            $0.isEnabled
        }
        guard !commands.isEmpty else {
            return
        }
        paletteController.show(
            commands: commands,
            target: target,
            anchorEventTapFrame: anchor
        )
    }

    @objc private func settingsChanged(_ notification: Notification) {
        guard SettingsStore.change(in: notification).affectsWindowPlacement else {
            return
        }
        refresh()
    }
}
