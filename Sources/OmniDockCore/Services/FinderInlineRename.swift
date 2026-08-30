import AppKit
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

struct FinderInlineRenameActivator {
    var frontmostBundleIdentifier: () -> String? = {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }
    var isSecureInputEnabled: () -> Bool = { IsSecureEventInputEnabled() }
    var postReturnKey: () -> Void = FinderInlineRenameActivator.postReturn
    var now: () -> Date = Date.init
    var schedule: (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func begin() {
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

    // Posting needs the accessibility permission the clipboard palette already
    // asks for. Without it the event is dropped by the system and the file just
    // stays selected, which is why nothing here reports a failure.
    private static func postReturn() {
        guard let source = CGEventSource(stateID: .combinedSessionState),
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
        keyDown.post(tap: .cgAnnotatedSessionEventTap)
        keyUp.post(tap: .cgAnnotatedSessionEventTap)
    }
}
