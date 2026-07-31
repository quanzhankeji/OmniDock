import AppKit
import Foundation

@MainActor
final class ApplicationUpdateService {
    static let changedNotification = Notification.Name(
        "ApplicationUpdateService.changed"
    )

    private let releaseClient: GitHubReleaseClient
    private let installer: UpdatePackageInstaller
    private let presentationCoordinator: ApplicationPresentationCoordinator
    private let currentAppURL: URL
    private let currentVersion: SemanticVersion
    private let currentVersionText: String
    private let currentBuild: String
    private let progressController = UpdateProgressWindowController()

    private var startupTask: Task<Void, Never>?
    private var checkTask: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?
    private var reminderTask: Task<Void, Never>?
    private var latestRelease: GitHubRelease?
    private var lastCheckedAt: Date?
    private var status: ApplicationUpdateStatus = .idle
    private var didDeferAutomaticPrompt = false
    private var isChecking = false

    init(
        releaseClient: GitHubReleaseClient = GitHubReleaseClient(),
        installer: UpdatePackageInstaller = UpdatePackageInstaller(),
        presentationCoordinator: ApplicationPresentationCoordinator,
        bundle: Bundle = .main
    ) {
        self.releaseClient = releaseClient
        self.installer = installer
        self.presentationCoordinator = presentationCoordinator
        currentAppURL = bundle.bundleURL
        currentVersionText = bundle.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "0.0.0"
        currentVersion = SemanticVersion(currentVersionText)
            ?? SemanticVersion("0.0.0")!
        currentBuild = bundle.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "0"
        progressController.onCancel = { [weak self] in
            self?.cancelDownload()
        }
    }

    var snapshot: ApplicationUpdateSnapshot {
        ApplicationUpdateSnapshot(
            currentVersion: currentVersionText,
            currentBuild: currentBuild,
            lastCheckedAt: lastCheckedAt,
            status: status
        )
    }

    func start() {
        guard startupTask == nil else {
            return
        }
        startupTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else {
                return
            }
            await self?.check(origin: .automatic)
            self?.startupTask = nil
        }
    }

    func stop() {
        startupTask?.cancel()
        startupTask = nil
        checkTask?.cancel()
        checkTask = nil
        reminderTask?.cancel()
        reminderTask = nil
        operationTask?.cancel()
        operationTask = nil
        installer.cancel()
        progressController.close()
    }

    func checkManually() {
        guard checkTask == nil else {
            return
        }
        startupTask?.cancel()
        startupTask = nil
        checkTask = Task { [weak self] in
            await self?.check(origin: .manual)
            self?.checkTask = nil
        }
    }

    func openLatestReleasePage() {
        let url = latestRelease?.pageURL
            ?? URL(string: "https://github.com/quanzhankeji/OmniDock/releases/latest")!
        NSWorkspace.shared.open(url)
    }

    private func check(origin: UpdateCheckOrigin) async {
        guard operationTask == nil, !isChecking else {
            return
        }
        isChecking = true
        defer { isChecking = false }

        setStatus(.checking)
        do {
            let response = try await releaseClient.fetchLatestRelease()
            lastCheckedAt = response.checkedAt
            latestRelease = response.release
            guard let releaseVersion = response.release.version,
                  releaseVersion > currentVersion
            else {
                setStatus(.current)
                if origin == .manual {
                    presentInformation(
                        title: AppStrings.text(.updateCurrentTitle),
                        detail: AppStrings.text(.updateCurrentDetail)
                    )
                }
                return
            }

            let canInstallAutomatically =
                installer.installationMode(for: currentAppURL) == .automatic
                    && response.release.installableZIPAsset != nil
            setStatus(
                .available(
                    version: releaseVersion.displayValue,
                    canInstallAutomatically: canInstallAutomatically
                )
            )
            if origin == .manual {
                presentUpdatePrompt(for: response.release)
            } else {
                presentAutomaticPromptWhenPossible(for: response.release)
            }
        } catch is CancellationError {
            setStatus(.idle)
        } catch {
            guard !Task.isCancelled else {
                setStatus(.idle)
                return
            }
            lastCheckedAt = Date()
            setStatus(.failed(message: error.localizedDescription))
            if origin == .manual {
                presentInformation(
                    title: AppStrings.text(.updateCheckFailedTitle),
                    detail: AppStrings.text(.updateCheckFailedDetail)
                )
            }
        }
    }

    private func presentAutomaticPromptWhenPossible(
        for release: GitHubRelease
    ) {
        guard !presentationCoordinator.isPresenting(.permissionOnboarding)
        else {
            guard !didDeferAutomaticPrompt else {
                return
            }
            didDeferAutomaticPrompt = true
            reminderTask?.cancel()
            reminderTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    guard let self else {
                        return
                    }
                    if !self.presentationCoordinator.isPresenting(
                        .permissionOnboarding
                    ) {
                        self.didDeferAutomaticPrompt = false
                        self.presentUpdatePrompt(for: release)
                        return
                    }
                }
            }
            return
        }
        presentUpdatePrompt(for: release)
    }

    private func presentUpdatePrompt(for release: GitHubRelease) {
        guard let version = release.version else {
            return
        }
        presentationCoordinator.present(.update)
        defer { presentationCoordinator.dismiss(.update) }

        let canDownload = (
            installer.installationMode(for: currentAppURL) == .automatic
                && release.installableZIPAsset != nil
        ) || release.manualDMGAsset != nil
        let alert = NSAlert()
        alert.messageText = AppStrings.format(
            .updateAvailableTitle,
            version.displayValue
        )
        alert.informativeText = canDownload
            ? AppStrings.text(.updateAvailableDetail)
            : AppStrings.text(.updateReleaseOnlyDetail)
        if canDownload {
            alert.addButton(withTitle: AppStrings.text(.updateDownloadAndInstall))
        }
        alert.addButton(withTitle: AppStrings.text(.updateLater))
        alert.addButton(withTitle: AppStrings.text(.updateViewRelease))

        let response = alert.runModal()
        if canDownload, response == .alertFirstButtonReturn {
            downloadAndInstall(release)
        } else if (
            canDownload && response == .alertThirdButtonReturn
        ) || (
            !canDownload && response == .alertSecondButtonReturn
        ) {
            NSWorkspace.shared.open(release.pageURL)
        }
    }

    private func downloadAndInstall(_ release: GitHubRelease) {
        guard operationTask == nil else {
            return
        }
        presentationCoordinator.present(.update)
        progressController.show()
        setStatus(.downloading(progress: 0))

        operationTask = Task { [weak self] in
            guard let self else {
                return
            }
            defer {
                self.operationTask = nil
            }
            do {
                if self.installer.installationMode(
                    for: self.currentAppURL
                ) == .automatic,
                release.installableZIPAsset != nil {
                    let prepared = try await self.installer.prepareAutomaticUpdate(
                        release: release,
                        currentAppURL: self.currentAppURL
                    ) { [weak self] progress in
                        Task { @MainActor in
                            self?.setDownloadProgress(progress)
                        }
                    }
                    guard !Task.isCancelled else {
                        throw CancellationError()
                    }
                    self.setStatus(.installing)
                    self.progressController.showInstalling()
                    try self.installer.beginAutomaticInstallation(
                        preparedUpdate: prepared,
                        currentAppURL: self.currentAppURL
                    )
                } else if release.manualDMGAsset != nil {
                    let prepared = try await self.installer.prepareManualUpdate(
                        release: release
                    ) { [weak self] progress in
                        Task { @MainActor in
                            self?.setDownloadProgress(progress)
                        }
                    }
                    guard !Task.isCancelled else {
                        throw CancellationError()
                    }
                    self.progressController.close()
                    self.presentationCoordinator.dismiss(.update)
                    self.setAvailableStatus(for: release)
                    NSWorkspace.shared.open(prepared.diskImageURL)
                    self.presentInformation(
                        title: AppStrings.text(.updateManualInstallTitle),
                        detail: AppStrings.text(.updateManualInstallDetail)
                    )
                } else {
                    self.progressController.close()
                    self.presentationCoordinator.dismiss(.update)
                    self.setAvailableStatus(for: release)
                    NSWorkspace.shared.open(release.pageURL)
                }
            } catch is CancellationError {
                self.progressController.close()
                self.presentationCoordinator.dismiss(.update)
                self.setAvailableStatus(for: release)
            } catch {
                self.progressController.close()
                self.presentationCoordinator.dismiss(.update)
                self.setStatus(.failed(message: error.localizedDescription))
                self.presentInformation(
                    title: AppStrings.text(.updateInstallFailedTitle),
                    detail: self.localizedInstallationError(error)
                )
            }
        }
    }

    private func cancelDownload() {
        installer.cancel()
        operationTask?.cancel()
    }

    private func setDownloadProgress(_ progress: Double) {
        setStatus(.downloading(progress: progress))
        progressController.update(progress: progress)
    }

    private func setAvailableStatus(for release: GitHubRelease) {
        guard let version = release.version else {
            setStatus(.idle)
            return
        }
        setStatus(
            .available(
                version: version.displayValue,
                canInstallAutomatically:
                    installer.installationMode(for: currentAppURL) == .automatic
                        && release.installableZIPAsset != nil
            )
        )
    }

    private func setStatus(_ status: ApplicationUpdateStatus) {
        self.status = status
        NotificationCenter.default.post(
            name: Self.changedNotification,
            object: self
        )
    }

    private func presentInformation(title: String, detail: String) {
        presentationCoordinator.present(.update)
        defer { presentationCoordinator.dismiss(.update) }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: AppStrings.text(.updateOK))
        alert.runModal()
    }

    private func localizedInstallationError(_ error: Error) -> String {
        guard let packageError = error as? UpdatePackageError else {
            return AppStrings.text(.updateDownloadValidationFailed)
        }
        switch packageError {
        case .assetTooLarge, .digestMismatch, .archiveInvalid:
            return AppStrings.text(.updateDownloadValidationFailed)
        case .bundleIdentifierMismatch, .finderExtensionMissing, .signatureInvalid,
             .gatekeeperRejected:
            return AppStrings.text(.updateSignatureValidationFailed)
        case .versionMismatch, .systemVersionUnsupported:
            return AppStrings.text(.updateCompatibilityFailed)
        case .installationUnavailable, .replacementFailed, .relaunchFailed:
            return AppStrings.text(.updateReplacementFailed)
        }
    }
}
