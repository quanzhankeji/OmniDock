import AppKit

@MainActor
final class PreviewWorkspaceMonitor {
    private let notificationCenter: NotificationCenter
    private let applicationNotificationCenter: NotificationCenter
    private let onDisplayConfigurationChanged: () -> Void
    private let onSuspensionChanged: (Bool) -> Void
    private var observers: [NSObjectProtocol] = []
    private var displayObserver: NSObjectProtocol?
    private var suspensionReasons = Set<Notification.Name>()

    var isSuspended: Bool { !suspensionReasons.isEmpty }

    init(
        notificationCenter: NotificationCenter,
        applicationNotificationCenter: NotificationCenter = .default,
        onDisplayConfigurationChanged: @escaping () -> Void = {},
        onSuspensionChanged: @escaping (Bool) -> Void
    ) {
        self.notificationCenter = notificationCenter
        self.applicationNotificationCenter = applicationNotificationCenter
        self.onDisplayConfigurationChanged = onDisplayConfigurationChanged
        self.onSuspensionChanged = onSuspensionChanged
    }

    deinit {
        observers.forEach(notificationCenter.removeObserver)
        if let displayObserver { applicationNotificationCenter.removeObserver(displayObserver) }
    }

    func start() {
        guard observers.isEmpty else { return }
        displayObserver = applicationNotificationCenter.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.observers.isEmpty else { return }
                self.onDisplayConfigurationChanged()
            }
        }
        let transitions: [(Notification.Name, Notification.Name)] = [
            (NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification),
            (NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification),
            (NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification)
        ]
        for (pause, resume) in transitions {
            for (name, suspending) in [(pause, true), (resume, false)] {
                observers.append(notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.update(reason: pause, suspending: suspending)
                    }
                })
            }
        }
    }

    func stop() {
        if let displayObserver { applicationNotificationCenter.removeObserver(displayObserver) }
        displayObserver = nil
        observers.forEach(notificationCenter.removeObserver)
        observers.removeAll()
        suspensionReasons.removeAll()
    }

    private func update(reason: Notification.Name, suspending: Bool) {
        guard !observers.isEmpty else { return }
        let wasSuspended = isSuspended
        if suspending {
            suspensionReasons.insert(reason)
        } else {
            suspensionReasons.remove(reason)
        }
        // Display wake alone must not resume a sleeping or inactive user session.
        if wasSuspended != isSuspended { onSuspensionChanged(isSuspended) }
    }
}
