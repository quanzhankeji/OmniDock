import AppKit
import ApplicationServices
import CoreGraphics

enum WindowInventoryInvalidation: Hashable {
    case created
    case destroyed
    case minimized
    case restored
    case focused
    case moved
    case resized
    case titleChanged
    case activeSpaceChanged
}

enum WindowInventoryEvent {
    case seed(processIdentifier: pid_t, revision: UInt64, records: [WindowInventoryRecord])
    case processLaunched(processIdentifier: pid_t)
    case processInvalidated(processIdentifier: pid_t, reason: WindowInventoryInvalidation)
    case processActivated(processIdentifier: pid_t)
    case windowFocused(PreviewWindowIdentity)
    case windowRemoved(PreviewWindowIdentity)
    case processTerminated(processIdentifier: pid_t)
    case activeSpaceChanged
}

struct WindowInventoryRecord: Hashable {
    let identity: PreviewWindowIdentity
    let id: String
    let processIdentifier: pid_t
    let appName: String
    let title: String
    let frame: CGRect
    let isMinimized: Bool
    let displayOrder: Int

    init(_ window: PreviewWindowInfo, displayOrder: Int) {
        identity = PreviewWindowIdentity(window)
        id = window.id
        processIdentifier = window.processIdentifier
        appName = window.appName
        title = window.title
        frame = window.frame
        isMinimized = window.isMinimized
        self.displayOrder = displayOrder
    }

    init(
        identity: PreviewWindowIdentity,
        id: String,
        processIdentifier: pid_t,
        appName: String,
        title: String,
        frame: CGRect,
        isMinimized: Bool,
        displayOrder: Int = 0
    ) {
        self.identity = identity
        self.id = id
        self.processIdentifier = processIdentifier
        self.appName = appName
        self.title = title
        self.frame = frame
        self.isMinimized = isMinimized
        self.displayOrder = displayOrder
    }

    func makePreviewWindowInfo() -> PreviewWindowInfo {
        PreviewWindowInfo(
            id: id,
            windowID: identity.windowID,
            processIdentifier: processIdentifier,
            appName: appName,
            title: title,
            frame: frame,
            isMinimized: isMinimized
        )
    }
}

struct WindowInventoryState {
    private(set) var recordsByWindowID: [CGWindowID: WindowInventoryRecord] = [:]
    private(set) var windowIDsByProcessID: [pid_t: Set<CGWindowID>] = [:]
    private(set) var focusHistory: [PreviewWindowIdentity] = []
    private(set) var staleProcessIdentifiers: Set<pid_t> = []

    private var recordsByIdentity: [PreviewWindowIdentity: WindowInventoryRecord] = [:]
    private var revisionByProcessID: [pid_t: UInt64] = [:]

    var processIdentifiers: Set<pid_t> {
        Set(recordsByIdentity.values.map(\.processIdentifier))
    }

    func records(for processIdentifier: pid_t) -> [WindowInventoryRecord] {
        recordsByIdentity.values
            .filter { $0.processIdentifier == processIdentifier }
            .sorted { lhs, rhs in
                if lhs.displayOrder != rhs.displayOrder {
                    return lhs.displayOrder < rhs.displayOrder
                }
                return lhs.id < rhs.id
            }
    }

    func allRecordsByMostRecentFocus() -> [WindowInventoryRecord] {
        let focusedOrder = Dictionary(
            uniqueKeysWithValues: focusHistory.enumerated().map { ($0.element, $0.offset) }
        )
        return recordsByIdentity.values.sorted { lhs, rhs in
            let lhsOrder = focusedOrder[lhs.identity] ?? .max
            let rhsOrder = focusedOrder[rhs.identity] ?? .max
            if lhsOrder != rhsOrder {
                return lhsOrder < rhsOrder
            }
            if lhs.processIdentifier != rhs.processIdentifier {
                return lhs.processIdentifier < rhs.processIdentifier
            }
            if lhs.displayOrder != rhs.displayOrder {
                return lhs.displayOrder < rhs.displayOrder
            }
            return lhs.id < rhs.id
        }
    }

    func isStale(processIdentifier: pid_t) -> Bool {
        staleProcessIdentifiers.contains(processIdentifier)
    }

    @discardableResult
    mutating func apply(_ event: WindowInventoryEvent) -> Bool {
        switch event {
        case let .seed(processIdentifier, revision, records):
            guard revision >= revisionByProcessID[processIdentifier, default: 0] else {
                return false
            }
            let previousFocusHistory = focusHistory
            removeRecords(for: processIdentifier)
            revisionByProcessID[processIdentifier] = revision
            for record in records where record.processIdentifier == processIdentifier {
                recordsByIdentity[record.identity] = record
                if let windowID = record.identity.windowID {
                    recordsByWindowID[windowID] = record
                    windowIDsByProcessID[processIdentifier, default: []].insert(windowID)
                }
            }
            focusHistory = previousFocusHistory.filter { recordsByIdentity[$0] != nil }
            staleProcessIdentifiers.remove(processIdentifier)
            return true

        case let .processLaunched(processIdentifier):
            let hadRecords = !records(for: processIdentifier).isEmpty
            removeRecords(for: processIdentifier)
            revisionByProcessID[processIdentifier] = nil
            staleProcessIdentifiers.remove(processIdentifier)
            return hadRecords

        case let .processInvalidated(processIdentifier, _):
            return staleProcessIdentifiers.insert(processIdentifier).inserted

        case let .processActivated(processIdentifier):
            promote(records(for: processIdentifier).map(\.identity))
            return true

        case let .windowFocused(identity):
            guard recordsByIdentity[identity] != nil else {
                return false
            }
            promote([identity])
            return true

        case let .windowRemoved(identity):
            guard let record = recordsByIdentity.removeValue(forKey: identity) else {
                return false
            }
            if let windowID = record.identity.windowID {
                recordsByWindowID[windowID] = nil
                windowIDsByProcessID[record.processIdentifier]?.remove(windowID)
                if windowIDsByProcessID[record.processIdentifier]?.isEmpty == true {
                    windowIDsByProcessID[record.processIdentifier] = nil
                }
            }
            focusHistory.removeAll { $0 == identity }
            return true

        case let .processTerminated(processIdentifier):
            let hadRecords = !records(for: processIdentifier).isEmpty
            removeRecords(for: processIdentifier)
            revisionByProcessID[processIdentifier] = nil
            staleProcessIdentifiers.remove(processIdentifier)
            return hadRecords

        case .activeSpaceChanged:
            let trackedProcessIdentifiers = self.processIdentifiers
            let previousCount = staleProcessIdentifiers.count
            staleProcessIdentifiers.formUnion(trackedProcessIdentifiers)
            return staleProcessIdentifiers.count != previousCount
        }
    }

    private mutating func removeRecords(for processIdentifier: pid_t) {
        let identities = records(for: processIdentifier).map(\.identity)
        for identity in identities {
            guard let record = recordsByIdentity.removeValue(forKey: identity) else {
                continue
            }
            if let windowID = record.identity.windowID {
                recordsByWindowID[windowID] = nil
            }
        }
        windowIDsByProcessID[processIdentifier] = nil
        let identitySet = Set(identities)
        focusHistory.removeAll { identitySet.contains($0) }
    }

    private mutating func promote(_ identities: [PreviewWindowIdentity]) {
        guard !identities.isEmpty else {
            return
        }
        let identitySet = Set(identities)
        focusHistory.removeAll { identitySet.contains($0) }
        focusHistory.insert(contentsOf: identities, at: 0)
    }
}

enum WindowInventorySnapshotReusePolicy {
    static let maximumAge: TimeInterval = 0.6

    static func shouldReuse(
        seededAt: Date,
        isStale: Bool,
        now: Date = Date()
    ) -> Bool {
        !isStale && now.timeIntervalSince(seededAt) <= maximumAge
    }
}

enum WindowInventoryEventCoalescingPolicy {
    static func delay(for reason: WindowInventoryInvalidation) -> TimeInterval {
        switch reason {
        case .moved, .resized, .titleChanged:
            return 0.1
        case .created, .destroyed, .minimized, .restored, .focused, .activeSpaceChanged:
            return 0
        }
    }
}

@MainActor
private protocol WindowInventoryEventBackend: AnyObject {
    var onEvent: ((WindowInventoryEvent) -> Void)? { get set }
    func start()
    func stop()
}

@MainActor
private final class WorkspaceWindowInventoryEventBackend: WindowInventoryEventBackend {
    var onEvent: ((WindowInventoryEvent) -> Void)?

    private var observers: [NSObjectProtocol] = []

    func start() {
        guard observers.isEmpty else {
            return
        }
        let center = NSWorkspace.shared.notificationCenter
        observers = [
            center.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let processIdentifier = Self.processIdentifier(from: notification) else {
                    return
                }
                Task { @MainActor [weak self] in
                    self?.onEvent?(.processLaunched(processIdentifier: processIdentifier))
                }
            },
            center.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let processIdentifier = Self.processIdentifier(from: notification) else {
                    return
                }
                Task { @MainActor [weak self] in
                    self?.onEvent?(.processActivated(processIdentifier: processIdentifier))
                }
            },
            center.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let processIdentifier = Self.processIdentifier(from: notification) else {
                    return
                }
                Task { @MainActor [weak self] in
                    self?.onEvent?(.processTerminated(processIdentifier: processIdentifier))
                }
            },
            center.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.onEvent?(.activeSpaceChanged)
                }
            }
        ]
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach(center.removeObserver)
        observers.removeAll()
    }

    nonisolated private static func processIdentifier(from notification: Notification) -> pid_t? {
        (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
            .processIdentifier
    }
}

private final class AccessibilityWindowInventoryObserverContext {
    weak var backend: AccessibilityWindowInventoryEventBackend?
    let processIdentifier: pid_t

    init(processIdentifier: pid_t) {
        self.processIdentifier = processIdentifier
    }
}

private final class AccessibilityWindowInventoryObservedApplication {
    let processIdentifier: pid_t
    let applicationElement: AXUIElement
    let observer: AXObserver
    let context: AccessibilityWindowInventoryObserverContext
    var observedWindows: [CFHashCode: AXUIElement] = [:]
    var applicationNotifications = Set<String>()
    var windowNotifications: [CFHashCode: Set<String>] = [:]

    init(
        processIdentifier: pid_t,
        applicationElement: AXUIElement,
        observer: AXObserver,
        context: AccessibilityWindowInventoryObserverContext
    ) {
        self.processIdentifier = processIdentifier
        self.applicationElement = applicationElement
        self.observer = observer
        self.context = context
    }
}

@MainActor
private final class AccessibilityWindowInventoryEventBackend: WindowInventoryEventBackend {
    var onEvent: ((WindowInventoryEvent) -> Void)?

    private let isAccessibilityTrusted: () -> Bool
    private var isRunning = false
    private var observedApplications: [pid_t: AccessibilityWindowInventoryObservedApplication] = [:]

    init(isAccessibilityTrusted: @escaping () -> Bool) {
        self.isAccessibilityTrusted = isAccessibilityTrusted
    }

    func start() {
        isRunning = true
    }

    func stop() {
        isRunning = false
        observedApplications.keys.forEach { untrack(processIdentifier: $0) }
    }

    func track(processIdentifier: pid_t) {
        guard isRunning,
              isAccessibilityTrusted(),
              observedApplications[processIdentifier] == nil,
              NSRunningApplication(processIdentifier: processIdentifier) != nil
        else {
            return
        }

        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        var observer: AXObserver?
        guard AXObserverCreate(processIdentifier, windowInventoryAXObserverCallback, &observer) == .success,
              let observer
        else {
            return
        }

        let context = AccessibilityWindowInventoryObserverContext(
            processIdentifier: processIdentifier
        )
        context.backend = self
        let observedApplication = AccessibilityWindowInventoryObservedApplication(
            processIdentifier: processIdentifier,
            applicationElement: applicationElement,
            observer: observer,
            context: context
        )
        observedApplications[processIdentifier] = observedApplication
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .commonModes
        )
        installApplicationNotifications(for: observedApplication)
        refreshWindowObservers(for: observedApplication)
    }

    func untrack(processIdentifier: pid_t) {
        guard let observedApplication = observedApplications.removeValue(forKey: processIdentifier) else {
            return
        }
        removeNotifications(from: observedApplication)
        CFRunLoopRemoveSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observedApplication.observer),
            .commonModes
        )
    }

    func refreshAccessibilityState() {
        guard isRunning else {
            return
        }
        guard isAccessibilityTrusted() else {
            observedApplications.keys.forEach { untrack(processIdentifier: $0) }
            return
        }
        for processIdentifier in observedApplications.keys {
            guard let observedApplication = observedApplications[processIdentifier] else {
                continue
            }
            refreshWindowObservers(for: observedApplication)
        }
    }

    fileprivate func handle(
        notification: String,
        element: AXUIElement,
        processIdentifier: pid_t
    ) {
        guard let observedApplication = observedApplications[processIdentifier] else {
            return
        }

        if notification == kAXFocusedWindowChangedNotification {
            if let identity = focusedWindowIdentity(in: observedApplication) {
                onEvent?(.windowFocused(identity))
            } else {
                onEvent?(.processActivated(processIdentifier: processIdentifier))
            }
            return
        }

        if notification == kAXCreatedNotification {
            observeWindow(element, in: observedApplication)
            refreshWindowObservers(for: observedApplication)
        } else if notification == kAXUIElementDestroyedNotification {
            let hash = CFHash(element)
            observedApplication.observedWindows[hash] = nil
            observedApplication.windowNotifications[hash] = nil
            if let identity = windowIdentity(for: element, processIdentifier: processIdentifier) {
                onEvent?(.windowRemoved(identity))
            }
        }

        let reason: WindowInventoryInvalidation
        switch notification {
        case kAXCreatedNotification:
            reason = .created
        case kAXUIElementDestroyedNotification:
            reason = .destroyed
        case kAXWindowMiniaturizedNotification:
            reason = .minimized
        case kAXWindowDeminiaturizedNotification:
            reason = .restored
        case kAXMovedNotification:
            reason = .moved
        case kAXResizedNotification:
            reason = .resized
        default:
            reason = .titleChanged
        }
        onEvent?(.processInvalidated(processIdentifier: processIdentifier, reason: reason))
    }

    private func installApplicationNotifications(
        for observedApplication: AccessibilityWindowInventoryObservedApplication
    ) {
        [
            kAXCreatedNotification,
            kAXUIElementDestroyedNotification,
            kAXFocusedWindowChangedNotification,
            kAXWindowMiniaturizedNotification,
            kAXWindowDeminiaturizedNotification
        ].forEach { notification in
            guard add(
                notification: notification,
                to: observedApplication.applicationElement,
                observedApplication: observedApplication
            ) else {
                return
            }
            observedApplication.applicationNotifications.insert(notification)
        }
    }

    private func refreshWindowObservers(
        for observedApplication: AccessibilityWindowInventoryObservedApplication
    ) {
        let windows = axWindows(for: observedApplication.applicationElement)
        let currentHashes = Set(windows.map { window in
            CFHash(window)
        })
        let staleHashes = Set(observedApplication.observedWindows.keys).subtracting(currentHashes)
        for hash in staleHashes {
            removeWindowNotifications(hash: hash, from: observedApplication)
        }
        windows.forEach { observeWindow($0, in: observedApplication) }
    }

    private func observeWindow(
        _ window: AXUIElement,
        in observedApplication: AccessibilityWindowInventoryObservedApplication
    ) {
        let hash = CFHash(window)
        guard observedApplication.observedWindows[hash] == nil else {
            return
        }
        observedApplication.observedWindows[hash] = window
        var notifications = Set<String>()
        [
            kAXUIElementDestroyedNotification,
            kAXWindowMiniaturizedNotification,
            kAXWindowDeminiaturizedNotification,
            kAXMovedNotification,
            kAXResizedNotification,
            kAXTitleChangedNotification
        ].forEach { notification in
            guard add(
                notification: notification,
                to: window,
                observedApplication: observedApplication
            ) else {
                return
            }
            notifications.insert(notification)
        }
        observedApplication.windowNotifications[hash] = notifications
    }

    private func add(
        notification: String,
        to element: AXUIElement,
        observedApplication: AccessibilityWindowInventoryObservedApplication
    ) -> Bool {
        let result = AXObserverAddNotification(
            observedApplication.observer,
            element,
            notification as CFString,
            Unmanaged.passUnretained(observedApplication.context).toOpaque()
        )
        return result == .success || result == .notificationAlreadyRegistered
    }

    private func removeNotifications(
        from observedApplication: AccessibilityWindowInventoryObservedApplication
    ) {
        observedApplication.applicationNotifications.forEach { notification in
            AXObserverRemoveNotification(
                observedApplication.observer,
                observedApplication.applicationElement,
                notification as CFString
            )
        }
        observedApplication.observedWindows.keys.forEach { hash in
            removeWindowNotifications(hash: hash, from: observedApplication)
        }
    }

    private func removeWindowNotifications(
        hash: CFHashCode,
        from observedApplication: AccessibilityWindowInventoryObservedApplication
    ) {
        guard let window = observedApplication.observedWindows.removeValue(forKey: hash) else {
            observedApplication.windowNotifications[hash] = nil
            return
        }
        let notifications = observedApplication.windowNotifications.removeValue(forKey: hash) ?? []
        notifications.forEach { notification in
            AXObserverRemoveNotification(
                observedApplication.observer,
                window,
                notification as CFString
            )
        }
    }

    private func axWindows(for applicationElement: AXUIElement) -> [AXUIElement] {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            applicationElement,
            kAXWindowsAttribute as CFString,
            &rawValue
        ) == .success else {
            return []
        }
        return rawValue as? [AXUIElement] ?? []
    }

    private func focusedWindowIdentity(
        in observedApplication: AccessibilityWindowInventoryObservedApplication
    ) -> PreviewWindowIdentity? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            observedApplication.applicationElement,
            kAXFocusedWindowAttribute as CFString,
            &rawValue
        ) == .success,
        let rawValue,
        CFGetTypeID(rawValue) == AXUIElementGetTypeID()
        else {
            return nil
        }
        let focusedWindow = rawValue as! AXUIElement
        return windowIdentity(
            for: focusedWindow,
            processIdentifier: observedApplication.processIdentifier
        )
    }

    private func windowIdentity(
        for element: AXUIElement,
        processIdentifier: pid_t
    ) -> PreviewWindowIdentity? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            "AXWindowNumber" as CFString,
            &rawValue
        ) == .success else {
            return nil
        }
        let value = (rawValue as? NSNumber)?.uint32Value
            ?? (rawValue as? UInt32)
        guard let value else {
            return nil
        }
        return .window(processIdentifier: processIdentifier, windowID: value)
    }
}

private let windowInventoryAXObserverCallback: AXObserverCallback = { _, element, notification, refcon in
    guard let refcon else {
        return
    }
    let context = Unmanaged<AccessibilityWindowInventoryObserverContext>
        .fromOpaque(refcon)
        .takeUnretainedValue()
    Task { @MainActor in
        context.backend?.handle(
            notification: notification as String,
            element: element,
            processIdentifier: context.processIdentifier
        )
    }
}

enum AccessibilityPreviewWindowReader {
    static func windows(for processIdentifier: pid_t, appName: String) -> [PreviewWindowInfo] {
        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            applicationElement,
            kAXWindowsAttribute as CFString,
            &rawValue
        ) == .success,
        let windows = rawValue as? [AXUIElement]
        else {
            return []
        }

        return windows.enumerated().compactMap { index, window in
            let role = stringAttribute(kAXRoleAttribute, from: window)
            let subrole = stringAttribute(kAXSubroleAttribute, from: window)
            let title = stringAttribute(kAXTitleAttribute, from: window)
            guard WindowFiltering.shouldIncludeAXPreviewWindow(
                role: role,
                subrole: subrole,
                title: title
            ) else {
                return nil
            }

            let windowID = intAttribute("AXWindowNumber", from: window).map(CGWindowID.init)
            let fallbackIdentifier = "ax-\(processIdentifier)-\(index)-\(title ?? appName)"
            return PreviewWindowInfo(
                id: windowID.map { "ax-\($0)" } ?? fallbackIdentifier,
                windowID: windowID,
                processIdentifier: processIdentifier,
                appName: appName,
                title: title ?? appName,
                frame: frame(from: window),
                isMinimized: boolAttribute(kAXMinimizedAttribute, from: window) ?? false
            )
        }
    }

    private static func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue) == .success else {
            return nil
        }
        return rawValue as? String
    }

    private static func intAttribute(_ attribute: String, from element: AXUIElement) -> Int? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue) == .success else {
            return nil
        }
        if let number = rawValue as? NSNumber {
            return number.intValue
        }
        return rawValue as? Int
    }

    private static func boolAttribute(_ attribute: String, from element: AXUIElement) -> Bool? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue) == .success else {
            return nil
        }
        return rawValue as? Bool
    }

    private static func frame(from element: AXUIElement) -> CGRect {
        let origin = pointAttribute(kAXPositionAttribute, from: element) ?? .zero
        let size = sizeAttribute(kAXSizeAttribute, from: element) ?? .zero
        return CGRect(origin: origin, size: size)
    }

    private static func pointAttribute(_ attribute: String, from element: AXUIElement) -> CGPoint? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue) == .success,
              let rawValue,
              CFGetTypeID(rawValue) == AXValueGetTypeID()
        else {
            return nil
        }

        let value = rawValue as! AXValue
        var point = CGPoint.zero
        guard AXValueGetValue(value, .cgPoint, &point) else {
            return nil
        }
        return point
    }

    private static func sizeAttribute(_ attribute: String, from element: AXUIElement) -> CGSize? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &rawValue) == .success,
              let rawValue,
              CFGetTypeID(rawValue) == AXValueGetTypeID()
        else {
            return nil
        }

        let value = rawValue as! AXValue
        var size = CGSize.zero
        guard AXValueGetValue(value, .cgSize, &size) else {
            return nil
        }
        return size
    }
}

enum WindowInventorySwitcherSnapshotPolicy {
    static func merge(
        accessibilityWindows: [PreviewWindowInfo],
        windowServerWindows: [PreviewWindowInfo]
    ) -> [PreviewWindowInfo] {
        // A WindowServer surface alone can outlive its AX window. Require a live AX
        // record before accepting it into the user-facing switcher.
        guard !accessibilityWindows.isEmpty else {
            return []
        }
        let verifiedWindowServerWindows = PreviewWindowCatalog.reconcileCaptureCandidates(
            axWindows: accessibilityWindows,
            candidates: windowServerWindows.map {
                PreviewCaptureWindowCandidate(info: $0, isOnScreen: false)
            }
        ).map(\.info)
        guard !verifiedWindowServerWindows.isEmpty else {
            return PreviewWindowCatalog.stableDisplayOrder(
                PreviewWindowCatalog.collapseTabbedWindows(accessibilityWindows)
            )
        }

        let verifiedIdentities = Set(verifiedWindowServerWindows.map(PreviewWindowIdentity.init))
        let minimizedAccessibilityWindows = accessibilityWindows.filter { window in
            window.isMinimized && !verifiedIdentities.contains(PreviewWindowIdentity(window))
        }
        return PreviewWindowCatalog.stableDisplayOrder(
            distinctByStableIdentity(verifiedWindowServerWindows + minimizedAccessibilityWindows)
        )
    }

    private static func distinctByStableIdentity(_ windows: [PreviewWindowInfo]) -> [PreviewWindowInfo] {
        var seen = Set<PreviewWindowIdentity>()
        return windows.filter { window in
            seen.insert(PreviewWindowIdentity(window)).inserted
        }
    }
}

@MainActor
final class WindowInventoryService {
    private struct CachedSnapshot {
        let snapshot: PreviewWindowSnapshot
        let seededAt: Date
    }

    private var state = WindowInventoryState()
    private var cachedSnapshots: [pid_t: CachedSnapshot] = [:]
    private var nextRevision: UInt64 = 0
    private var pendingInvalidations: [pid_t: DispatchWorkItem] = [:]
    private var snapshotCleanupWorkItem: DispatchWorkItem?
    private var changeObservers: [UUID: (WindowInventoryEvent) -> Void] = [:]
    private lazy var workspaceBackend = WorkspaceWindowInventoryEventBackend()
    private lazy var accessibilityBackend = AccessibilityWindowInventoryEventBackend(
        isAccessibilityTrusted: { AXIsProcessTrusted() }
    )

    func start() {
        configureBackends()
        workspaceBackend.start()
        accessibilityBackend.start()
        state.processIdentifiers.forEach { processIdentifier in
            accessibilityBackend.track(processIdentifier: processIdentifier)
        }
    }

    func stop() {
        pendingInvalidations.values.forEach { $0.cancel() }
        pendingInvalidations.removeAll()
        snapshotCleanupWorkItem?.cancel()
        snapshotCleanupWorkItem = nil
        accessibilityBackend.stop()
        workspaceBackend.stop()
        cachedSnapshots.removeAll()
        changeObservers.removeAll()
        state = WindowInventoryState()
    }

    @discardableResult
    func observeChanges(_ observer: @escaping (WindowInventoryEvent) -> Void) -> UUID {
        let identifier = UUID()
        changeObservers[identifier] = observer
        return identifier
    }

    func removeChangeObserver(_ identifier: UUID) {
        changeObservers[identifier] = nil
    }

    func refreshAccessibilityTracking() {
        accessibilityBackend.refreshAccessibilityState()
        state.processIdentifiers.forEach { processIdentifier in
            accessibilityBackend.track(processIdentifier: processIdentifier)
        }
    }

    func previewSnapshot(for target: DockAppTarget, now: Date = Date()) -> PreviewWindowSnapshot? {
        guard let cached = cachedSnapshots[target.processIdentifier],
              WindowInventorySnapshotReusePolicy.shouldReuse(
                seededAt: cached.seededAt,
                isStale: state.isStale(processIdentifier: target.processIdentifier),
                now: now
              )
        else {
            cachedSnapshots[target.processIdentifier] = nil
            return nil
        }
        return cached.snapshot
    }

    func beginSnapshotRequest(for target: DockAppTarget) -> UInt64 {
        nextRevision &+= 1
        return nextRevision
    }

    func seed(
        _ snapshot: PreviewWindowSnapshot,
        for target: DockAppTarget,
        requestRevision: UInt64? = nil,
        now: Date = Date()
    ) {
        let revision = requestRevision ?? beginSnapshotRequest(for: target)
        let records = snapshot.windows.enumerated().map { index, window in
            WindowInventoryRecord(window, displayOrder: index)
        }
        guard apply(
            .seed(
                processIdentifier: target.processIdentifier,
                revision: revision,
                records: records
            )
        ) else {
            return
        }
        if snapshot.message == nil {
            cachedSnapshots[target.processIdentifier] = CachedSnapshot(
                snapshot: snapshot,
                seededAt: now
            )
            scheduleSnapshotCleanup()
        } else {
            cachedSnapshots[target.processIdentifier] = nil
        }
        accessibilityBackend.track(processIdentifier: target.processIdentifier)
    }

    func remove(_ window: PreviewWindowInfo) {
        guard apply(.windowRemoved(PreviewWindowIdentity(window))) else {
            return
        }
        invalidate(processIdentifier: window.processIdentifier, reason: .destroyed)
    }

    func remove(processIdentifier: pid_t) {
        cachedSnapshots[processIdentifier] = nil
        pendingInvalidations.removeValue(forKey: processIdentifier)?.cancel()
        _ = apply(.processTerminated(processIdentifier: processIdentifier))
        accessibilityBackend.untrack(processIdentifier: processIdentifier)
    }

    func windows(for processIdentifier: pid_t) -> [WindowInventoryRecord] {
        guard !state.isStale(processIdentifier: processIdentifier) else {
            return []
        }
        return state.records(for: processIdentifier)
    }

    func allWindows() -> [WindowInventoryRecord] {
        state.allRecordsByMostRecentFocus().filter {
            !state.isStale(processIdentifier: $0.processIdentifier)
        }
    }

    // This is an on-demand public API reconciliation for the independent window
    // switcher. AX establishes that a window is still interactive; WindowServer
    // metadata only supplements stable IDs and geometry. It never starts capture.
    func reconcileSwitcherWindows() -> [WindowInventoryRecord] {
        let windowServerWindows = windowServerWindowsByProcess()
        let runningApplications = NSWorkspace.shared.runningApplications.filter { application in
            application.activationPolicy == .regular
                && !application.isTerminated
                && DockTargetOwnershipPolicy.shouldHandle(
                    targetProcessIdentifier: application.processIdentifier
                )
        }
        let processIdentifiers = Set(runningApplications.map(\.processIdentifier))
            .union(windowServerWindows.keys)
            .union(state.processIdentifiers)

        for processIdentifier in processIdentifiers {
            let application = NSRunningApplication(processIdentifier: processIdentifier)
            let appName = application?.localizedName ?? AppStrings.text(.genericApplication)
            let accessibilityWindows = AccessibilityPreviewWindowReader.windows(
                for: processIdentifier,
                appName: appName
            )
            let mergedWindows = WindowInventorySwitcherSnapshotPolicy.merge(
                accessibilityWindows: accessibilityWindows,
                windowServerWindows: windowServerWindows[processIdentifier, default: []]
            )
            let records = mergedWindows.enumerated().map { index, window in
                WindowInventoryRecord(window, displayOrder: index)
            }

            nextRevision &+= 1
            guard apply(.seed(
                processIdentifier: processIdentifier,
                revision: nextRevision,
                records: records
            )) else {
                continue
            }
            if !records.isEmpty {
                accessibilityBackend.track(processIdentifier: processIdentifier)
            }
        }
        return allWindows()
    }

    private func windowServerWindowsByProcess() -> [pid_t: [PreviewWindowInfo]] {
        guard let rawWindows = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return [:]
        }

        var windowsByProcess: [pid_t: [PreviewWindowInfo]] = [:]
        for (displayOrder, rawWindow) in rawWindows.enumerated() {
            guard let rawProcessIdentifier = CGWindowDictionary.intValue(kCGWindowOwnerPID, from: rawWindow),
                  rawProcessIdentifier > 0,
                  let rawWindowID = CGWindowDictionary.intValue(kCGWindowNumber, from: rawWindow),
                  let layer = CGWindowDictionary.intValue(kCGWindowLayer, from: rawWindow)
            else {
                continue
            }

            let processIdentifier = pid_t(rawProcessIdentifier)
            guard DockTargetOwnershipPolicy.shouldHandle(targetProcessIdentifier: processIdentifier) else {
                continue
            }

            let frame = CGWindowDictionary.frame(from: rawWindow)
            guard WindowFiltering.hasNormalWindowGeometry(layer: layer, frame: frame),
                  let application = NSRunningApplication(processIdentifier: processIdentifier)
            else {
                continue
            }

            let appName = application.localizedName
                ?? CGWindowDictionary.stringValue(kCGWindowOwnerName, from: rawWindow)
                ?? AppStrings.text(.genericApplication)
            let title = CGWindowDictionary.stringValue(kCGWindowName, from: rawWindow)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedTitle = (title?.isEmpty == false ? title : nil) ?? appName
            let windowID = CGWindowID(rawWindowID)
            windowsByProcess[processIdentifier, default: []].append(PreviewWindowInfo(
                id: "cg-\(windowID)-\(displayOrder)",
                windowID: windowID,
                processIdentifier: processIdentifier,
                appName: appName,
                title: resolvedTitle,
                frame: frame,
                isMinimized: false
            ))
        }
        return windowsByProcess
    }

    private func configureBackends() {
        workspaceBackend.onEvent = { [weak self] event in
            self?.receive(event)
        }
        accessibilityBackend.onEvent = { [weak self] event in
            self?.receive(event)
        }
    }

    private func receive(_ event: WindowInventoryEvent) {
        switch event {
        case let .processLaunched(processIdentifier):
            cachedSnapshots[processIdentifier] = nil
            pendingInvalidations.removeValue(forKey: processIdentifier)?.cancel()
            _ = apply(.processLaunched(processIdentifier: processIdentifier))
            accessibilityBackend.untrack(processIdentifier: processIdentifier)
        case let .processInvalidated(processIdentifier, reason):
            enqueueInvalidation(processIdentifier: processIdentifier, reason: reason)
        case let .processActivated(processIdentifier):
            _ = apply(.processActivated(processIdentifier: processIdentifier))
        case let .windowFocused(identity):
            _ = apply(.windowFocused(identity))
        case let .processTerminated(processIdentifier):
            remove(processIdentifier: processIdentifier)
        case .activeSpaceChanged:
            _ = apply(.activeSpaceChanged)
            cachedSnapshots.removeAll()
            snapshotCleanupWorkItem?.cancel()
            snapshotCleanupWorkItem = nil
        case .seed, .windowRemoved:
            _ = apply(event)
        }
    }

    private func enqueueInvalidation(
        processIdentifier: pid_t,
        reason: WindowInventoryInvalidation
    ) {
        pendingInvalidations.removeValue(forKey: processIdentifier)?.cancel()
        let apply = { [weak self] in
            guard let self else {
                return
            }
            self.pendingInvalidations[processIdentifier] = nil
            _ = self.apply(
                .processInvalidated(processIdentifier: processIdentifier, reason: reason)
            )
            self.cachedSnapshots[processIdentifier] = nil
        }
        let delay = WindowInventoryEventCoalescingPolicy.delay(for: reason)
        guard delay > 0 else {
            apply()
            return
        }
        let workItem = DispatchWorkItem(block: apply)
        pendingInvalidations[processIdentifier] = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func invalidate(processIdentifier: pid_t, reason: WindowInventoryInvalidation) {
        enqueueInvalidation(processIdentifier: processIdentifier, reason: reason)
    }

    @discardableResult
    private func apply(_ event: WindowInventoryEvent) -> Bool {
        guard state.apply(event) else {
            return false
        }
        let observers = Array(changeObservers.values)
        observers.forEach { observer in
            observer(event)
        }
        return true
    }

    private func scheduleSnapshotCleanup() {
        snapshotCleanupWorkItem?.cancel()
        guard let nextExpiry = cachedSnapshots.values.map({
            $0.seededAt.addingTimeInterval(WindowInventorySnapshotReusePolicy.maximumAge)
        }).min() else {
            snapshotCleanupWorkItem = nil
            return
        }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }
            self.snapshotCleanupWorkItem = nil
            let now = Date()
            self.cachedSnapshots = self.cachedSnapshots.filter { processIdentifier, cached in
                WindowInventorySnapshotReusePolicy.shouldReuse(
                    seededAt: cached.seededAt,
                    isStale: self.state.isStale(processIdentifier: processIdentifier),
                    now: now
                )
            }
            self.scheduleSnapshotCleanup()
        }
        snapshotCleanupWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + max(0, nextExpiry.timeIntervalSinceNow),
            execute: workItem
        )
    }
}
