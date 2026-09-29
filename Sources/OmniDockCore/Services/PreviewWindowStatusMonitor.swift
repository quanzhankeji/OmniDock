import AppKit

@MainActor
final class PreviewWindowStatusMonitor {
    var onChange: (([PreviewWindowInfo]) -> Void)?

    private let inventory: WindowInventoryService
    private let readWindows: (pid_t, String) -> [PreviewWindowInfo]
    private var observer: UUID?
    private var windows: [PreviewWindowInfo] = []
    private var observedStates: [PreviewWindowIdentity: PreviewWindowInfo] = [:]
    private var pendingProcesses: Set<pid_t> = []
    private var refreshWorkItem: DispatchWorkItem?
    private var generation: UInt64 = 0

    init(
        inventory: WindowInventoryService,
        readWindows: @escaping (pid_t, String) -> [PreviewWindowInfo] = {
            AccessibilityPreviewWindowReader.windows(for: $0, appName: $1)
        }
    ) {
        self.inventory = inventory
        self.readWindows = readWindows
    }

    deinit {
        refreshWorkItem?.cancel()
        if let observer {
            Task { @MainActor [inventory] in inventory.removeChangeObserver(observer) }
        }
    }

    func updateWindows(_ replacement: [PreviewWindowInfo]) -> [PreviewWindowInfo] {
        guard !replacement.isEmpty else {
            stop()
            return []
        }
        let identities = Set(replacement.map(PreviewWindowIdentity.init))
        observedStates = observedStates.filter { identity, state in
            identities.contains(identity)
                && PreviewWindowCatalog.matchingAccessibilityWindow(for: state, in: replacement)
                    .map(PreviewWindowIdentity.init) == identity
        }
        windows = replacement.map(applyingObservedState)
        if observer == nil {
            observer = inventory.observeChanges { [weak self] in self?.receive($0) }
        }
        return windows
    }

    func stop() {
        generation &+= 1
        refreshWorkItem?.cancel()
        refreshWorkItem = nil
        pendingProcesses.removeAll()
        if let observer { inventory.removeChangeObserver(observer) }
        observer = nil
        windows.removeAll()
        observedStates.removeAll()
    }

    private func receive(_ event: WindowInventoryEvent) {
        let visibleProcesses = Set(windows.map(\.processIdentifier))
        switch event {
        case let .processInvalidated(pid, _):
            guard visibleProcesses.contains(pid) else { return }
            pendingProcesses.insert(pid)
        case .activeSpaceChanged, .displayConfigurationChanged:
            pendingProcesses.formUnion(visibleProcesses)
        case let .processLaunched(pid), let .processTerminated(pid):
            observedStates = observedStates.filter { $0.key.processIdentifier != pid }
            pendingProcesses.remove(pid)
            return
        case .seed, .processActivated, .windowFocused, .windowRemoved:
            return
        }
        guard refreshWorkItem == nil, !pendingProcesses.isEmpty else { return }
        let requestGeneration = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == requestGeneration else { return }
            self.refreshWorkItem = nil
            let processes = self.pendingProcesses
            self.pendingProcesses.removeAll()
            self.refresh(processes: processes)
        }
        refreshWorkItem = work
        DispatchQueue.main.async(execute: work)
    }

    private func refresh(processes: Set<pid_t>) {
        for pid in processes {
            let visibleWindows = windows.filter { $0.processIdentifier == pid }
            guard let first = visibleWindows.first else { continue }
            let current = readWindows(pid, first.appName)
            for window in visibleWindows {
                let identity = PreviewWindowIdentity(window)
                guard let state = PreviewWindowCatalog.matchingAccessibilityWindow(for: window, in: current),
                      PreviewWindowCatalog.matchingAccessibilityWindow(for: state, in: visibleWindows)
                        .map(PreviewWindowIdentity.init) == identity
                else {
                    observedStates[identity] = nil
                    continue
                }
                observedStates[identity] = state
            }
        }
        let refreshed = windows.map(applyingObservedState)
        guard refreshed.map(PreviewWindowPresentation.init) != windows.map(PreviewWindowPresentation.init) else { return }
        windows = refreshed
        onChange?(refreshed)
    }

    private func applyingObservedState(to window: PreviewWindowInfo) -> PreviewWindowInfo {
        guard let state = observedStates[PreviewWindowIdentity(window)],
              PreviewWindowCatalog.matchingAccessibilityWindow(for: window, in: [state]) != nil
        else { return window }
        let placeholder: String?
        switch window.placeholderText {
        case AppStrings.text(.previewMetadataOnly), AppStrings.text(.previewMinimizedClickRestore):
            placeholder = AppStrings.text(state.isMinimized ? .previewMinimizedClickRestore : .previewMetadataOnly)
        default:
            placeholder = window.placeholderText
        }
        // Keep capture images, order and identity intact when an AX event supplies
        // newer state than an in-flight thumbnail or inventory response.
        return PreviewWindowInfo(
            id: window.id, windowID: window.windowID, processIdentifier: window.processIdentifier,
            appName: window.appName, title: window.title, frame: state.frame,
            isMinimized: state.isMinimized, isApplicationHidden: state.isApplicationHidden,
            isFullScreen: state.isFullScreen, staticPreviewImage: window.staticPreviewImage,
            placeholderText: placeholder
        )
    }
}
