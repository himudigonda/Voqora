import Combine
import Foundation
import Sparkle

/// Owns Voqora's future Sparkle updater configuration.
///
/// Non-notarized early-access builds intentionally use the GitHub Releases
/// page for manual installs. Sparkle remains wired for the notarized release
/// channel, but is not started until that trust boundary exists.
@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    /// Sparkle's public `SUNoUpdateError` value. Keep this isolated behind a
    /// small helper so the UI never calls an invalid feed or signature error
    /// “up to date.”
    private static let noUpdateErrorCode = 1001
    private var controller: SPUStandardUpdaterController?
    private var observations: [NSKeyValueObservation] = []

    /// Mirror Sparkle's persisted user choices so Preferences can explain what
    /// will happen instead of hiding update behaviour behind a background
    /// framework.
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var isCheckingForUpdates = false
    /// Short, user-facing state for Preferences. Sparkle still presents its
    /// native update sheet; this text only keeps a failed or completed check
    /// from looking like a button that silently did nothing.
    @Published private(set) var updateStatusMessage: String?

    override init() {
        super.init()
        controller = nil
        observeUpdaterState()
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        isCheckingForUpdates = true
        updateStatusMessage = nil
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

    // MARK: - Sparkle lifecycle

    static func statusMessage(forUpdateCheckError error: NSError) -> String {
        guard error.domain == SUSparkleErrorDomain,
              error.code == noUpdateErrorCode else {
            return "Couldn't check for updates. Your current Voqora still works. Try again later."
        }
        return "Voqora is up to date."
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        isCheckingForUpdates = false
        updateStatusMessage = "Update \(item.displayVersionString) is ready to review."
        PermissionsService.shared.scheduleNotification(
            title: "Update available",
            body: "Voqora \(item.displayVersionString) is ready to review."
        )
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        isCheckingForUpdates = false
        updateStatusMessage = Self.statusMessage(forUpdateCheckError: error as NSError)
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        isCheckingForUpdates = false
        updateStatusMessage = Self.statusMessage(forUpdateCheckError: error as NSError)
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        isCheckingForUpdates = false
        if let error {
            updateStatusMessage = Self.statusMessage(forUpdateCheckError: error as NSError)
        }
    }
}
