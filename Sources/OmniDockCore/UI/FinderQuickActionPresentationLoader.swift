import AppKit

struct FinderQuickActionPresentation: @unchecked Sendable {
    let applicationURL: URL?
    let icon: NSImage?
}

struct FinderQuickActionPresentationKey: Equatable, Hashable, Sendable {
    let id: UUID
    let bundleURLString: String
    let bundleIdentifier: String?

    init(shortcut: FinderLaunchShortcut) {
        id = shortcut.id
        bundleURLString = shortcut.bundleURLString
        bundleIdentifier = shortcut.bundleIdentifier
    }
}

@MainActor
final class FinderQuickActionPresentationLoader {
    typealias ApplicationURLProvider = @Sendable (String) -> URL?
    typealias IconProvider = @Sendable (String) -> NSImage
    typealias FileExistsProvider = @Sendable (String) -> Bool

    private let applicationURLProvider: ApplicationURLProvider
    private let iconProvider: IconProvider
    private let fileExistsProvider: FileExistsProvider
    private var loadTask: Task<[UUID: FinderQuickActionPresentation], Never>?
    private var generation: UInt = 0

    init(
        applicationURLProvider: @escaping ApplicationURLProvider = { bundleIdentifier in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        },
        iconProvider: @escaping IconProvider = { path in
            NSWorkspace.shared.icon(forFile: path)
        },
        fileExistsProvider: @escaping FileExistsProvider = { path in
            FileManager.default.fileExists(atPath: path)
        }
    ) {
        self.applicationURLProvider = applicationURLProvider
        self.iconProvider = iconProvider
        self.fileExistsProvider = fileExistsProvider
    }

    func load(
        shortcuts: [FinderLaunchShortcut]
    ) async -> [UUID: FinderQuickActionPresentation] {
        cancel()
        let currentGeneration = generation
        let applicationURLProvider = applicationURLProvider
        let iconProvider = iconProvider
        let fileExistsProvider = fileExistsProvider
        let task: Task<[UUID: FinderQuickActionPresentation], Never> = Task.detached(
            priority: .userInitiated
        ) {
            var result: [UUID: FinderQuickActionPresentation] = [:]
            result.reserveCapacity(shortcuts.count)

            for shortcut in shortcuts {
                guard !Task.isCancelled else {
                    return [:]
                }
                let applicationURL = FinderApplicationTargetResolver.resolve(
                    shortcut: shortcut,
                    fileExists: fileExistsProvider,
                    installedApplicationURL: applicationURLProvider
                )
                let icon = applicationURL.map { iconProvider($0.path) }
                result[shortcut.id] = FinderQuickActionPresentation(
                    applicationURL: applicationURL,
                    icon: icon
                )
            }
            return result
        }
        loadTask = task
        let result = await task.value
        if generation == currentGeneration {
            loadTask = nil
        }
        return result
    }

    func cancel() {
        generation &+= 1
        loadTask?.cancel()
        loadTask = nil
    }
}

enum FinderQuickActionBrandIcon {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var cache: [String: NSImage] = [:]

    static func image(for shortcut: FinderLaunchShortcut) -> NSImage {
        let key = shortcut.bundleIdentifier ?? shortcut.id.uuidString
        lock.lock()
        if let cached = cache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let image = shortcut.bundleIdentifier
            .flatMap(resourceImage(bundleIdentifier:))
            ?? fallbackImage(for: shortcut)
        image.size = NSSize(width: 26, height: 26)

        lock.lock()
        cache[key] = image
        lock.unlock()
        return image
    }

    private static func resourceImage(bundleIdentifier: String) -> NSImage? {
        if let image = resourceImage(bundleIdentifier: bundleIdentifier, bundle: .main) {
            return image
        }

        #if SWIFT_PACKAGE && !OMNIDOCK_APP_BUNDLE_BUILD
        return resourceImage(bundleIdentifier: bundleIdentifier, bundle: .module)
        #else
        return nil
        #endif
    }

    private static func resourceImage(
        bundleIdentifier: String,
        bundle: Bundle
    ) -> NSImage? {
        let url = bundle.url(
            forResource: bundleIdentifier,
            withExtension: "png",
            subdirectory: "FinderQuickActionIcons"
        ) ?? bundle.url(
            forResource: bundleIdentifier,
            withExtension: "png"
        )
        return url.flatMap(NSImage.init(contentsOf:))
    }

    private static func fallbackImage(for shortcut: FinderLaunchShortcut) -> NSImage {
        if shortcut.bundleIdentifier == "com.apple.Terminal",
           let terminal = NSImage(
               systemSymbolName: "terminal",
               accessibilityDescription: shortcut.displayName
           ) {
            return terminal
        }
        return NSImage(
            systemSymbolName: "app",
            accessibilityDescription: shortcut.displayName
        ) ?? NSImage(size: NSSize(width: 26, height: 26))
    }
}
