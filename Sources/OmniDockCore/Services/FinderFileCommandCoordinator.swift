import AppKit
import ApplicationServices
import CoreGraphics

// What to do about items whose name is already taken at the destination. One
// decision covers the whole paste: asking per item turns a multi-file paste
// into an interrogation.
enum FinderPasteConflictResolution: Equatable {
    case replace
    case keepBoth
    case cancel
}

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
    private let resolvePasteConflicts: @MainActor ([URL]) -> FinderPasteConflictResolution
    private let announceDirectoryChange: (URL) -> Void
    private let beginInlineRename: () -> Void
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
        resolvePasteConflicts: @escaping @MainActor ([URL]) -> FinderPasteConflictResolution =
            FinderFileCommandCoordinator.presentPasteConflictAlert,
        announceDirectoryChange: @escaping (URL) -> Void = { directory in
            NSWorkspace.shared.noteFileSystemChanged(directory.path)
        },
        beginInlineRename: @escaping () -> Void = {
            FinderInlineRenameActivator().begin()
        },
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
        self.resolvePasteConflicts = resolvePasteConflicts
        self.announceDirectoryChange = announceDirectoryChange
        self.beginInlineRename = beginInlineRename
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
        case let .copyItems(displayPaths, isCut):
            guard isCut ? preferences.showsCutItemsCommand
                        : preferences.showsCopyItemsCommand
            else {
                return
            }
            let urls = displayPaths.map {
                URL(fileURLWithPath: $0).standardizedFileURL
            }
            FinderItemPasteboard.write(urls, isCut: isCut, to: itemPasteboard)
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
            finishPaste(pasted, movedFrom: sources, isCut: isCut)
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
                    finishPaste(pasted, movedFrom: sources, isCut: isCut)
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
                finishPaste(pasted, movedFrom: sources, isCut: isCut)
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
        // Moving an item into the folder it already sits in is a no-op, not a
        // rename to "Report 2.txt".
        let incoming = sources.filter { source in
            !(isCut && source.deletingLastPathComponent().standardizedFileURL == directory)
        }

        var resolution = FinderPasteConflictResolution.keepBoth
        let conflicts = incoming.filter {
            Self.conflictsOnPaste($0, in: directory, isCut: isCut, fileManager: fileManager)
        }
        if !conflicts.isEmpty {
            resolution = resolvePasteConflicts(conflicts)
            guard resolution != .cancel else {
                return []
            }
        }

        var pasted: [URL] = []
        for source in incoming {
            let taken = directory.appendingPathComponent(source.lastPathComponent)
            let replaces = resolution == .replace
                && Self.conflictsOnPaste(
                    source,
                    in: directory,
                    isCut: isCut,
                    fileManager: fileManager
                )
            // Keeping both puts the incoming item beside the existing one, the
            // way Finder does; replacing clears the way for it first.
            let destination = replaces
                ? taken
                : Self.availableDestination(
                    for: source,
                    in: directory,
                    fileManager: fileManager
                )
            if replaces, fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            if isCut {
                try fileManager.moveItem(at: source, to: destination)
            } else {
                try fileManager.copyItem(at: source, to: destination)
            }
            pasted.append(destination)
        }
        return pasted
    }

    // Copying an item into the folder it already lives in is never a conflict:
    // there is nothing to replace, because the only match is the item itself.
    static func conflictsOnPaste(
        _ source: URL,
        in directory: URL,
        isCut: Bool,
        fileManager: FileManager = .default
    ) -> Bool {
        let taken = directory.appendingPathComponent(source.lastPathComponent)
        guard fileManager.fileExists(atPath: taken.path) else {
            return false
        }
        return isCut || taken.standardizedFileURL != source.standardizedFileURL
    }

    static func presentPasteConflictAlert(
        _ conflicts: [URL]
    ) -> FinderPasteConflictResolution {
        guard let application = NSApp, let first = conflicts.first else {
            return .cancel
        }
        application.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = conflicts.count == 1
            ? String(
                format: AppStrings.text(.finderPasteConflictTitle),
                first.lastPathComponent
            )
            : String(
                format: AppStrings.text(.finderPasteConflictMultipleTitle),
                conflicts.count
            )
        alert.informativeText = AppStrings.text(.finderPasteConflictDetail)
        // Keeping both is first so Return cannot destroy anything.
        alert.addButton(withTitle: AppStrings.text(.finderPasteConflictKeepBoth))
        alert.addButton(withTitle: AppStrings.text(.finderPasteConflictReplace))
        alert.addButton(withTitle: AppStrings.text(.finderPasteConflictCancel))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .keepBoth
        case .alertSecondButtonReturn:
            return .replace
        default:
            return .cancel
        }
    }

    private func finishPaste(_ pasted: [URL], movedFrom sources: [URL], isCut: Bool) {
        // Nothing moved means the cut is still pending - every item was already
        // in this folder - so the clipboard has to survive for the paste the
        // user actually meant. Clearing it here emptied the clipboard and moved
        // nothing, which is indistinguishable from the command being broken.
        guard !pasted.isEmpty else {
            return
        }
        if isCut {
            // The sources are gone, so leaving them on the pasteboard would
            // offer a second paste that could only fail.
            itemPasteboard.clearContents()
        }

        // Revealing the pasted items refreshes the folder they landed in, but
        // nothing tells Finder about the folder a cut emptied, so a window
        // showing it keeps listing an item that is no longer there.
        var changed = Set(pasted.map { $0.deletingLastPathComponent().standardizedFileURL })
        if isCut {
            changed.formUnion(
                sources.map { $0.deletingLastPathComponent().standardizedFileURL }
            )
        }
        for directory in changed {
            announceDirectoryChange(directory)
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

    // Only the new-document commands land here; a paste reveals its own items
    // without arming the rename, because a pasted file already has the name the
    // user chose for it.
    private func reveal(_ file: URL) {
        revealFiles([file])
        beginInlineRename()
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
