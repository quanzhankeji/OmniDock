import AppKit

struct ApplicationSelectionCandidate: Equatable, Hashable, Sendable {
    let displayName: String
    let bundleIdentifier: String?
    let bundleURL: URL
    let isSystemApplication: Bool

    var detailText: String {
        bundleIdentifier ?? bundleURL.path
    }
}

enum ApplicationSelectionCatalogError: Error, Equatable, Sendable {
    case directoryEnumerationFailed(path: String)
}

enum ApplicationSelectionCatalog {
    static var defaultSearchRoots: [URL] {
        [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true),
            URL(fileURLWithPath: "/System/Library/CoreServices", isDirectory: true),
            URL(fileURLWithPath: "/System/Library/CoreServices/Applications", isDirectory: true)
        ]
    }

    static func loadCandidates(
        searchRoots: [URL] = defaultSearchRoots,
        fileManager: FileManager = .default,
        cancellationCheck: () throws -> Void = { try Task.checkCancellation() }
    ) throws -> [ApplicationSelectionCandidate] {
        var candidates: [ApplicationSelectionCandidate] = []
        var seenKeys = Set<String>()
        var didEnumerateSearchRoot = false
        var firstEnumerationFailure: ApplicationSelectionCatalogError?

        for root in searchRoots where fileManager.fileExists(atPath: root.path) {
            try cancellationCheck()
            let appURLs: [URL]
            do {
                appURLs = try applicationBundleURLs(
                    in: root,
                    fileManager: fileManager,
                    cancellationCheck: cancellationCheck
                )
                didEnumerateSearchRoot = true
            } catch let error as ApplicationSelectionCatalogError {
                if firstEnumerationFailure == nil {
                    firstEnumerationFailure = error
                }
                continue
            }

            for appURL in appURLs {
                try cancellationCheck()
                guard let candidate = makeCandidate(for: appURL, root: root, fileManager: fileManager) else {
                    continue
                }

                let key = candidate.bundleIdentifier?.lowercased() ?? candidate.bundleURL.standardizedFileURL.path
                guard seenKeys.insert(key).inserted else {
                    continue
                }
                candidates.append(candidate)
            }
        }

        try cancellationCheck()
        if !didEnumerateSearchRoot, let firstEnumerationFailure {
            throw firstEnumerationFailure
        }
        return candidates.sorted { lhs, rhs in
            let nameComparison = lhs.displayName.localizedStandardCompare(rhs.displayName)
            if nameComparison != .orderedSame {
                return nameComparison == .orderedAscending
            }
            return lhs.bundleURL.path.localizedStandardCompare(rhs.bundleURL.path) == .orderedAscending
        }
    }

    private static func applicationBundleURLs(
        in root: URL,
        fileManager: FileManager,
        cancellationCheck: () throws -> Void
    ) throws -> [URL] {
        var urls: [URL] = []
        var failedPath: String?
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { url, _ in
                failedPath = url.path
                return false
            }
        ) else {
            throw ApplicationSelectionCatalogError.directoryEnumerationFailed(path: root.path)
        }

        for case let url as URL in enumerator {
            try cancellationCheck()
            guard url.pathExtension == "app" else {
                continue
            }
            urls.append(url)
            enumerator.skipDescendants()
        }

        if let failedPath {
            throw ApplicationSelectionCatalogError.directoryEnumerationFailed(path: failedPath)
        }
        return urls
    }

    private static func makeCandidate(
        for url: URL,
        root: URL,
        fileManager: FileManager
    ) -> ApplicationSelectionCandidate? {
        guard let bundle = Bundle(url: url) else {
            return nil
        }

        let packageType = bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String
        guard packageType == "APPL" || packageType == "FNDR" else {
            return nil
        }

        let displayName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? fileManager.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        let standardizedURL = url.standardizedFileURL
        return ApplicationSelectionCandidate(
            displayName: displayName,
            bundleIdentifier: bundle.bundleIdentifier,
            bundleURL: standardizedURL,
            isSystemApplication: standardizedURL.path.hasPrefix("/System/")
                || root.standardizedFileURL.path.hasPrefix("/System/")
        )
    }
}

@MainActor
protocol ApplicationSelectionLoading: AnyObject {
    func loadCandidates() async throws -> [ApplicationSelectionCandidate]
    func cancel()
}

@MainActor
final class ApplicationSelectionCatalogLoader: ApplicationSelectionLoading {
    private let searchRoots: [URL]
    private let fileManagerFactory: @Sendable () -> FileManager
    private var scanTask: Task<[ApplicationSelectionCandidate], Error>?
    private var generation: UInt = 0

    init(
        searchRoots: [URL] = ApplicationSelectionCatalog.defaultSearchRoots,
        fileManagerFactory: @escaping @Sendable () -> FileManager = { FileManager() }
    ) {
        self.searchRoots = searchRoots
        self.fileManagerFactory = fileManagerFactory
    }

    func loadCandidates() async throws -> [ApplicationSelectionCandidate] {
        cancelScan()
        generation &+= 1
        let currentGeneration = generation
        let searchRoots = searchRoots
        let fileManagerFactory = fileManagerFactory
        let task = Task.detached(priority: .userInitiated) {
            try ApplicationSelectionCatalog.loadCandidates(
                searchRoots: searchRoots,
                fileManager: fileManagerFactory()
            )
        }
        scanTask = task

        defer {
            if generation == currentGeneration {
                scanTask = nil
            }
        }

        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func cancel() {
        generation &+= 1
        cancelScan()
    }

    private func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
    }
}
