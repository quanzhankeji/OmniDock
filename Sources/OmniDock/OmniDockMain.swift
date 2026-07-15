import AppKit
#if SWIFT_PACKAGE
import OmniDockCore
#endif

@main
struct OmniDockMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
