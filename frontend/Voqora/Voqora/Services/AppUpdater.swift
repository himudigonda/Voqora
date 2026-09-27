import Combine
import Foundation
import Sparkle

@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    private static let noUpdateErrorCode = 1001
    private var controller: SPUStandardUpdaterController?
    private var observations: [NSKeyValueObservation] = []

    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var isCheckingForUpdates = false
    @Published private(set) var updateStatusMessage: String?

    @Published private(set) var latestGitHubVersion: String?
    private static let latestReleaseAPIURL = URL(string: "https://api.github.com/repos/himudigonda/Voqora/releases/latest")!

    private var lastGitHubCheck: Date?

    nonisolated static let gitHubCheckMinimumInterval: TimeInterval = 60 * 60

    nonisolated static func shouldCheckGitHubRelease(
        lastChecked: Date?,
        now: Date = Date(),
        minimumInterval: TimeInterval = gitHubCheckMinimumInterval
    ) -> Bool {
        guard let lastChecked else { return true }
        return now.timeIntervalSince(lastChecked) >= minimumInterval
    }

    func checkGitHubReleaseForUpdateIfStale() async {
        guard Self.shouldCheckGitHubRelease(lastChecked: lastGitHubCheck) else { return }
        await checkGitHubReleaseForUpdate()
    }

    private struct GitHubReleaseTag: Decodable {
        let tagName: String
        enum CodingKeys: String, CodingKey { case tagName = "tag_name" }
    }

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
        lastGitHubCheck = Date()

        let latest = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        guard Self.isVersion(latest, newerThan: current) else { return }

        latestGitHubVersion = latest
        PermissionsService.shared.scheduleNotification(
            title: "Update available",
            body: "Voqora \(latest) is ready — open the releases page to download it."
        )
    }

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
