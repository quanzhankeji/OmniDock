import AppKit
#if SWIFT_PACKAGE
import OmniDockCore
#endif

@main
struct OmniDockMain {
    @MainActor
    static func main() {
        if UpdateInstallerCommand.runIfRequested(
            arguments: CommandLine.arguments
        ) {
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
