import AppKit
import ApplicationServices
import CoreGraphics
import FinderSync

public struct PermissionSnapshot: Equatable {
    public let accessibility: Bool
    public let screenRecording: Bool
    public let inputMonitoring: Bool
    public let finderExtension: Bool
    public let folderAccess: Bool

    public init(
        accessibility: Bool,
        screenRecording: Bool,
        inputMonitoring: Bool,
        finderExtension: Bool = false,
        folderAccess: Bool = false
    ) {
        self.accessibility = accessibility
        self.screenRecording = screenRecording
        self.inputMonitoring = inputMonitoring
        self.finderExtension = finderExtension
        self.folderAccess = folderAccess
    }
}

public enum PermissionKind: CaseIterable, Hashable {
    case accessibility
    case screenRecording
    case inputMonitoring
    case finderExtension
    case folderAccess

    public var title: String {
        AppStrings.permissionTitle(self)
    }
}

public final class PermissionService {
    public static let changedNotification = Notification.Name("OmniDockPermissionServiceChanged")

    private let directoryGrantStore: FinderDirectoryGrantStore

    public init() {
        directoryGrantStore = FinderDirectoryGrantStore()
    }

    public func snapshot() -> PermissionSnapshot {
        PermissionSnapshot(
            accessibility: isAccessibilityTrusted(prompt: false),
            screenRecording: CGPreflightScreenCaptureAccess(),
            inputMonitoring: CGPreflightListenEventAccess(),
            finderExtension: FinderExtensionActivation.isEnabledInFinder,
            folderAccess: directoryGrantStore.hasUsableGrant()
        )
    }

    public func openPrivacySettings(for kind: PermissionKind) {
        let anchor: String
        switch kind {
        case .accessibility:
            anchor = "Privacy_Accessibility"
        case .screenRecording:
            anchor = "Privacy_ScreenCapture"
        case .inputMonitoring:
            anchor = "Privacy_ListenEvent"
        case .finderExtension:
            FinderExtensionActivation.showManagementInterface()
            return
        case .folderAccess:
            requestFolderAccess()
            return
        }

        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
        }
    }

    public func isGranted(_ kind: PermissionKind, in snapshot: PermissionSnapshot) -> Bool {
        switch kind {
        case .accessibility:
            return snapshot.accessibility
        case .screenRecording:
            return snapshot.screenRecording
        case .inputMonitoring:
            return snapshot.inputMonitoring
        case .finderExtension:
            return snapshot.finderExtension
        case .folderAccess:
            return snapshot.folderAccess
        }
    }

    @discardableResult
    public func relaunchApp() -> Bool {
        guard scheduleRelaunchAfterTermination() else {
            return false
        }
        NSApp.terminate(nil)
        return true
    }

    @discardableResult
    func scheduleRelaunchAfterTermination() -> Bool {
        let processIdentifier = ProcessInfo.processInfo.processIdentifier
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = [
            "-c",
            """
            for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42 43 44 45 46 47 48 49 50; do
                if ! /bin/kill -0 \(processIdentifier) >/dev/null 2>&1; then
                    break
                fi
                /bin/sleep 0.1
            done
            /usr/bin/open "$1"
            """,
            "omnidock-relauncher",
            Bundle.main.bundleURL.path
        ]

        do {
            try task.run()
            return true
        } catch {
            return false
        }
    }

    private func isAccessibilityTrusted(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private func requestFolderAccess() {
        let panel = NSOpenPanel()
        panel.title = AppStrings.text(.folderAccessPanelTitle)
        panel.message = AppStrings.text(.folderAccessPanelDetail)
        panel.prompt = AppStrings.text(.folderAccessPanelChoose)
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser

        panel.begin { [weak self] response in
            guard response == .OK,
                  let directory = panel.url
            else {
                return
            }
            try? self?.directoryGrantStore.remember(directory: directory)
            NotificationCenter.default.post(name: Self.changedNotification, object: self)
        }
    }
}
