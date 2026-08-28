import AppKit
import ApplicationServices
import CoreGraphics

@MainActor
final class FinderFileCommandCoordinator: NSObject {
    private let requestMailbox: FinderCommandMailbox
    private let preferencesStore: FinderMenuPreferencesStore
    private let directoryGrantStore: FinderDirectoryGrantStore
    private let fileManager: FileManager
    private let hiddenFilesController: FinderHiddenFilesController
    private let homeDirectory: URL
    private let revealFiles: ([URL]) -> Void
    private var isListening = false

    init(
        requestMailbox: FinderCommandMailbox = FinderCommandMailbox(),
        preferencesStore: FinderMenuPreferencesStore = FinderMenuPreferencesStore(),
        directoryGrantStore: FinderDirectoryGrantStore = FinderDirectoryGrantStore(),
        fileManager: FileManager = .default,
        hiddenFilesController: FinderHiddenFilesController? = nil,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        revealFiles: @escaping ([URL]) -> Void = {
            NSWorkspace.shared.activateFileViewerSelecting($0)
        }
    ) {
        self.requestMailbox = requestMailbox
        self.preferencesStore = preferencesStore
        self.directoryGrantStore = directoryGrantStore
        self.fileManager = fileManager
        self.hiddenFilesController = hiddenFilesController ?? FinderHiddenFilesController()
        self.homeDirectory = homeDirectory
        self.revealFiles = revealFiles
        super.init()
    }

    func start() {
        guard !isListening else {
            return
        }
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(commandBecameAvailable(_:)),
            name: FinderCommandSignal.notificationName,
            object: nil
        )
        isListening = true
    }

    func stop() {
        guard isListening else {
            return
        }
        DistributedNotificationCenter.default().removeObserver(
            self,
            name: FinderCommandSignal.notificationName,
            object: nil
        )
        isListening = false
    }

    func handle(urls: [URL]) {
        for url in urls {
            guard let requestID = FinderActionRoute.requestID(from: url) else {
                continue
            }
            handle(requestID: requestID)
        }
    }

    func handle(requestID: UUID) {
        guard let request = requestMailbox.take(id: requestID) else {
            return
        }
        let preferences = preferencesStore.snapshot()
        guard preferences.isEnabled
        else {
            return
        }
        execute(request.command, preferences: preferences)
    }

    @objc private func commandBecameAvailable(_ notification: Notification) {
        guard let requestID = FinderCommandSignal.requestID(from: notification) else {
            return
        }
        handle(requestID: requestID)
    }

    private func execute(
        _ command: FinderCommand,
        preferences: FinderMenuPreferences
    ) {
        switch command {
        case let .createDocument(fileExtension, directoryDisplayPath):
            guard FinderCommandAuthorizationPolicy.documentPreset(
                for: fileExtension,
                preferences: preferences
            ) != nil else {
                return
            }
            let directory = URL(
                fileURLWithPath: directoryDisplayPath,
                isDirectory: true
            )
            guard FinderCommandAuthorizationPolicy.isAllowedTarget(
                directory,
                preferences: preferences,
                homeDirectory: homeDirectory
            ) else {
                return
            }
            createFile(
                fileExtension: fileExtension,
                directoryDisplayPath: directoryDisplayPath
            )
        case let .setHiddenFilesVisible(isVisible):
            guard FinderCommandAuthorizationPolicy.allowsHiddenFilesCommand(
                isVisible: isVisible,
                preferences: preferences
            ) else {
                return
            }
            hiddenFilesController.setHiddenFilesVisible(isVisible)
        case let .openSelection(requestedShortcut, selectedDisplayPaths):
            guard let shortcut = FinderCommandAuthorizationPolicy.launchShortcut(
                matching: requestedShortcut,
                preferences: preferences
            ) else {
                return
            }
            let selectedURLs = selectedDisplayPaths.map {
                URL(fileURLWithPath: $0).standardizedFileURL
            }
            guard !selectedURLs.isEmpty,
                  selectedURLs.allSatisfy({
                      FinderCommandAuthorizationPolicy.isAllowedTarget(
                          $0,
                          preferences: preferences,
                          homeDirectory: homeDirectory
                      )
                  })
            else {
                return
            }
            openSelection(
                selectedURLs,
                with: shortcut
            )
        }
    }

    private func createFile(
        fileExtension: String,
        directoryDisplayPath: String
    ) {
        let directory = URL(
            fileURLWithPath: directoryDisplayPath,
            isDirectory: true
        ).standardizedFileURL

        do {
            let file = try BlankDocumentFactory.create(
                in: directory,
                fileExtension: fileExtension,
                fileManager: fileManager
            )
            reveal(file)
        } catch {
            guard Self.isPermissionFailure(error) else {
                presentCreateFailure(
                    directoryDisplayPath: directoryDisplayPath,
                    error: error
                )
                return
            }

            do {
                if let file = try directoryGrantStore.performWithSavedAccess(
                    to: directory,
                    operation: { authorizedDirectory in
                        try BlankDocumentFactory.create(
                            in: authorizedDirectory,
                            fileExtension: fileExtension,
                            fileManager: fileManager
                        )
                    }
                ) {
                    reveal(file)
                    return
                }
            } catch {
                guard Self.isPermissionFailure(error) else {
                    presentCreateFailure(
                        directoryDisplayPath: directoryDisplayPath,
                        error: error
                    )
                    return
                }
            }

            requestAccessAndCreateFile(
                fileExtension: fileExtension,
                directoryDisplayPath: directoryDisplayPath,
                directory: directory
            )
        }
    }

    private func requestAccessAndCreateFile(
        fileExtension: String,
        directoryDisplayPath: String,
        directory: URL
    ) {
        NSApp.activate(ignoringOtherApps: true)

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = directory
        panel.message = String(
            format: AppStrings.text(.finderExtensionAccessDetail),
            directory.path
        )
        panel.prompt = AppStrings.text(.finderExtensionAccessButton)

        guard panel.runModal() == .OK,
              let authorizedDirectory = panel.url?.standardizedFileURL,
              FinderDirectoryGrantStore.contains(directory, in: authorizedDirectory)
        else {
            return
        }

        do {
            try directoryGrantStore.remember(directory: authorizedDirectory)
            guard let file = try directoryGrantStore.performWithSavedAccess(
                to: directory,
                operation: { targetDirectory in
                    try BlankDocumentFactory.create(
                        in: targetDirectory,
                        fileExtension: fileExtension,
                        fileManager: fileManager
                    )
                }
            ) else {
                throw CocoaError(.fileWriteNoPermission)
            }
            reveal(file)
        } catch {
            presentCreateFailure(
                directoryDisplayPath: directoryDisplayPath,
                error: error
            )
        }
    }

    private func reveal(_ file: URL) {
        revealFiles([file])
    }

    nonisolated static func isPermissionFailure(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain {
            return error.code == NSFileWriteNoPermissionError
                || error.code == NSFileReadNoPermissionError
        }
        return error.domain == NSPOSIXErrorDomain
            && (error.code == Int(EACCES) || error.code == Int(EPERM))
    }

    private func openSelection(
        _ selectedURLs: [URL],
        with shortcut: FinderLaunchShortcut
    ) {
        let urls = selectedURLs
            .filter { fileManager.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else {
            return
        }

        guard let applicationURL = FinderApplicationTargetResolver.resolve(
            shortcut: shortcut,
            fileExists: fileManager.fileExists(atPath:),
            installedApplicationURL: { bundleIdentifier in
                NSWorkspace.shared.urlForApplication(
                    withBundleIdentifier: bundleIdentifier
                )
            }
        ) else {
            presentOpenFailure(
                applicationName: shortcut.displayName,
                detail: AppStrings.text(.finderQuickOpenApplicationMissing)
            )
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(
            urls,
            withApplicationAt: applicationURL,
            configuration: configuration
        ) { [weak self] _, error in
            guard let error else {
                return
            }
            Task { @MainActor [weak self] in
                self?.presentOpenFailure(
                    applicationName: shortcut.displayName,
                    detail: error.localizedDescription
                )
            }
        }
    }

    private func presentCreateFailure(
        directoryDisplayPath: String,
        error: Error
    ) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = AppStrings.text(.finderExtensionCreateFailedTitle)
        alert.informativeText = String(
            format: AppStrings.text(.finderExtensionCreateFailedDetail),
            directoryDisplayPath,
            error.localizedDescription
        )
        alert.addButton(withTitle: AppStrings.text(.finderExtensionFailureDismiss))
        alert.runModal()
    }

    private func presentOpenFailure(
        applicationName: String,
        detail: String
    ) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = AppStrings.text(.finderQuickOpenFailedTitle)
        alert.informativeText = String(
            format: AppStrings.text(.finderQuickOpenFailedDetail),
            applicationName,
            detail
        )
        alert.addButton(withTitle: AppStrings.text(.finderExtensionFailureDismiss))
        alert.runModal()
    }
}

enum FinderCommandAuthorizationPolicy {
    static func isAllowedTarget(
        _ target: URL,
        preferences: FinderMenuPreferences,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        let resolvedTarget = target.standardizedFileURL.resolvingSymlinksInPath()
        return FinderObservationRoots.commandTargetURLs(
            homeDirectory: homeDirectory,
            authorizedDirectoryPaths: preferences.observationRootPaths
        ).contains { root in
            FinderDirectoryGrantStore.contains(
                resolvedTarget,
                in: root.resolvingSymlinksInPath()
            )
        }
    }

    static func documentPreset(
        for fileExtension: String,
        preferences: FinderMenuPreferences
    ) -> FinderDocumentPreset? {
        guard let normalizedExtension = FinderDocumentPreset.normalizedFileExtension(
            fileExtension
        ) else {
            return nil
        }
        return preferences.documentPresets.first {
            $0.isEnabled && $0.fileExtension == normalizedExtension
        }
    }

    static func launchShortcut(
        matching requestedShortcut: FinderLaunchShortcut,
        preferences: FinderMenuPreferences
    ) -> FinderLaunchShortcut? {
        preferences.launchShortcuts.first {
            $0.id == requestedShortcut.id && $0.isEnabled
        }
    }

    static func allowsHiddenFilesCommand(
        isVisible: Bool,
        preferences: FinderMenuPreferences
    ) -> Bool {
        isVisible
            ? preferences.showsShowHiddenFilesCommand
            : preferences.showsHideHiddenFilesCommand
    }
}

@MainActor
final class FinderHiddenFilesController {
    private static let finderBundleIdentifier = "com.apple.finder"
    private static let preferenceKey = "AppleShowAllFiles"
    private static let periodKeyCode: CGKeyCode = 47

    private let isShowingHiddenFiles: () -> Bool
    private let sendVisibilityToggle: () -> Bool

    convenience init() {
        self.init(
            isShowingHiddenFiles: {
                FinderHiddenFilesController.readFinderVisibilityPreference()
            },
            sendVisibilityToggle: {
                FinderHiddenFilesController.postFinderVisibilityShortcut()
            }
        )
    }

    init(
        isShowingHiddenFiles: @escaping () -> Bool,
        sendVisibilityToggle: @escaping () -> Bool
    ) {
        self.isShowingHiddenFiles = isShowingHiddenFiles
        self.sendVisibilityToggle = sendVisibilityToggle
    }

    @discardableResult
    func setHiddenFilesVisible(_ isVisible: Bool) -> Bool {
        guard isShowingHiddenFiles() != isVisible else {
            return true
        }
        return sendVisibilityToggle()
    }

    private static func readFinderVisibilityPreference() -> Bool {
        guard let value = CFPreferencesCopyAppValue(
            preferenceKey as CFString,
            finderBundleIdentifier as CFString
        ) else {
            return false
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        if let string = value as? String {
            return ["1", "true", "yes"].contains(string.lowercased())
        }
        return false
    }

    private static func postFinderVisibilityShortcut() -> Bool {
        guard AXIsProcessTrusted(),
              let finder = NSRunningApplication.runningApplications(
                  withBundleIdentifier: finderBundleIdentifier
              ).first,
              let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: periodKeyCode,
                  keyDown: true
              ),
              let keyUp = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: periodKeyCode,
                  keyDown: false
              )
        else {
            return false
        }

        let flags: CGEventFlags = [.maskCommand, .maskShift]
        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.postToPid(finder.processIdentifier)
        keyUp.postToPid(finder.processIdentifier)
        return true
    }
}

enum FinderApplicationTargetResolver {
    static func resolve(
        shortcut: FinderLaunchShortcut,
        fileExists: (String) -> Bool,
        installedApplicationURL: (String) -> URL?
    ) -> URL? {
        if let storedURL = shortcut.bundleURL,
           fileExists(storedURL.path) {
            return storedURL
        }
        guard let bundleIdentifier = shortcut.bundleIdentifier else {
            return nil
        }
        return installedApplicationURL(bundleIdentifier)
    }
}
