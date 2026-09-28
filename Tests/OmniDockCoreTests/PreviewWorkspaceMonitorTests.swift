import AppKit
import XCTest
@testable import OmniDockCore

@MainActor
final class PreviewWorkspaceMonitorTests: XCTestCase {
    func testDisplayChangesUseApplicationCenterAndDoNotResumeSuspension() {
        let workspace = NotificationCenter()
        let application = NotificationCenter()
        var changes = 0
        var suspensions: [Bool] = []
        let monitor = PreviewWorkspaceMonitor(
            notificationCenter: workspace, applicationNotificationCenter: application,
            onDisplayConfigurationChanged: { changes += 1 }, onSuspensionChanged: { suspensions.append($0) }
        )
        monitor.start()
        monitor.start()
        defer { monitor.stop() }
        workspace.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        XCTAssertEqual(changes, 0)
        workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        application.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        application.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        XCTAssertEqual(changes, 2)
        XCTAssertTrue(monitor.isSuspended)
        XCTAssertEqual(suspensions, [true])
        monitor.stop()
        application.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        XCTAssertEqual(changes, 2)
        monitor.start()
        application.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        XCTAssertEqual(changes, 3)
    }

    private let pauses = [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                          NSWorkspace.sessionDidResignActiveNotification]
    private let resumes = [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                           NSWorkspace.sessionDidBecomeActiveNotification]

    func testOverlappingInterruptionsResumeOnlyAfterEveryReasonClears() {
        for order in [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]] {
            let center = NotificationCenter()
            var transitions: [Bool] = []
            let monitor = PreviewWorkspaceMonitor(notificationCenter: center) { transitions.append($0) }
            monitor.start()
            defer { monitor.stop() }
            for pause in pauses {
                center.post(name: pause, object: nil)
                center.post(name: pause, object: nil)
            }
            XCTAssertTrue(monitor.isSuspended)
            XCTAssertEqual(transitions, [true])
            for (step, index) in order.enumerated() {
                center.post(name: resumes[index], object: nil)
                XCTAssertEqual(monitor.isSuspended, step < 2)
                XCTAssertEqual(transitions, step < 2 ? [true] : [true, false])
            }
        }
    }

    func testStartStopAndUnmatchedWakeDoNotDuplicateOrResurrectCallbacks() {
        let center = NotificationCenter()
        var transitions: [Bool] = []
        let monitor = PreviewWorkspaceMonitor(notificationCenter: center) { transitions.append($0) }
        for index in pauses.indices {
            monitor.start()
            monitor.start()
            center.post(name: resumes[index], object: nil)
            let count = transitions.count
            center.post(name: pauses[index], object: nil)
            XCTAssertEqual(transitions.count, count + 1)
            monitor.stop()
            monitor.stop()
            center.post(name: resumes[index], object: nil)
            center.post(name: pauses[index], object: nil)
            XCTAssertFalse(monitor.isSuspended)
            XCTAssertEqual(transitions.count, count + 1)
        }
        XCTAssertEqual(transitions, [true, true, true])
    }
}
