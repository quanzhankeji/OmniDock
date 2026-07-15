import AppKit
import XCTest
@testable import OmniDockCore

@MainActor
final class ApplicationPickerWindowControllerTests: XCTestCase {
    func testIconLoaderReadsIconsOutsideMainThread() async {
        let recorder = ApplicationPickerIconThreadRecorder()
        let loader = ApplicationPickerIconLoader { _ in
            recorder.record(Thread.isMainThread)
            return NSImage(size: CGSize(width: 32, height: 32))
        }
        let loaded = expectation(description: "icon loaded")

        loader.loadIcon(atPath: "/Applications/Example.app") { icon in
            XCTAssertEqual(icon.size, CGSize(width: 32, height: 32))
            loaded.fulfill()
        }

        await fulfillment(of: [loaded], timeout: 2)
        XCTAssertEqual(recorder.values, [false])
    }

    func testSuccessfulLoadsEnterContentAndEmptyStates() async {
        _ = NSApplication.shared
        let loader = ControlledApplicationSelectionLoader()
        let controller = makeController(loader: loader)

        controller.reloadCandidates()
        XCTAssertEqual(controller.contentState, .loading)
        await waitUntil { loader.pendingRequestIDs == [0] }

        loader.succeed(requestID: 0, with: [candidate(named: "Example")])
        await waitUntil { controller.contentState == .content }

        XCTAssertEqual(controller.allCandidates.map(\.displayName), ["Example"])
        XCTAssertEqual(controller.filteredCandidates.map(\.displayName), ["Example"])

        controller.reloadCandidates()
        await waitUntil { loader.pendingRequestIDs == [1] }
        loader.succeed(requestID: 1, with: [])
        await waitUntil { controller.contentState == .empty }

        XCTAssertTrue(controller.allCandidates.isEmpty)
        XCTAssertTrue(controller.filteredCandidates.isEmpty)
    }

    func testFailureShowsFailedStateAndRetryStartsFreshLoad() async throws {
        _ = NSApplication.shared
        let loader = ControlledApplicationSelectionLoader()
        let controller = makeController(loader: loader)

        controller.reloadCandidates()
        await waitUntil { loader.pendingRequestIDs == [0] }
        loader.fail(requestID: 0)
        await waitUntil { controller.contentState == .failed }

        let contentView = try XCTUnwrap(controller.window?.contentView)
        let retryButton = try XCTUnwrap(button(withAction: "retryLoading:", in: contentView))
        XCTAssertEqual(retryButton.title, AppStrings.text(.pickerRetry))

        retryButton.performClick(nil)
        XCTAssertEqual(controller.contentState, .loading)
        await waitUntil { loader.pendingRequestIDs == [1] }

        loader.succeed(requestID: 1, with: [candidate(named: "Retried")])
        await waitUntil { controller.contentState == .content }

        XCTAssertEqual(controller.allCandidates.map(\.displayName), ["Retried"])
    }

    func testCancellationRejectsResultFromCancelledGeneration() async {
        _ = NSApplication.shared
        let loader = ControlledApplicationSelectionLoader()
        let controller = makeController(loader: loader)

        controller.reloadCandidates()
        await waitUntil { loader.pendingRequestIDs == [0] }
        controller.invalidateCandidateLoading()

        loader.succeed(requestID: 0, with: [candidate(named: "Late")])
        await Task.yield()

        XCTAssertGreaterThan(loader.cancellationCount, 0)
        XCTAssertTrue(controller.allCandidates.isEmpty)
        XCTAssertTrue(controller.filteredCandidates.isEmpty)
        XCTAssertEqual(controller.contentState, .loading)
    }

    func testLateRetryResultCannotReplaceCurrentGeneration() async {
        _ = NSApplication.shared
        let loader = ControlledApplicationSelectionLoader()
        let controller = makeController(loader: loader)

        controller.reloadCandidates()
        await waitUntil { loader.pendingRequestIDs == [0] }
        controller.reloadCandidates()
        await waitUntil { loader.pendingRequestIDs == [0, 1] }

        loader.succeed(requestID: 1, with: [candidate(named: "Current")])
        await waitUntil { controller.allCandidates.map(\.displayName) == ["Current"] }

        loader.succeed(requestID: 0, with: [candidate(named: "Stale")])
        await Task.yield()

        XCTAssertEqual(controller.contentState, .content)
        XCTAssertEqual(controller.allCandidates.map(\.displayName), ["Current"])
    }

    func testReopenedLoadRejectsResultFromClosedGeneration() async {
        _ = NSApplication.shared
        let loader = ControlledApplicationSelectionLoader()
        let controller = makeController(loader: loader)

        controller.reloadCandidates()
        await waitUntil { loader.pendingRequestIDs == [0] }
        controller.invalidateCandidateLoading()
        controller.reloadCandidates()
        await waitUntil { loader.pendingRequestIDs == [0, 1] }

        loader.succeed(requestID: 1, with: [candidate(named: "Reopened")])
        await waitUntil { controller.allCandidates.map(\.displayName) == ["Reopened"] }

        loader.succeed(requestID: 0, with: [candidate(named: "Closed")])
        await Task.yield()

        XCTAssertEqual(controller.contentState, .content)
        XCTAssertEqual(controller.allCandidates.map(\.displayName), ["Reopened"])
    }

    func testSearchAndAlreadyBoundSelectionBehaviorRemainUnchanged() async throws {
        _ = NSApplication.shared
        let alpha = candidate(named: "Alpha", bundleIdentifier: "com.example.Alpha")
        let beta = candidate(named: "Beta", bundleIdentifier: "com.example.Beta")
        let binding = AppHotkeyBinding(
            appName: alpha.displayName,
            bundleURLString: alpha.bundleURL.absoluteString,
            bundleIdentifier: alpha.bundleIdentifier
        )
        let loader = ControlledApplicationSelectionLoader()
        let controller = makeController(existingBindings: [binding], loader: loader)

        controller.reloadCandidates()
        await waitUntil { loader.pendingRequestIDs == [0] }
        loader.succeed(requestID: 0, with: [alpha, beta])
        await waitUntil { controller.contentState == .content }

        let contentView = try XCTUnwrap(controller.window?.contentView)
        let tableView = try XCTUnwrap(firstSubview(of: NSTableView.self, in: contentView))
        XCTAssertFalse(controller.tableView(tableView, shouldSelectRow: 0))
        XCTAssertTrue(controller.tableView(tableView, shouldSelectRow: 1))

        let searchField = try XCTUnwrap(firstSubview(of: NSSearchField.self, in: contentView))
        searchField.stringValue = "beta"
        searchField.sendAction(searchField.action, to: searchField.target)

        XCTAssertEqual(controller.contentState, .content)
        XCTAssertEqual(controller.filteredCandidates.map(\.displayName), ["Beta"])
    }

    private func makeController(
        existingBindings: [AppHotkeyBinding] = [],
        loader: ApplicationSelectionLoading
    ) -> ApplicationPickerWindowController {
        ApplicationPickerWindowController(
            existingBindings: existingBindings,
            loader: loader,
            onSelect: { _ in },
            onClose: {}
        )
    }

    private func candidate(
        named name: String,
        bundleIdentifier: String? = nil
    ) -> ApplicationSelectionCandidate {
        ApplicationSelectionCandidate(
            displayName: name,
            bundleIdentifier: bundleIdentifier ?? "com.example.\(name)",
            bundleURL: URL(fileURLWithPath: "/Applications/\(name).app"),
            isSystemApplication: false
        )
    }

    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<1_000 {
            if condition() {
                return
            }
            await Task.yield()
        }
        XCTFail("Condition was not met", file: file, line: line)
    }

    private func button(withAction actionName: String, in view: NSView) -> NSButton? {
        if let button = view as? NSButton,
           let action = button.action,
           NSStringFromSelector(action) == actionName {
            return button
        }

        for subview in view.subviews {
            if let button = button(withAction: actionName, in: subview) {
                return button
            }
        }
        return nil
    }

    private func firstSubview<View: NSView>(of type: View.Type, in view: NSView) -> View? {
        if let matchingView = view as? View {
            return matchingView
        }
        for subview in view.subviews {
            if let matchingView = firstSubview(of: type, in: subview) {
                return matchingView
            }
        }
        return nil
    }
}

private final class ApplicationPickerIconThreadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedValues: [Bool] = []

    var values: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return recordedValues
    }

    func record(_ value: Bool) {
        lock.lock()
        recordedValues.append(value)
        lock.unlock()
    }
}

@MainActor
private final class ControlledApplicationSelectionLoader: ApplicationSelectionLoading {
    private struct PendingRequest {
        let id: Int
        let continuation: CheckedContinuation<[ApplicationSelectionCandidate], Error>
    }

    private var nextRequestID = 0
    private var pendingRequests: [PendingRequest] = []
    private(set) var cancellationCount = 0

    var pendingRequestIDs: [Int] {
        pendingRequests.map(\.id)
    }

    func loadCandidates() async throws -> [ApplicationSelectionCandidate] {
        let requestID = nextRequestID
        nextRequestID += 1
        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests.append(PendingRequest(id: requestID, continuation: continuation))
        }
    }

    func cancel() {
        cancellationCount += 1
    }

    func succeed(requestID: Int, with candidates: [ApplicationSelectionCandidate]) {
        takeRequest(id: requestID)?.continuation.resume(returning: candidates)
    }

    func fail(requestID: Int) {
        takeRequest(id: requestID)?.continuation.resume(throwing: TestFailure.expected)
    }

    private func takeRequest(id: Int) -> PendingRequest? {
        guard let index = pendingRequests.firstIndex(where: { $0.id == id }) else {
            XCTFail("Missing request \(id)")
            return nil
        }
        return pendingRequests.remove(at: index)
    }

    private enum TestFailure: Error {
        case expected
    }
}
