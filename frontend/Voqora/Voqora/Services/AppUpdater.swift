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
    private var observations: [NSKeyValueObservation] = []

    /// Mirror Sparkle's persisted user choices so Preferences can explain what
    /// will happen instead of hiding update behaviour behind a background
    /// framework.
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var canCheckForUpdates = false

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
        observeUpdaterState()
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        controller?.checkForUpdates(nil)
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        guard let updater = controller?.updater else { return }
        updater.automaticallyChecksForUpdates = enabled
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
    }

    private func observeUpdaterState() {
        guard let updater = controller?.updater else { return }
        observations = [
            updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                MainActor.assumeIsolated {
                    self?.automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
                }
            },
            updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                MainActor.assumeIsolated {
                    self?.canCheckForUpdates = updater.canCheckForUpdates
                }
            },
        ]
    }
}
