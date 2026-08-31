import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics

// A new document is born with a placeholder name, and the first thing anyone
// does is rename it. Finder exposes no way to start its inline editor, so the
// file is selected and a Return is delivered - the same key a person would
// press once the file is highlighted.
//
// The keystroke goes wherever keyboard focus happens to be, and revealing a
// file activates Finder asynchronously, so posting immediately can send a
// Return into whatever the user was doing. These rules hold it back until
// Finder actually owns focus and drop it otherwise: the file is created and
// selected either way, so the worst case is a rename the user starts by hand.
enum FinderInlineRenameStep: Equatable {
    case rename
    case wait
    case cancel
}

enum FinderInlineRenamePolicy {
    static let finderBundleIdentifier = "com.apple.finder"
    // Finder has to come forward and draw the revealed selection first. This is
    // longer than the clipboard palette's window because activating Finder can
    // mean opening a window, not just raising one.
    static let activationTimeout: TimeInterval = 1.0
    static let activationPollInterval: TimeInterval = 0.02

    static func step(
        frontmostBundleIdentifier: String?,
        isSecureInputEnabled: Bool,
        now: Date,
        deadline: Date
    ) -> FinderInlineRenameStep {
        // Secure input suppresses synthetic key events, so the Return would be
        // swallowed. Stop rather than poll until the deadline for nothing.
        guard !isSecureInputEnabled else {
            return .cancel
        }
        guard frontmostBundleIdentifier == finderBundleIdentifier else {
            return now < deadline ? .wait : .cancel
        }
        return .rename
    }
}

// Synthetic key events are dropped unless the app is trusted for accessibility.
// Without the permission the rename simply never starts, which looks like a
// broken feature, so ask for it - once per launch. Repeating the request every
// time a document is created would nag someone who has already decided against
// it, and the decision is theirs to make in System Settings.
private final class AccessibilityAuthorizationRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var hasAsked = false

    func isGranted() -> Bool {
        if AXIsProcessTrusted() {
            return true
        }
        lock.lock()
        let shouldAsk = !hasAsked
        hasAsked = true
        lock.unlock()
        guard shouldAsk else {
            return false
        }
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
    }
}

private let accessibilityAuthorization = AccessibilityAuthorizationRequest()

struct FinderInlineRenameActivator {
    var frontmostBundleIdentifier: () -> String? = {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }
    var isSecureInputEnabled: () -> Bool = { IsSecureEventInputEnabled() }
    var hasAccessibilityAccess: () -> Bool = { accessibilityAuthorization.isGranted() }
    // Revealing the file asks Finder to come forward, but that request competes
    // with whatever else is activating. Asking the application directly as well
    // makes the difference between a rename that starts and one that times out
    // waiting for a Finder that never quite arrives.
    var bringFinderForward: () -> Void = {
        NSRunningApplication.runningApplications(
            withBundleIdentifier: FinderInlineRenamePolicy.finderBundleIdentifier
        ).first?.activate(options: [])
    }
    var postReturnKey: () -> Void = FinderInlineRenameActivator.postReturn
    var now: () -> Date = Date.init
    var schedule: (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func begin() {
        guard !isSecureInputEnabled(), hasAccessibilityAccess() else {
            return
        }
        bringFinderForward()
        waitForFinder(
            deadline: now().addingTimeInterval(
                FinderInlineRenamePolicy.activationTimeout
            )
        )
    }

    private func waitForFinder(deadline: Date) {
        switch FinderInlineRenamePolicy.step(
            frontmostBundleIdentifier: frontmostBundleIdentifier(),
            isSecureInputEnabled: isSecureInputEnabled(),
            now: now(),
            deadline: deadline
        ) {
        case .rename:
            postReturnKey()
        case .wait:
            schedule(FinderInlineRenamePolicy.activationPollInterval) {
                waitForFinder(deadline: deadline)
            }
        case .cancel:
            break
        }
    }

    // Posted at the HID layer, the level real hardware feeds into. A key put
    // onto the session tap instead is delivered inconsistently to another
    // application's window, which is exactly what this has to do.
    private static func postReturn() {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: CGKeyCode(kVK_Return),
                  keyDown: true
              ),
              let keyUp = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: CGKeyCode(kVK_Return),
                  keyDown: false
              )
        else {
            return
        }
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
