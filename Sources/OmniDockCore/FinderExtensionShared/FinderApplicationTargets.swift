import AppKit
import CoreServices

// Both processes need the same answer about a configured application: the
// extension decides whether to offer it in the menu, and the containing app
// decides what to launch. Keeping the rules here stops the two from drifting,
// which is how the menu ended up hiding applications the app could have opened.
enum FinderApplicationTargetResolver {
    static func resolve(
        shortcut: FinderLaunchShortcut,
        fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:),
        installedApplicationURL: (String) -> URL? = { bundleIdentifier in
            NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: bundleIdentifier
            )
        }
    ) -> URL? {
        // The stored path is only a hint: it is the location the shortcut was
        // created from. An application moved to ~/Applications, renamed, or
        // installed somewhere else is still found by its bundle identifier.
        if let storedURL = shortcut.bundleURL,
           fileExists(storedURL.path) {
            return storedURL
        }
        guard let bundleIdentifier = shortcut.bundleIdentifier else {
            return nil
        }
        return installedApplicationURL(bundleIdentifier)
    }
}

// This menu hands a folder to an application. Applications that only take
// single documents do nothing useful with one, so they are left out rather than
// offered as a command that quietly fails.
//
// LaunchServices is asked directly instead of reading the application's
// document types: it needs no access to the application bundle, so it answers
// the same way from the sandboxed extension, and it recognises terminals.
// NSWorkspace's list of handlers for a folder is not usable here - it omits
// Terminal.app, which is one of the applications people most want.
enum FinderApplicationDirectorySupport {
    static func acceptsDirectories(
        applicationURL: URL,
        directoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        var accepts: DarwinBoolean = false
        let status = LSCanURLAcceptURL(
            directoryURL as CFURL,
            applicationURL as CFURL,
            .all,
            .acceptDefault,
            &accepts
        )
        guard status == noErr else {
            // An application LaunchServices cannot answer for is still offered:
            // hiding a working command is worse than offering one that fails
            // visibly.
            return true
        }
        return accepts.boolValue
    }
}
