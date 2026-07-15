import XCTest
@testable import OmniDockCore

@MainActor
final class ApplicationSelectionCatalogTests: XCTestCase {
    func testDefaultSearchRootsIncludeSystemApplicationLocations() {
        let paths = ApplicationSelectionCatalog.defaultSearchRoots.map(\.path)

        XCTAssertTrue(paths.contains("/Applications"))
        XCTAssertTrue(paths.contains("/System/Applications"))
        XCTAssertTrue(paths.contains("/System/Library/CoreServices"))
    }

    func testCatalogFindsFinderFromSystemCoreServices() throws {
        let candidates = try ApplicationSelectionCatalog.loadCandidates()
        let finder = try XCTUnwrap(candidates.first {
            $0.bundleIdentifier == "com.apple.finder"
        })

        XCTAssertEqual(finder.displayName, "Finder")
        XCTAssertEqual(finder.bundleURL.lastPathComponent, "Finder.app")
        XCTAssertTrue(finder.isSystemApplication)
    }

    func testCatalogLoadsApplicationBundlesRecursively() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let app = root
            .appendingPathComponent("Utilities", isDirectory: true)
            .appendingPathComponent("Example.app", isDirectory: true)
        try makeApplicationBundle(
            at: app,
            displayName: "Example",
            bundleIdentifier: "com.example.Example",
            packageType: "APPL"
        )

        let candidates = try ApplicationSelectionCatalog.loadCandidates(searchRoots: [root])

        XCTAssertEqual(candidates.map(\.displayName), ["Example"])
        XCTAssertEqual(candidates.first?.bundleIdentifier, "com.example.Example")
    }

    func testCatalogKeepsFinderPackageType() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let finder = root.appendingPathComponent("Finder.app", isDirectory: true)
        try makeApplicationBundle(
            at: finder,
            displayName: "Finder",
            bundleIdentifier: "com.apple.finder",
            packageType: "FNDR"
        )

        let candidates = try ApplicationSelectionCatalog.loadCandidates(searchRoots: [root])

        XCTAssertEqual(candidates.map(\.bundleIdentifier), ["com.apple.finder"])
    }

    func testCatalogDeduplicatesByBundleIdentifier() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try makeApplicationBundle(
            at: root.appendingPathComponent("First.app", isDirectory: true),
            displayName: "First",
            bundleIdentifier: "com.example.Duplicate",
            packageType: "APPL"
        )
        try makeApplicationBundle(
            at: root.appendingPathComponent("Second.app", isDirectory: true),
            displayName: "Second",
            bundleIdentifier: "com.example.Duplicate",
            packageType: "APPL"
        )

        let candidates = try ApplicationSelectionCatalog.loadCandidates(searchRoots: [root])

        XCTAssertEqual(candidates.count, 1)
    }

    func testCatalogPreservesSearchRootPriorityWhenDeduplicating() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let firstRoot = directory.appendingPathComponent("First", isDirectory: true)
        let secondRoot = directory.appendingPathComponent("Second", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let preferredURL = firstRoot.appendingPathComponent("Preferred.app", isDirectory: true)
        try makeApplicationBundle(
            at: preferredURL,
            displayName: "Preferred",
            bundleIdentifier: "com.example.Priority",
            packageType: "APPL"
        )
        try makeApplicationBundle(
            at: secondRoot.appendingPathComponent("Fallback.app", isDirectory: true),
            displayName: "Fallback",
            bundleIdentifier: "com.example.Priority",
            packageType: "APPL"
        )

        let candidates = try ApplicationSelectionCatalog.loadCandidates(searchRoots: [firstRoot, secondRoot])

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?.bundleURL, preferredURL.standardizedFileURL)
    }

    func testCatalogRejectsBundlesThatAreNotApplicationsOrFinder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try makeApplicationBundle(
            at: root.appendingPathComponent("NotAnApp.app", isDirectory: true),
            displayName: "Not an App",
            bundleIdentifier: "com.example.NotAnApp",
            packageType: "BNDL"
        )

        let candidates = try ApplicationSelectionCatalog.loadCandidates(searchRoots: [root])

        XCTAssertTrue(candidates.isEmpty)
    }

    func testCatalogReportsDirectoryEnumerationFailure() throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        XCTAssertThrowsError(try ApplicationSelectionCatalog.loadCandidates(searchRoots: [fileURL])) { error in
            XCTAssertEqual(
                error as? ApplicationSelectionCatalogError,
                .directoryEnumerationFailed(path: fileURL.path)
            )
        }
    }

    func testCatalogKeepsResultsWhenAnotherSearchRootCannotBeEnumerated() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let failedRoot = directory.appendingPathComponent("NotADirectory")
        let validRoot = directory.appendingPathComponent("Applications", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data().write(to: failedRoot)
        try makeApplicationBundle(
            at: validRoot.appendingPathComponent("Available.app", isDirectory: true),
            displayName: "Available",
            bundleIdentifier: "com.example.Available",
            packageType: "APPL"
        )

        let candidates = try ApplicationSelectionCatalog.loadCandidates(
            searchRoots: [failedRoot, validRoot]
        )

        XCTAssertEqual(candidates.map(\.displayName), ["Available"])
    }

    func testCatalogStopsWhenCancellationIsRequested() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try makeApplicationBundle(
            at: root.appendingPathComponent("Example.app", isDirectory: true),
            displayName: "Example",
            bundleIdentifier: "com.example.Cancelled",
            packageType: "APPL"
        )
        var cancellationCheckCount = 0

        XCTAssertThrowsError(
            try ApplicationSelectionCatalog.loadCandidates(
                searchRoots: [root],
                cancellationCheck: {
                    cancellationCheckCount += 1
                    if cancellationCheckCount == 2 {
                        throw CancellationError()
                    }
                }
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(cancellationCheckCount, 2)
    }

    func testCandidateCanCrossConcurrencyDomains() {
        requireSendable(ApplicationSelectionCandidate.self)
    }

    func testLoaderRunsCatalogScanOutsideMainActor() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try makeApplicationBundle(
            at: root.appendingPathComponent("Background.app", isDirectory: true),
            displayName: "Background",
            bundleIdentifier: "com.example.Background",
            packageType: "APPL"
        )
        let fileManager = ThreadRecordingFileManager()
        let loader = ApplicationSelectionCatalogLoader(
            searchRoots: [root],
            fileManagerFactory: { fileManager }
        )

        let candidates = try await loader.loadCandidates()

        XCTAssertEqual(candidates.map(\.displayName), ["Background"])
        XCTAssertEqual(fileManager.mainThreadObservations, [false])
    }

    private func requireSendable<T: Sendable>(_ type: T.Type) {}

    private func makeApplicationBundle(
        at url: URL,
        displayName: String,
        bundleIdentifier: String,
        packageType: String
    ) throws {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: NSDictionary = [
            "CFBundleDisplayName": displayName,
            "CFBundleName": displayName,
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundlePackageType": packageType
        ]
        try info.write(to: contents.appendingPathComponent("Info.plist"))
    }
}

private final class ThreadRecordingFileManager: FileManager, @unchecked Sendable {
    private let observationLock = NSLock()
    private var observations: [Bool] = []

    var mainThreadObservations: [Bool] {
        observationLock.lock()
        defer { observationLock.unlock() }
        return observations
    }

    override func fileExists(atPath path: String) -> Bool {
        observationLock.lock()
        observations.append(Thread.isMainThread)
        observationLock.unlock()
        return super.fileExists(atPath: path)
    }
}
