import AppKit

@MainActor
final class FinderFileCommandCoordinator {
    private let requestMailbox: FinderFileRequestMailbox
    private let preferencesStore: FinderMenuPreferencesStore
    private let directoryGrantStore: FinderDirectoryGrantStore
    private let fileManager: FileManager

    init(
        requestMailbox: FinderFileRequestMailbox = FinderFileRequestMailbox(),
        preferencesStore: FinderMenuPreferencesStore = FinderMenuPreferencesStore(),
        directoryGrantStore: FinderDirectoryGrantStore = FinderDirectoryGrantStore(),
        fileManager: FileManager = .default
    ) {
        self.requestMailbox = requestMailbox
        self.preferencesStore = preferencesStore
        self.directoryGrantStore = directoryGrantStore
        self.fileManager = fileManager
    }

    func handle(urls: [URL]) {
        for url in urls {
            guard let requestID = FinderActionRoute.requestID(from: url),
                  let request = requestMailbox.take(id: requestID)
            else {
                continue
            }
            guard preferencesStore.snapshot().isEnabled else {
                continue
            }
            execute(request)
        }
    }

    private func execute(_ request: FinderFileRequest) {
        switch request.action {
        case .createTextFile, .createMarkdownFile:
            createFile(for: request)
        case .copyCurrentDirectoryPath, .copySelectedPaths:
            break
        }
    }

    private func createFile(for request: FinderFileRequest) {
        guard let kind = request.action.documentKind else {
            return
        }
        let directory = URL(
            fileURLWithPath: request.directoryDisplayPath,
            isDirectory: true
        ).standardizedFileURL

        do {
            let file = try BlankDocumentFactory.create(
                in: directory,
                kind: kind,
                fileManager: fileManager
            )
            reveal(file)
        } catch {
            guard Self.isPermissionFailure(error) else {
                presentFailure(for: request, error: error)
                return
            }

            do {
                if let file = try directoryGrantStore.performWithSavedAccess(
                    to: directory,
                    operation: { authorizedDirectory in
                        try BlankDocumentFactory.create(
                            in: authorizedDirectory,
                            kind: kind,
                            fileManager: fileManager
                        )
                    }
                ) {
                    reveal(file)
                    return
                }
            } catch {
                guard Self.isPermissionFailure(error) else {
                    presentFailure(for: request, error: error)
                    return
                }
            }

            requestAccessAndCreateFile(
                for: request,
                directory: directory,
                kind: kind
            )
        }
    }

    private func requestAccessAndCreateFile(
        for request: FinderFileRequest,
        directory: URL,
        kind: FinderDocumentKind
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
                        kind: kind,
                        fileManager: fileManager
                    )
                }
            ) else {
                throw CocoaError(.fileWriteNoPermission)
            }
            reveal(file)
        } catch {
            presentFailure(for: request, error: error)
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

    private func presentFailure(for request: FinderFileRequest, error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = AppStrings.text(.finderExtensionCreateFailedTitle)
        alert.informativeText = String(
            format: AppStrings.text(.finderExtensionCreateFailedDetail),
            request.directoryDisplayPath,
            error.localizedDescription
        )
        alert.addButton(withTitle: AppStrings.text(.finderExtensionFailureDismiss))
        alert.runModal()
    }
}
