import Foundation

final class RuntimeActivityLease {
    private var token: NSObjectProtocol?

    func begin(reason: String) {
        guard token == nil else {
            return
        }
        token = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: reason
        )
    }

    func end() {
        guard let token else {
            return
        }
        ProcessInfo.processInfo.endActivity(token)
        self.token = nil
    }

    deinit {
        end()
    }
}
