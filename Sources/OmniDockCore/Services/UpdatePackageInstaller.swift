import AppKit
import CryptoKit
import Foundation
import Security

enum UpdatePackageError: LocalizedError, Equatable {
    case assetTooLarge
    case digestMismatch
    case archiveInvalid
    case bundleIdentifierMismatch
    case versionMismatch
    case systemVersionUnsupported
    case finderExtensionMissing
    case signatureInvalid
    case gatekeeperRejected
    case installationUnavailable
    case replacementFailed
    case relaunchFailed

    var errorDescription: String? {
        switch self {
        case .assetTooLarge:
            return "The update is larger than OmniDock's download limit."
        case .digestMismatch:
            return "The downloaded update did not match GitHub's SHA-256 digest."
        case .archiveInvalid:
            return "The downloaded archive does not contain a valid OmniDock app."
        case .bundleIdentifierMismatch:
            return "The downloaded app has an unexpected bundle identifier."
        case .versionMismatch:
            return "The downloaded app version does not match the release."
        case .systemVersionUnsupported:
            return "This update does not support the current macOS version."
        case .finderExtensionMissing:
            return "The update is missing the Finder extension."
        case .signatureInvalid:
            return "The update is not signed by the same developer as this copy of OmniDock."
        case .gatekeeperRejected:
            return "macOS Gatekeeper rejected the downloaded update."
        case .installationUnavailable:
            return "OmniDock cannot replace the app at its current location."
        case .replacementFailed:
            return "OmniDock could not replace the installed app."
        case .relaunchFailed:
            return "The updated app could not be opened."
        }
    }
}

struct PreparedApplicationUpdate {
    let release: GitHubRelease
    let appURL: URL
    let workingDirectory: URL
    let designatedRequirement: String
}

struct PreparedManualUpdate {
    let release: GitHubRelease
    let diskImageURL: URL
    let workingDirectory: URL
}

struct UpdateInstallerManifest: Codable {
    let targetAppURL: URL
    let stagedAppURL: URL
    let cleanupDirectoryURL: URL
    let readinessFileURL: URL
    let currentProcessIdentifier: Int32
    let expectedVersion: String
    let designatedRequirement: String
}

enum UpdateArtifactIntegrity {
    static func sha256Hex(for data: Data) -> String {
        SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }
}

enum UpdateAtomicReplacement {
    static func perform(
        targetURL: URL,
        incomingURL: URL,
        launchAndConfirm: () -> Bool
    ) throws {
        try swap(targetURL, incomingURL)

        guard launchAndConfirm() else {
            try swap(targetURL, incomingURL)
            throw UpdatePackageError.relaunchFailed
        }
        try? FileManager.default.removeItem(at: incomingURL)
    }

    private static func swap(_ firstURL: URL, _ secondURL: URL) throws {
        let result = firstURL.withUnsafeFileSystemRepresentation { firstPath in
            secondURL.withUnsafeFileSystemRepresentation { secondPath in
                guard let firstPath, let secondPath else {
                    return Int32(-1)
                }
                return renameatx_np(
                    AT_FDCWD,
                    firstPath,
                    AT_FDCWD,
                    secondPath,
                    UInt32(RENAME_SWAP)
                )
            }
        }
        guard result == 0 else {
            throw UpdatePackageError.replacementFailed
        }
    }
}

enum UpdateBundleValidator {
    static let bundleIdentifier = "com.quanzhankeji.OmniDock"
    static let finderExtensionRelativePath =
        "Contents/PlugIns/OmniDockFinderSync.appex"

    static func currentDesignatedRequirement(appURL: URL) throws -> String {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            appURL as CFURL,
            SecCSFlags(),
            &staticCode
        ) == errSecSuccess,
        let staticCode
        else {
            throw UpdatePackageError.signatureInvalid
        }

        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(
            staticCode,
            SecCSFlags(),
            &requirement
        ) == errSecSuccess,
        let requirement
        else {
            throw UpdatePackageError.signatureInvalid
        }

        var requirementText: CFString?
        guard SecRequirementCopyString(
            requirement,
            SecCSFlags(),
            &requirementText
        ) == errSecSuccess,
        let requirementText
        else {
            throw UpdatePackageError.signatureInvalid
        }
        return requirementText as String
    }

    static func validate(
        appURL: URL,
        expectedVersion: SemanticVersion,
        designatedRequirement: String,
        assessGatekeeper: Bool = true
    ) throws {
        guard let bundle = Bundle(url: appURL),
              bundle.bundleIdentifier == bundleIdentifier
        else {
            throw UpdatePackageError.bundleIdentifierMismatch
        }
        guard let bundleVersion = bundle.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String,
        SemanticVersion(bundleVersion) == expectedVersion
        else {
            throw UpdatePackageError.versionMismatch
        }

        if let minimumVersion = bundle.object(
            forInfoDictionaryKey: "LSMinimumSystemVersion"
        ) as? String,
        let minimumSemanticVersion = SemanticVersion(minimumVersion),
        currentOperatingSystemVersion < minimumSemanticVersion {
            throw UpdatePackageError.systemVersionUnsupported
        }

        let finderExtensionURL = appURL.appendingPathComponent(
            finderExtensionRelativePath
        )
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: finderExtensionURL.path,
            isDirectory: &isDirectory
        ),
        isDirectory.boolValue
        else {
            throw UpdatePackageError.finderExtensionMissing
        }

        try verifySignature(
            appURL: appURL,
            designatedRequirement: designatedRequirement
        )
        if assessGatekeeper {
            let result = ProcessResult.run(
                executableURL: URL(fileURLWithPath: "/usr/sbin/spctl"),
                arguments: ["--assess", "--type", "execute", appURL.path]
            )
            guard result.status == 0 else {
                throw UpdatePackageError.gatekeeperRejected
            }
        }
    }

    private static var currentOperatingSystemVersion: SemanticVersion {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return SemanticVersion(
            "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        )!
    }

    private static func verifySignature(
        appURL: URL,
        designatedRequirement: String
    ) throws {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            appURL as CFURL,
            SecCSFlags(),
            &staticCode
        ) == errSecSuccess,
        let staticCode
        else {
            throw UpdatePackageError.signatureInvalid
        }

        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            designatedRequirement as CFString,
            SecCSFlags(),
            &requirement
        ) == errSecSuccess,
        let requirement
        else {
            throw UpdatePackageError.signatureInvalid
        }

        let flags = SecCSFlags(
            rawValue: UInt32(
                kSecCSCheckAllArchitectures
                    | kSecCSCheckNestedCode
                    | kSecCSStrictValidate
            )
        )
        guard SecStaticCodeCheckValidity(
            staticCode,
            flags,
            requirement
        ) == errSecSuccess else {
            throw UpdatePackageError.signatureInvalid
        }
    }
}

final class UpdatePackageInstaller: @unchecked Sendable {
    static let maximumAssetSize: Int64 = 512 * 1_024 * 1_024

    private let fileManager: FileManager
    private let downloader: UpdateAssetDownloader

    init(
        fileManager: FileManager = .default,
        downloader: UpdateAssetDownloader = UpdateAssetDownloader()
    ) {
        self.fileManager = fileManager
        self.downloader = downloader
    }

    func cancel() {
        downloader.cancel()
    }

    func prepareAutomaticUpdate(
        release: GitHubRelease,
        currentAppURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> PreparedApplicationUpdate {
        guard let releaseVersion = release.version,
              let asset = release.installableZIPAsset,
              let digest = asset.sha256Digest
        else {
            throw UpdatePackageError.archiveInvalid
        }
        let workingDirectory = try makeWorkingDirectory()
        do {
            let archiveURL = workingDirectory.appendingPathComponent(asset.name)
            try await downloader.download(
                asset: asset,
                destinationURL: archiveURL,
                maximumSize: Self.maximumAssetSize,
                progress: progress
            )
            try verifySHA256(fileURL: archiveURL, expected: digest)

            let extractionURL = workingDirectory.appendingPathComponent(
                "Expanded",
                isDirectory: true
            )
            try fileManager.createDirectory(
                at: extractionURL,
                withIntermediateDirectories: true
            )
            let extraction = ProcessResult.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/ditto"),
                arguments: ["-x", "-k", archiveURL.path, extractionURL.path]
            )
            guard extraction.status == 0 else {
                throw UpdatePackageError.archiveInvalid
            }

            let appURL = extractionURL.appendingPathComponent(
                "OmniDock.app",
                isDirectory: true
            )
            guard fileManager.fileExists(atPath: appURL.path) else {
                throw UpdatePackageError.archiveInvalid
            }
            let requirement = try UpdateBundleValidator.currentDesignatedRequirement(
                appURL: currentAppURL
            )
            try UpdateBundleValidator.validate(
                appURL: appURL,
                expectedVersion: releaseVersion,
                designatedRequirement: requirement
            )
            return PreparedApplicationUpdate(
                release: release,
                appURL: appURL,
                workingDirectory: workingDirectory,
                designatedRequirement: requirement
            )
        } catch {
            try? fileManager.removeItem(at: workingDirectory)
            throw error
        }
    }

    func prepareManualUpdate(
        release: GitHubRelease,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> PreparedManualUpdate {
        guard let asset = release.manualDMGAsset,
              let digest = asset.sha256Digest
        else {
            throw UpdatePackageError.archiveInvalid
        }
        let workingDirectory = try makeWorkingDirectory()
        do {
            let diskImageURL = workingDirectory.appendingPathComponent(asset.name)
            try await downloader.download(
                asset: asset,
                destinationURL: diskImageURL,
                maximumSize: Self.maximumAssetSize,
                progress: progress
            )
            try verifySHA256(fileURL: diskImageURL, expected: digest)
            return PreparedManualUpdate(
                release: release,
                diskImageURL: diskImageURL,
                workingDirectory: workingDirectory
            )
        } catch {
            try? fileManager.removeItem(at: workingDirectory)
            throw error
        }
    }

    @MainActor
    func beginAutomaticInstallation(
        preparedUpdate: PreparedApplicationUpdate,
        currentAppURL: URL
    ) throws {
        guard let version = preparedUpdate.release.version,
              let executableURL = Bundle.main.executableURL
        else {
            throw UpdatePackageError.installationUnavailable
        }

        let readinessFileURL = preparedUpdate.workingDirectory
            .appendingPathComponent("helper-ready")

        let manifest = UpdateInstallerManifest(
            targetAppURL: currentAppURL,
            stagedAppURL: preparedUpdate.appURL,
            cleanupDirectoryURL: preparedUpdate.workingDirectory,
            readinessFileURL: readinessFileURL,
            currentProcessIdentifier: ProcessInfo.processInfo.processIdentifier,
            expectedVersion: version.displayValue,
            designatedRequirement: preparedUpdate.designatedRequirement
        )
        let manifestURL = preparedUpdate.workingDirectory.appendingPathComponent(
            "install.json"
        )
        let manifestData = try JSONEncoder().encode(manifest)
        try manifestData.write(to: manifestURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: manifestURL.path
        )

        let process = Process()
        // Keep the helper inside the signed app bundle. A copied Mach-O loses
        // the bundle context required by its Developer ID signature.
        process.executableURL = executableURL
        process.arguments = ["--omnidock-apply-update", manifestURL.path]
        try process.run()
        guard waitForHelperReadiness(
            at: readinessFileURL,
            process: process
        ) else {
            if process.isRunning {
                process.terminate()
            }
            throw UpdatePackageError.installationUnavailable
        }
        NSApp.terminate(nil)
    }

    func installationMode(for appURL: URL) -> UpdateInstallationMode {
        let parentURL = appURL.deletingLastPathComponent()
        let values = try? parentURL.resourceValues(
            forKeys: [.volumeIsReadOnlyKey]
        )
        return UpdateInstallationPolicy.mode(
            appURL: appURL,
            isParentDirectoryWritable: fileManager.isWritableFile(
                atPath: parentURL.path
            ),
            isVolumeReadOnly: values?.volumeIsReadOnly ?? true
        )
    }

    private func makeWorkingDirectory() throws -> URL {
        let root = try fileManager.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent(
            "com.quanzhankeji.OmniDock/Updates",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let directory = root.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private func verifySHA256(fileURL: URL, expected: String) throws {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            guard !data.isEmpty else {
                break
            }
            hasher.update(data: data)
        }
        let actual = hasher.finalize().map {
            String(format: "%02x", $0)
        }.joined()
        guard actual == expected.lowercased() else {
            throw UpdatePackageError.digestMismatch
        }
    }

    private func waitForHelperReadiness(
        at readinessFileURL: URL,
        process: Process
    ) -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if fileManager.fileExists(atPath: readinessFileURL.path) {
                return true
            }
            guard process.isRunning else {
                return false
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }
}

final class UpdateAssetDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private struct State {
        var continuation: CheckedContinuation<Void, Error>?
        var destinationURL: URL?
        var maximumSize: Int64 = 0
        var expectedSize: Int64 = 0
        var progress: (@Sendable (Double) -> Void)?
        var task: URLSessionDownloadTask?
        var session: URLSession?
        var finished = false
    }

    private let lock = NSLock()
    private var state = State()

    func download(
        asset: GitHubReleaseAsset,
        destinationURL: URL,
        maximumSize: Int64,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard asset.size > 0, asset.size <= maximumSize else {
            throw UpdatePackageError.assetTooLarge
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = 30
                configuration.timeoutIntervalForResource = 300
                let session = URLSession(
                    configuration: configuration,
                    delegate: self,
                    delegateQueue: nil
                )
                let task = session.downloadTask(with: asset.downloadURL)
                lock.lock()
                state = State(
                    continuation: continuation,
                    destinationURL: destinationURL,
                    maximumSize: maximumSize,
                    expectedSize: asset.size,
                    progress: progress,
                    task: task,
                    session: session,
                    finished: false
                )
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            cancel()
        }
    }

    func cancel() {
        lock.lock()
        let task = state.task
        lock.unlock()
        task?.cancel()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        lock.lock()
        let maximumSize = state.maximumSize
        let expectedSize = state.expectedSize
        let progress = state.progress
        lock.unlock()

        if totalBytesWritten > maximumSize {
            downloadTask.cancel()
            finish(with: UpdatePackageError.assetTooLarge)
            return
        }
        let expected = max(totalBytesExpectedToWrite, expectedSize, 1)
        progress?(min(max(Double(totalBytesWritten) / Double(expected), 0), 1))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        lock.lock()
        let destinationURL = state.destinationURL
        lock.unlock()
        guard let destinationURL else {
            finish(with: UpdatePackageError.archiveInvalid)
            return
        }

        do {
            try FileManager.default.moveItem(
                at: location,
                to: destinationURL
            )
            finish(with: nil)
        } catch {
            finish(with: error)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            finish(with: error)
        }
    }

    private func finish(with error: Error?) {
        lock.lock()
        guard !state.finished else {
            lock.unlock()
            return
        }
        state.finished = true
        let continuation = state.continuation
        let session = state.session
        state.continuation = nil
        state.task = nil
        state.session = nil
        state.progress = nil
        lock.unlock()

        session?.finishTasksAndInvalidate()
        if let error {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume()
        }
    }
}

public enum UpdateInstallerCommand {
    public static func runIfRequested(arguments: [String]) -> Bool {
        guard arguments.count == 3,
              arguments[1] == "--omnidock-apply-update"
        else {
            return false
        }

        let manifestURL = URL(fileURLWithPath: arguments[2])
        do {
            let data = try Data(contentsOf: manifestURL)
            let manifest = try JSONDecoder().decode(
                UpdateInstallerManifest.self,
                from: data
            )
            try markReady(manifest.readinessFileURL)
            try apply(manifest)
        } catch {
            NSLog("OmniDock update installation failed: %@", error.localizedDescription)
        }
        return true
    }

    private static func markReady(_ url: URL) throws {
        try Data().write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    private static func apply(_ manifest: UpdateInstallerManifest) throws {
        guard waitForProcessToExit(manifest.currentProcessIdentifier) else {
            throw UpdatePackageError.installationUnavailable
        }
        terminateFinderExtension()

        guard let expectedVersion = SemanticVersion(manifest.expectedVersion)
        else {
            throw UpdatePackageError.versionMismatch
        }

        let fileManager = FileManager.default
        let targetURL = manifest.targetAppURL.resolvingSymlinksInPath()
        let stagedURL = manifest.stagedAppURL.resolvingSymlinksInPath()
        let cleanupURL = manifest.cleanupDirectoryURL.resolvingSymlinksInPath()
        guard targetURL.pathExtension == "app",
              Bundle(url: targetURL)?.bundleIdentifier
                == UpdateBundleValidator.bundleIdentifier,
              isDescendant(stagedURL, of: cleanupURL),
              fileManager.isWritableFile(
                atPath: targetURL.deletingLastPathComponent().path
              ),
              let installedVersionText = Bundle(url: targetURL)?.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
              ) as? String,
              let installedVersion = SemanticVersion(installedVersionText),
              expectedVersion > installedVersion
        else {
            throw UpdatePackageError.installationUnavailable
        }
        try UpdateBundleValidator.validate(
            appURL: targetURL,
            expectedVersion: installedVersion,
            designatedRequirement: manifest.designatedRequirement,
            assessGatekeeper: false
        )

        let parentURL = targetURL.deletingLastPathComponent()
        let identifier = UUID().uuidString
        let incomingURL = parentURL.appendingPathComponent(
            ".OmniDock.update-\(identifier).app",
            isDirectory: true
        )
        let copyResult = ProcessResult.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: [stagedURL.path, incomingURL.path]
        )
        guard copyResult.status == 0 else {
            throw UpdatePackageError.replacementFailed
        }
        do {
            try UpdateBundleValidator.validate(
                appURL: incomingURL,
                expectedVersion: expectedVersion,
                designatedRequirement: manifest.designatedRequirement
            )
            do {
                try UpdateAtomicReplacement.perform(
                    targetURL: targetURL,
                    incomingURL: incomingURL,
                    launchAndConfirm: {
                        launchAndConfirm(appURL: targetURL)
                    }
                )
            } catch {
                if error as? UpdatePackageError == .relaunchFailed {
                    _ = launch(appURL: targetURL)
                }
                throw error
            }
            try? fileManager.removeItem(at: cleanupURL)
        } catch {
            try? fileManager.removeItem(at: incomingURL)
            throw error
        }
    }

    private static func isDescendant(_ url: URL, of directoryURL: URL) -> Bool {
        let directoryPath = directoryURL.standardizedFileURL.path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let candidatePath = url.standardizedFileURL.path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return candidatePath.hasPrefix(directoryPath + "/")
    }

    private static func waitForProcessToExit(
        _ processIdentifier: Int32
    ) -> Bool {
        let deadline = Date().addingTimeInterval(30)
        while kill(processIdentifier, 0) == 0, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        return kill(processIdentifier, 0) != 0
    }

    private static func terminateFinderExtension() {
        let bundleIdentifier = "com.quanzhankeji.OmniDock.FinderSync"
        for application in NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        ) {
            _ = application.terminate()
        }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let running = NSRunningApplication.runningApplications(
                withBundleIdentifier: bundleIdentifier
            )
            if running.isEmpty {
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    private static func launchAndConfirm(appURL: URL) -> Bool {
        guard launch(appURL: appURL) else {
            return false
        }
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let applications = NSRunningApplication.runningApplications(
                withBundleIdentifier: UpdateBundleValidator.bundleIdentifier
            )
            if applications.contains(where: {
                $0.bundleURL?.resolvingSymlinksInPath()
                    == appURL.resolvingSymlinksInPath()
            }) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    private static func launch(appURL: URL) -> Bool {
        ProcessResult.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/open"),
            arguments: ["-n", appURL.path]
        ).status == 0
    }
}

struct ProcessResult {
    let status: Int32
    let standardError: String

    static func run(executableURL: URL, arguments: [String]) -> ProcessResult {
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            return ProcessResult(
                status: process.terminationStatus,
                standardError: String(data: data, encoding: .utf8) ?? ""
            )
        } catch {
            return ProcessResult(
                status: -1,
                standardError: error.localizedDescription
            )
        }
    }
}
