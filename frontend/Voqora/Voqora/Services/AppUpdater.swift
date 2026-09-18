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

    /// Set once `checkGitHubReleaseForUpdate()` finds a release newer than
    /// the running build. This is deliberately independent of Sparkle (which
    /// stays dormant until Voqora is notarized): it never downloads or
    /// installs anything, only tells the user a newer version exists and
    /// points at the releases page for a manual install.
    @Published private(set) var latestGitHubVersion: String?
    private static let latestReleaseAPIURL = URL(string: "https://api.github.com/repos/himudigonda/Voqora/releases/latest")!

    /// When the GitHub release check last completed a network round trip.
    private var lastGitHubCheck: Date?

    /// How long a completed check stays good enough. `VoqoraApp` already runs
    /// one at launch, so under normal use every later opportunistic check —
    /// notably the About tab's — is answered from this without touching the
    /// network at all.
    nonisolated static let gitHubCheckMinimumInterval: TimeInterval = 60 * 60

    /// Whether an opportunistic check is worth making. Pure and static so the
    /// throttle is testable without a network or a clock.
    nonisolated static func shouldCheckGitHubRelease(
        lastChecked: Date?,
        now: Date = Date(),
        minimumInterval: TimeInterval = gitHubCheckMinimumInterval
    ) -> Bool {
        guard let lastChecked else { return true }
        return now.timeIntervalSince(lastChecked) >= minimumInterval
    }

    /// The opportunistic entry point for UI that merely *displays* update
    /// state, as opposed to a button the user pressed meaning "check now".
    ///
    /// The About tab used to `await` the unthrottled check on every single
    /// visit, so re-opening a tab whose content was already fully determined
    /// re-issued a request with a 12-second timeout and made the screen feel
    /// like it was still loading. Nothing on that screen depends on the
    /// result arriving before it renders, and a release published seconds ago
    /// is not worth a network round trip per tab switch.
    func checkGitHubReleaseForUpdateIfStale() async {
        guard Self.shouldCheckGitHubRelease(lastChecked: lastGitHubCheck) else { return }
        await checkGitHubReleaseForUpdate()
    }

    private struct GitHubReleaseTag: Decodable {
        let tagName: String
        enum CodingKeys: String, CodingKey { case tagName = "tag_name" }
    }

    /// Fetches the latest published GitHub release tag and compares it
    /// against `CFBundleShortVersionString`. Schedules the same "Update
    /// available" notification Sparkle would have, so the user hears about
    /// it either way. Silently no-ops on any network/parsing failure — this
    /// is a courtesy check, not a required startup step.
    func checkGitHubReleaseForUpdate() async {
        guard NSClassFromString("XCTestCase") == nil else { return }
        guard let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String else { return }
        var request = URLRequest(url: Self.latestReleaseAPIURL)
        request.timeoutInterval = 12
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Voqora", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode),
              let release = try? JSONDecoder().decode(GitHubReleaseTag.self, from: data)
        else { return }
        // Stamped only on a real answer from GitHub: a failed or refused check
        // must not silence the next hour's worth of opportunistic retries.
        lastGitHubCheck = Date()

        let latest = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        guard Self.isVersion(latest, newerThan: current) else { return }

        latestGitHubVersion = latest
        PermissionsService.shared.scheduleNotification(
            title: "Update available",
            body: "Voqora \(latest) is ready — open the releases page to download it."
        )
    }

    /// Numeric, dot-separated comparison (e.g. "1.0.10" > "1.0.9"). Falls
    /// back to 0 for any missing/non-numeric component.
    static func isVersion(_ a: String, newerThan b: String) -> Bool {
        let partsA = a.split(separator: ".").compactMap { Int($0) }
        let partsB = b.split(separator: ".").compactMap { Int($0) }
        for i in 0 ..< max(partsA.count, partsB.count) {
            let x = i < partsA.count ? partsA[i] : 0
            let y = i < partsB.count ? partsB[i] : 0
            if x != y {
                return x > y
            }
        }
        return false
    }

    override init() {
        super.init()
        controller = nil
        observeUpdaterState()
    }

    deinit {
        observations.forEach { $0.invalidate() }
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
              error.code == noUpdateErrorCode
        else {
            return "Couldn't check for updates. Your current Voqora still works. Try again later."
        }
        return "Voqora is up to date."
    }

    func updater(_: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        isCheckingForUpdates = false
        updateStatusMessage = "Update \(item.displayVersionString) is ready to review."
        PermissionsService.shared.scheduleNotification(
            title: "Update available",
            body: "Voqora \(item.displayVersionString) is ready to review."
        )
    }

    func updaterDidNotFindUpdate(_: SPUUpdater, error: Error) {
        isCheckingForUpdates = false
        updateStatusMessage = Self.statusMessage(forUpdateCheckError: error as NSError)
    }

    func updater(_: SPUUpdater, didAbortWithError error: Error) {
        isCheckingForUpdates = false
        updateStatusMessage = Self.statusMessage(forUpdateCheckError: error as NSError)
    }

    func updater(_: SPUUpdater, didFinishUpdateCycleFor _: SPUUpdateCheck, error: Error?) {
        isCheckingForUpdates = false
        if let error {
            updateStatusMessage = Self.statusMessage(forUpdateCheckError: error as NSError)
        }
    }
}
