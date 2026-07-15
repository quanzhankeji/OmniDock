import AppKit

enum ApplicationPresentationSurface: Hashable {
    case settings
    case permissionOnboarding
}

@MainActor
final class ApplicationPresentationCoordinator {
    typealias ActivationPolicySetter = @MainActor (NSApplication.ActivationPolicy) -> Bool
    typealias ApplicationActivator = @MainActor () -> Void
    typealias DeferredAction = @MainActor () -> Void
    typealias DeferredScheduler = @MainActor (@escaping DeferredAction) -> Void

    private let setActivationPolicy: ActivationPolicySetter
    private let activateApplication: ApplicationActivator
    private let scheduleDeferred: DeferredScheduler

    private var activeSurfaces: Set<ApplicationPresentationSurface> = []
    private var transitionGeneration = 0
    private var isRegularPresentationRequested = false

    init(
        setActivationPolicy: @escaping ActivationPolicySetter = { NSApp.setActivationPolicy($0) },
        activateApplication: @escaping ApplicationActivator = {
            NSApp.activate(ignoringOtherApps: true)
        },
        scheduleDeferred: @escaping DeferredScheduler = { action in
            DispatchQueue.main.async {
                action()
            }
        }
    ) {
        self.setActivationPolicy = setActivationPolicy
        self.activateApplication = activateApplication
        self.scheduleDeferred = scheduleDeferred
    }

    func present(_ surface: ApplicationPresentationSurface) {
        let wasEmpty = activeSurfaces.isEmpty
        let inserted = activeSurfaces.insert(surface).inserted
        if inserted {
            transitionGeneration &+= 1
        }

        if wasEmpty, inserted, !isRegularPresentationRequested {
            isRegularPresentationRequested = true
            if !setActivationPolicy(.regular) {
                NSLog("OmniDock could not switch to regular application presentation.")
            }
        }
        activateApplication()
    }

    func dismiss(_ surface: ApplicationPresentationSurface) {
        guard activeSurfaces.remove(surface) != nil else {
            return
        }

        transitionGeneration &+= 1
        guard activeSurfaces.isEmpty else {
            return
        }

        let expectedGeneration = transitionGeneration
        scheduleDeferred { [weak self] in
            guard let self,
                  self.activeSurfaces.isEmpty,
                  self.transitionGeneration == expectedGeneration
            else {
                return
            }
            self.isRegularPresentationRequested = false
            if !self.setActivationPolicy(.accessory) {
                NSLog("OmniDock could not restore accessory application presentation.")
            }
        }
    }

    var activeSurfaceCount: Int {
        activeSurfaces.count
    }
}
