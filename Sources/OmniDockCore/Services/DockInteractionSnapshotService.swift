import CoreGraphics
import Darwin
import Foundation

enum DockInteractionClock {
    private static let timebase: mach_timebase_info_data_t = {
        var value = mach_timebase_info_data_t()
        mach_timebase_info(&value)
        return value
    }()

    static func now() -> TimeInterval {
        let ticks = mach_continuous_time()
        let nanoseconds = Double(ticks) * Double(timebase.numer) / Double(timebase.denom)
        return nanoseconds / 1_000_000_000
    }
}

struct DockInteractionEvaluatedTarget {
    let target: DockAppTarget
    let shouldHandle: Bool
}

struct DockInteractionHotTargetSnapshot: Equatable {
    let target: DockAppTarget
    let eventTapFrame: CGRect
    let shouldHandle: Bool
    let refreshedAt: TimeInterval
    let inventoryRefreshedAt: TimeInterval
}

struct DockInteractionSnapshotPublication: Equatable {
    let generation: UInt64
    let hotTarget: DockInteractionHotTargetSnapshot?
}

final class DockInteractionSnapshotStore {
    private let lock = NSLock()
    private let publicationHandler: ((DockInteractionSnapshotPublication) -> Void)?
    private var publication = DockInteractionSnapshotPublication(generation: 0, hotTarget: nil)

    init(publicationHandler: ((DockInteractionSnapshotPublication) -> Void)? = nil) {
        self.publicationHandler = publicationHandler
    }

    @discardableResult
    func publish(_ candidate: DockInteractionSnapshotPublication) -> Bool {
        lock.lock()
        guard candidate.generation >= publication.generation else {
            lock.unlock()
            return false
        }
        publication = candidate
        lock.unlock()
        publicationHandler?(candidate)
        return true
    }

    func target(atEventTapPoint point: CGPoint, now: TimeInterval) -> DockClickGestureTarget? {
        guard lock.try() else {
            return nil
        }
        let snapshot = publication.hotTarget
        lock.unlock()

        guard let snapshot,
              snapshot.shouldHandle,
              snapshot.eventTapFrame.contains(point),
              isFresh(now: now, refreshedAt: snapshot.refreshedAt, ttl: DockInteractionSnapshotService.hotTargetTTL),
              isFresh(
                now: now,
                refreshedAt: snapshot.inventoryRefreshedAt,
                ttl: DockInteractionSnapshotService.inventoryTTL
              )
        else {
            return nil
        }
        return DockClickGestureTarget(target: snapshot.target)
    }

    func removeAll(generation: UInt64) {
        _ = publish(DockInteractionSnapshotPublication(generation: generation, hotTarget: nil))
    }

    func currentPublication() -> DockInteractionSnapshotPublication {
        lock.lock()
        defer { lock.unlock() }
        return publication
    }

    private func isFresh(now: TimeInterval, refreshedAt: TimeInterval, ttl: TimeInterval) -> Bool {
        let age = now - refreshedAt
        return age >= 0 && age <= ttl
    }
}

private final class DockInteractionTargetEvaluator {
    private let windowControlService: WindowControlService
    private let currentProcessIdentifier: pid_t
    private let proxyTargetRouter: DockProxyTargetRouter

    init(
        windowControlService: WindowControlService,
        currentProcessIdentifier: pid_t,
        proxyOwnerStore: DockProxyOwnerStore
    ) {
        self.windowControlService = windowControlService
        self.currentProcessIdentifier = currentProcessIdentifier
        self.proxyTargetRouter = DockProxyTargetRouter(ownerStore: proxyOwnerStore)
    }

    func evaluate(
        _ originalTarget: DockAppTarget,
        applications: DockApplicationInventory
    ) -> DockInteractionEvaluatedTarget {
        guard DockTargetOwnershipPolicy.shouldHandle(
            targetProcessIdentifier: originalTarget.processIdentifier,
            currentProcessIdentifier: currentProcessIdentifier
        ), let originalApplication = applications.application(
            processIdentifier: originalTarget.processIdentifier
        ) else {
            return DockInteractionEvaluatedTarget(
                target: originalTarget,
                shouldHandle: false
            )
        }

        let windows = DockProxyTargetResolver.currentWindowInfos()
        let originalSummary = windowControlService.interactionSummary(
            for: originalTarget.processIdentifier
        )
        if originalSummary.normalWindowCount > 0
            || originalSummary.onscreenNormalWindowCount > 0
            || ownsValidWindow(originalTarget.processIdentifier, in: windows) {
            proxyTargetRouter.removeRememberedOwner(for: originalTarget)
            return evaluatedTarget(
                originalTarget,
                application: originalApplication,
                summary: originalSummary
            )
        }

        let resolution = proxyTargetRouter.resolution(
            for: originalTarget,
            windows: windows,
            runningApplication: { processIdentifier in
                guard let application = applications.application(
                    processIdentifier: processIdentifier
                ) else {
                    return nil
                }
                return DockProxyApplicationInfo(
                    processIdentifier: application.processIdentifier,
                    bundleIdentifier: application.bundleIdentifier,
                    localizedName: application.localizedName
                )
            }
        )
        let target = resolution.target
        guard DockTargetOwnershipPolicy.shouldHandle(
            targetProcessIdentifier: target.processIdentifier,
            currentProcessIdentifier: currentProcessIdentifier
        ), resolution.proxyOwnerProcessIdentifier != nil,
           let application = applications.application(
            processIdentifier: target.processIdentifier
           ) else {
            return DockInteractionEvaluatedTarget(
                target: target,
                shouldHandle: false
            )
        }

        let summary = windowControlService.interactionSummary(for: target.processIdentifier)
        return evaluatedTarget(target, application: application, summary: summary)
    }

    private func evaluatedTarget(
        _ target: DockAppTarget,
        application: DockRunningApplicationInventoryItem,
        summary: WindowInteractionSummary
    ) -> DockInteractionEvaluatedTarget {
        return DockInteractionEvaluatedTarget(
            target: target,
            shouldHandle: WindowFiltering.shouldHandleRunningDockClick(
                isHidden: application.isHidden,
                normalWindowCount: summary.normalWindowCount,
                onscreenNormalWindowCount: summary.onscreenNormalWindowCount
            )
        )
    }

    private func ownsValidWindow(
        _ processIdentifier: pid_t,
        in windows: [DockProxyWindowInfo]
    ) -> Bool {
        windows.contains { window in
            window.processIdentifier == processIdentifier
                && WindowFiltering.shouldIncludeShareableWindow(
                    layer: window.layer,
                    isOnScreen: window.isOnScreen,
                    frame: window.frame
                )
        }
    }

    func reset() {
        proxyTargetRouter.removeAll()
    }
}

final class DockInteractionSnapshotService {
    static let hotTargetTTL: TimeInterval = 0.25
    static let inventoryTTL: TimeInterval = 1.0
    private static let inventoryRefreshAge: TimeInterval = 0.8
    private static let timerInterval: TimeInterval = 0.08

    typealias InventoryProvider = () -> [DockHitTestInventoryItem]
    typealias TargetEvaluator = (DockAppTarget) -> DockInteractionEvaluatedTarget
    typealias SystemInventoryProvider = () -> DockInteractionSystemInventory
    typealias BackgroundInventoryProvider = (
        DockInteractionSystemInventory
    ) -> [DockHitTestInventoryItem]
    typealias InventoryTargetEvaluator = (
        DockAppTarget,
        DockApplicationInventory
    ) -> DockInteractionEvaluatedTarget
    typealias PointerLocationProvider = () -> CGPoint?

    let snapshotStore: DockInteractionSnapshotStore

    private struct Inventory {
        let items: [DockHitTestInventoryItem]
        let applications: DockApplicationInventory
        let refreshedAt: TimeInterval
    }

    private struct RefreshRequest {
        let generation: UInt64
        let session: UInt64
        let eventTapPoint: CGPoint
    }

    private struct RequestState {
        var isRunning = false
        var session: UInt64 = 0
        var latestGeneration: UInt64 = 0
        var latestRequest: RefreshRequest?
        var isDrainScheduled = false
    }

    private let queue = DispatchQueue(
        label: "com.omnidock.dock-interaction-snapshots",
        qos: .userInteractive
    )
    private let requestLock = NSLock()
    private let systemInventoryProvider: SystemInventoryProvider
    private let inventoryProvider: BackgroundInventoryProvider
    private let targetEvaluator: InventoryTargetEvaluator
    private let resetEvaluator: () -> Void
    private let pointerLocationProvider: PointerLocationProvider
    private let clock: () -> TimeInterval

    private var requestState = RequestState()
    private var inventory: Inventory?
    private var pendingInventoryRefreshSession: UInt64?
    private var timer: DispatchSourceTimer?

    convenience init(
        dockHitTester: DockHitTester,
        windowControlService: WindowControlService,
        currentProcessIdentifier: pid_t = getpid(),
        proxyOwnerStore: DockProxyOwnerStore? = nil
    ) {
        let ownsProxyOwnerStore = proxyOwnerStore == nil
        let proxyOwnerStore = proxyOwnerStore ?? DockProxyOwnerStore()
        let evaluator = DockInteractionTargetEvaluator(
            windowControlService: windowControlService,
            currentProcessIdentifier: currentProcessIdentifier,
            proxyOwnerStore: proxyOwnerStore
        )
        self.init(
            systemInventoryProvider: {
                dockHitTester.captureSystemInventory()
            },
            inventoryProvider: { systemInventory in
                dockHitTester.interactionInventory(using: systemInventory)
            },
            targetEvaluator: { target, applications in
                evaluator.evaluate(target, applications: applications)
            },
            resetEvaluator: ownsProxyOwnerStore ? evaluator.reset : {}
        )
    }

    convenience init(
        dockHitTester: DockHitTester,
        shouldHandleTarget: @escaping (DockAppTarget) -> Bool
    ) {
        self.init(
            systemInventoryProvider: {
                dockHitTester.captureSystemInventory()
            },
            inventoryProvider: { systemInventory in
                dockHitTester.interactionInventory(using: systemInventory)
            },
            targetEvaluator: { target, _ in
                DockInteractionEvaluatedTarget(
                    target: target,
                    shouldHandle: shouldHandleTarget(target)
                )
            }
        )
    }

    convenience init(
        snapshotStore: DockInteractionSnapshotStore = DockInteractionSnapshotStore(),
        inventoryProvider: @escaping InventoryProvider,
        targetEvaluator: @escaping TargetEvaluator,
        resetEvaluator: @escaping () -> Void = {},
        pointerLocationProvider: @escaping PointerLocationProvider = {
            CGEvent(source: nil)?.location
        },
        clock: @escaping () -> TimeInterval = DockInteractionClock.now
    ) {
        self.init(
            snapshotStore: snapshotStore,
            systemInventoryProvider: { .empty },
            inventoryProvider: { _ in inventoryProvider() },
            targetEvaluator: { target, _ in targetEvaluator(target) },
            resetEvaluator: resetEvaluator,
            pointerLocationProvider: pointerLocationProvider,
            clock: clock
        )
    }

    init(
        snapshotStore: DockInteractionSnapshotStore = DockInteractionSnapshotStore(),
        systemInventoryProvider: @escaping SystemInventoryProvider,
        inventoryProvider: @escaping BackgroundInventoryProvider,
        targetEvaluator: @escaping InventoryTargetEvaluator,
        resetEvaluator: @escaping () -> Void = {},
        pointerLocationProvider: @escaping PointerLocationProvider = {
            CGEvent(source: nil)?.location
        },
        clock: @escaping () -> TimeInterval = DockInteractionClock.now
    ) {
        self.snapshotStore = snapshotStore
        self.systemInventoryProvider = systemInventoryProvider
        self.inventoryProvider = inventoryProvider
        self.targetEvaluator = targetEvaluator
        self.resetEvaluator = resetEvaluator
        self.pointerLocationProvider = pointerLocationProvider
        self.clock = clock
    }

    deinit {
        stop()
    }

    func start() {
        requestLock.lock()
        guard !requestState.isRunning else {
            requestLock.unlock()
            return
        }
        requestState.isRunning = true
        requestState.session &+= 1
        let session = requestState.session
        requestState.latestGeneration &+= 1
        requestLock.unlock()

        let initialSystemInventory = Thread.isMainThread ? systemInventoryProvider() : nil
        queue.async { [weak self] in
            guard let self, self.isRunning(session: session) else {
                return
            }
            self.startTimer(session: session)
            if let initialSystemInventory {
                _ = self.rebuildInventory(
                    using: initialSystemInventory,
                    session: session
                )
            } else {
                self.requestInventoryRefreshIfNeeded(
                    now: self.clock(),
                    force: true,
                    session: session
                )
            }
            if let point = self.pointerLocationProvider() {
                self.updateEventTapPointerLocation(point)
            }
        }
    }

    func stop() {
        requestLock.lock()
        requestState.isRunning = false
        requestState.session &+= 1
        requestState.latestGeneration &+= 1
        let clearingGeneration = requestState.latestGeneration
        requestState.latestRequest = nil
        requestState.isDrainScheduled = false
        requestLock.unlock()

        snapshotStore.removeAll(generation: clearingGeneration)
        queue.async { [weak self] in
            guard let self else {
                return
            }
            self.timer?.cancel()
            self.timer = nil
            self.inventory = nil
            self.pendingInventoryRefreshSession = nil
            self.resetEvaluator()
        }
    }

    private func updateEventTapPointerLocation(_ eventTapPoint: CGPoint) {
        requestLock.lock()
        guard requestState.isRunning else {
            requestLock.unlock()
            return
        }
        requestState.latestGeneration &+= 1
        let request = RefreshRequest(
            generation: requestState.latestGeneration,
            session: requestState.session,
            eventTapPoint: eventTapPoint
        )
        requestState.latestRequest = request
        let shouldScheduleDrain = !requestState.isDrainScheduled
        requestState.isDrainScheduled = true
        requestLock.unlock()

        if shouldScheduleDrain {
            queue.async { [weak self] in
                self?.drainRefreshRequests()
            }
        }
    }

    private func startTimer(session: UInt64) {
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + Self.timerInterval,
            repeating: Self.timerInterval,
            leeway: .milliseconds(20)
        )
        timer.setEventHandler { [weak self] in
            self?.handleTimer(session: session)
        }
        self.timer = timer
        timer.resume()
    }

    private func handleTimer(session: UInt64) {
        guard isRunning(session: session) else {
            return
        }

        requestInventoryRefreshIfNeeded(
            now: clock(),
            force: false,
            session: session
        )
        if let point = pointerLocationProvider() {
            updateEventTapPointerLocation(point)
        }
    }

    private func drainRefreshRequests() {
        while let request = takeLatestRequest() {
            refresh(request)
        }
    }

    private func takeLatestRequest() -> RefreshRequest? {
        requestLock.lock()
        defer { requestLock.unlock() }
        guard requestState.isRunning else {
            requestState.isDrainScheduled = false
            return nil
        }
        guard let requestStateLatestRequest = requestState.latestRequest else {
            requestState.isDrainScheduled = false
            return nil
        }
        requestState.latestRequest = nil
        return requestStateLatestRequest
    }

    private func refresh(_ request: RefreshRequest) {
        guard isRunning(session: request.session) else {
            return
        }

        let now = clock()
        requestInventoryRefreshIfNeeded(
            now: now,
            force: false,
            session: request.session
        )
        let currentInventory = inventory
        let matchingItems = currentInventory?.items.filter { item in
            item.eventTapFrame.contains(request.eventTapPoint)
        } ?? []

        let hotTarget: DockInteractionHotTargetSnapshot?
        if matchingItems.count == 1,
           let item = matchingItems.first,
           let currentInventory {
            let evaluation = targetEvaluator(
                item.target,
                currentInventory.applications
            )
            hotTarget = DockInteractionHotTargetSnapshot(
                target: evaluation.target,
                eventTapFrame: item.eventTapFrame,
                shouldHandle: evaluation.shouldHandle,
                refreshedAt: clock(),
                inventoryRefreshedAt: currentInventory.refreshedAt
            )
        } else {
            hotTarget = nil
        }

        guard isLatest(request) else {
            return
        }
        snapshotStore.publish(DockInteractionSnapshotPublication(
            generation: request.generation,
            hotTarget: hotTarget
        ))
    }

    private func requestInventoryRefreshIfNeeded(
        now: TimeInterval,
        force: Bool,
        session: UInt64
    ) {
        guard isRunning(session: session),
              pendingInventoryRefreshSession != session
        else {
            return
        }
        if !force,
           let inventory,
           now - inventory.refreshedAt < Self.inventoryRefreshAge {
            return
        }
        pendingInventoryRefreshSession = session

        DispatchQueue.main.async { [weak self] in
            guard let self, self.isRunning(session: session) else {
                return
            }
            let systemInventory = self.systemInventoryProvider()
            self.queue.async { [weak self] in
                guard let self else {
                    return
                }
                if self.pendingInventoryRefreshSession == session {
                    self.pendingInventoryRefreshSession = nil
                }
                guard self.rebuildInventory(
                    using: systemInventory,
                    session: session
                ) else {
                    return
                }
                if let point = self.pointerLocationProvider() {
                    self.updateEventTapPointerLocation(point)
                }
            }
        }
    }

    @discardableResult
    private func rebuildInventory(
        using systemInventory: DockInteractionSystemInventory,
        session: UInt64
    ) -> Bool {
        guard isRunning(session: session) else {
            return false
        }
        let items = inventoryProvider(systemInventory)
        guard isRunning(session: session) else {
            return false
        }
        inventory = Inventory(
            items: items,
            applications: systemInventory.applications,
            refreshedAt: clock()
        )
        return true
    }

    private func isRunning(session: UInt64) -> Bool {
        requestLock.lock()
        defer { requestLock.unlock() }
        return requestState.isRunning && requestState.session == session
    }

    private func isLatest(_ request: RefreshRequest) -> Bool {
        requestLock.lock()
        defer { requestLock.unlock() }
        return requestState.isRunning
            && requestState.session == request.session
            && requestState.latestGeneration == request.generation
    }
}
