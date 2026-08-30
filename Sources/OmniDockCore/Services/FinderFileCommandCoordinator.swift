import AppKit
import ApplicationServices
import CoreGraphics

@MainActor
final class FinderFileCommandCoordinator: NSObject {
    private let requestMailbox: FinderCommandMailbox
    private let preferencesStore: FinderMenuPreferencesStore
    private let directoryGrantStore: FinderDirectoryGrantStore
    private let fileManager: FileManager
    private let itemPasteboard: NSPasteboard
    private let hiddenFilesController: FinderHiddenFilesController
    private let revealFiles: ([URL]) -> Void
    private let requestDirectoryAccess: @MainActor (URL) -> URL?
    private let openApplication: (
        _ directoryURL: URL,
        _ applicationURL: URL,
        _ completion: @escaping (Error?) -> Void
    ) -> Void
    private var isListening = false

    init(
        requestMailbox: FinderCommandMailbox = FinderCommandMailbox(),
        preferencesStore: FinderMenuPreferencesStore = FinderMenuPreferencesStore(),
        directoryGrantStore: FinderDirectoryGrantStore = FinderDirectoryGrantStore(),
        fileManager: FileManager = .default,
        itemPasteboard: NSPasteboard = .general,
        hiddenFilesController: FinderHiddenFilesController? = nil,
        revealFiles: @escaping ([URL]) -> Void = {
            NSWorkspace.shared.activateFileViewerSelecting($0)
        },
        requestDirectoryAccess: @escaping @MainActor (URL) -> URL? =
            FinderFileCommandCoordinator.presentDirectoryAccessPanel,
        openApplication: @escaping (
            _ directoryURL: URL,
            _ applicationURL: URL,
            _ completion: @escaping (Error?) -> Void
        ) -> Void = { directoryURL, applicationURL, completion in
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open(
                [directoryURL],
                withApplicationAt: applicationURL,
                configuration: configuration
            ) { _, error in
                completion(error)
            }
        }
    ) {
        self.requestMailbox = requestMailbox
        self.preferencesStore = preferencesStore
        self.directoryGrantStore = directoryGrantStore
        self.fileManager = fileManager
        self.itemPasteboard = itemPasteboard
        self.hiddenFilesController = hiddenFilesController ?? FinderHiddenFilesController()
        self.revealFiles = revealFiles
        self.requestDirectoryAccess = requestDirectoryAccess
        self.openApplication = openApplication
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
            createFile(
                fileExtension: fileExtension,
                directoryDisplayPath: directoryDisplayPath
            )
        case let .pasteItems(directoryDisplayPath):
            guard preferences.showsPasteItemsCommand else {
                return
            }
            pasteItems(
                into: URL(
                    fileURLWithPath: directoryDisplayPath,
                    isDirectory: true
                ).standardizedFileURL
            )
        case let .setHiddenFilesVisible(isVisible):
            guard FinderCommandAuthorizationPolicy.allowsHiddenFilesCommand(
                isVisible: isVisible,
                preferences: preferences
            ) else {
                return
            }
            hiddenFilesController.setHiddenFilesVisible(isVisible)
        case let .openDirectory(requestedShortcut, directoryDisplayPath):
            guard let shortcut = FinderCommandAuthorizationPolicy.launchShortcut(
                matching: requestedShortcut,
                preferences: preferences
            ) else {
                return
            }
            let directory = URL(
                fileURLWithPath: directoryDisplayPath,
                isDirectory: true
            ).standardizedFileURL
            openDirectory(
                directory,
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

    // Asks the user to grant a folder OmniDock has no access to yet, and
    // records the grant. Shared by every command that needs one, so a folder
    // approved for one is approved for the rest.
    static func presentDirectoryAccessPanel(for directory: URL) -> URL? {
        // There is no panel to present without a running application, and
        // asking for one would be worse than declining the grant.
        guard let application = NSApp else {
            return nil
        }
        application.activate(ignoringOtherApps: true)

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

        guard panel.runModal() == .OK else {
            return nil
        }
        return panel.url?.standardizedFileURL
    }

    @discardableResult
    private func grantAccess(to directory: URL) -> Bool {
        guard let authorizedDirectory = requestDirectoryAccess(directory),
              FinderDirectoryGrantStore.contains(directory, in: authorizedDirectory)
        else {
            return false
        }
        do {
            try directoryGrantStore.remember(directory: authorizedDirectory)
            return true
        } catch {
            return false
        }
    }

    private func requestAccessAndCreateFile(
        fileExtension: String,
        directoryDisplayPath: String,
        directory: URL
    ) {
        guard grantAccess(to: directory) else {
            return
        }

        do {
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

    // The sources come from the pasteboard at the moment the command runs, the
    // same thing Finder pastes, so nothing about them travels in the request.
    private func pasteItems(into directory: URL) {
        let (sources, isCut) = FinderItemPasteboard.read(from: itemPasteboard)
        guard !sources.isEmpty else {
            return
        }

        do {
            let pasted = try paste(sources, into: directory, isCut: isCut)
            finishPaste(pasted, isCut: isCut)
        } catch {
            guard Self.isPermissionFailure(error) else {
                presentCreateFailure(
                    directoryDisplayPath: directory.path,
                    error: error
                )
                return
            }
            do {
                if let pasted = try directoryGrantStore.performWithSavedAccess(
                    to: directory,
                    operation: { try paste(sources, into: $0, isCut: isCut) }
                ) {
                    finishPaste(pasted, isCut: isCut)
                    return
                }
            } catch {
                guard Self.isPermissionFailure(error) else {
                    presentCreateFailure(
                        directoryDisplayPath: directory.path,
                        error: error
                    )
                    return
                }
            }
            guard grantAccess(to: directory) else {
                return
            }
            do {
                guard let pasted = try directoryGrantStore.performWithSavedAccess(
                    to: directory,
                    operation: { try paste(sources, into: $0, isCut: isCut) }
                ) else {
                    throw CocoaError(.fileWriteNoPermission)
                }
                finishPaste(pasted, isCut: isCut)
            } catch {
                presentCreateFailure(
                    directoryDisplayPath: directory.path,
                    error: error
                )
            }
        }
    }

    private func paste(
        _ sources: [URL],
        into directory: URL,
        isCut: Bool
    ) throws -> [URL] {
        var pasted: [URL] = []
        for source in sources {
            // Moving an item into the folder it already sits in is a no-op, not
            // a rename to "Report 2.txt".
            if isCut,
               source.deletingLastPathComponent().standardizedFileURL == directory {
                continue
            }
            // Pasting a copy into that same folder does need a free name, the
            // way Finder puts a copy beside the original.
            let destination = Self.availableDestination(
                for: source,
                in: directory,
                fileManager: fileManager
            )
            if isCut {
                try fileManager.moveItem(at: source, to: destination)
            } else {
                try fileManager.copyItem(at: source, to: destination)
            }
            pasted.append(destination)
        }
        return pasted
    }

    private func finishPaste(_ pasted: [URL], isCut: Bool) {
        if isCut {
            // The sources are gone, so leaving them on the pasteboard would
            // offer a second paste that could only fail.
            itemPasteboard.clearContents()
        }
        guard !pasted.isEmpty else {
            return
        }
        revealFiles(pasted)
    }

    // "Report.txt" becomes "Report 2.txt" rather than overwriting anything.
    static func availableDestination(
        for source: URL,
        in directory: URL,
        fileManager: FileManager = .default
    ) -> URL {
        let fileExtension = source.pathExtension
        let base = source.deletingPathExtension().lastPathComponent
        var candidate = directory.appendingPathComponent(source.lastPathComponent)
        var sequence = 2
        while fileManager.fileExists(atPath: candidate.path) {
            let name = fileExtension.isEmpty
                ? "\(base) \(sequence)"
                : "\(base) \(sequence).\(fileExtension)"
            candidate = directory.appendingPathComponent(name)
            sequence += 1
        }
        return candidate
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

    private func openDirectory(
        _ directoryURL: URL,
        with shortcut: FinderLaunchShortcut
    ) {
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(
            atPath: directoryURL.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            return
        }

        guard let applicationURL = FinderApplicationTargetResolver.resolve(
            shortcut: shortcut,
            fileExists: fileManager.fileExists(atPath:)
        ) else {
            presentOpenFailure(
                applicationName: shortcut.displayName,
                detail: AppStrings.text(.finderQuickOpenApplicationMissing)
            )
            return
        }

        openApplication(directoryURL, applicationURL) { [weak self] error in
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
