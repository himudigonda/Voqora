import Combine
import Foundation
import Sparkle

/// Owns Sparkle's standard updater for the lifetime of the app.
///
/// Sparkle handles scheduled checks, signed appcast parsing, archive
/// verification, replacement, and relaunch. The UI intentionally uses
/// Sparkle's native controller rather than reimplementing installer logic.
@MainActor
final class AppUpdater: NSObject, ObservableObject {
    private let controller: SPUStandardUpdaterController?

    override init() {
        if RuntimeEnvironment.isRunningTests {
            controller = nil
        } else {
            controller = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: nil,
                userDriverDelegate: nil
            )
        }
        super.init()
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}
