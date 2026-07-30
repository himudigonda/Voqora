import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    /// Installed by `VoqoraApp` with the exact `BackendService` instance this
    /// app launched. Never terminate a server merely because it shares a name.
    var stopOwnedBackend: (() -> Void)?

    func applicationWillTerminate(_: Notification) {
        stopOwnedBackend?()
    }
}
