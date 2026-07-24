import AppKit

@MainActor
final class FinderFileCommandCoordinator: NSObject {
    private let requestMailbox: FinderCommandMailbox
    private let preferencesStore: FinderMenuPreferencesStore
    private let directoryGrantStore: FinderDirectoryGrantStore
    private let fileManager: FileManager
    private var isListening = false

    init(
        requestMailbox: FinderCommandMailbox = FinderCommandMailbox(),
        preferencesStore: FinderMenuPreferencesStore = FinderMenuPreferencesStore(),
        directoryGrantStore: FinderDirectoryGrantStore = FinderDirectoryGrantStore(),
        fileManager: FileManager = .default
    ) {
        self.requestMailbox = requestMailbox
        self.preferencesStore = preferencesStore
        self.directoryGrantStore = directoryGrantStore
        self.fileManager = fileManager
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
        guard let request = requestMailbox.take(id: requestID),
              preferencesStore.snapshot().isEnabled
        else {
            return
        }
        execute(request.command)
    }

    @objc private func commandBecameAvailable(_ notification: Notification) {
        guard let requestID = FinderCommandSignal.requestID(from: notification) else {
            return
        }
        handle(requestID: requestID)
    }

    private func execute(_ command: FinderCommand) {
        switch command {
        case let .createDocument(fileExtension, directoryDisplayPath):
            createFile(
                fileExtension: fileExtension,
                directoryDisplayPath: directoryDisplayPath
            )
        case let .openSelection(shortcut, selectedDisplayPaths):
            openSelection(
                selectedDisplayPaths,
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
        NSWorkspace.shared.activateFileViewerSelecting([file])
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
        _ selectedDisplayPaths: [String],
        with shortcut: FinderLaunchShortcut
    ) {
        let urls = selectedDisplayPaths
            .map { URL(fileURLWithPath: $0).standardizedFileURL }
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
