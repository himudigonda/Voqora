import Sparkle
@testable import Voqora
import XCTest

@MainActor
final class AppUpdaterTests: XCTestCase {
    func test_updateStatusDoesNotCallAnInvalidFeedUpToDate() {
        let noUpdate = NSError(domain: SUSparkleErrorDomain, code: 1001)
        let invalidFeed = NSError(domain: SUSparkleErrorDomain, code: 4)
        let networkFailure = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)

        XCTAssertEqual(AppUpdater.statusMessage(forUpdateCheckError: noUpdate), "Voqora is up to date.")
        XCTAssertEqual(
            AppUpdater.statusMessage(forUpdateCheckError: invalidFeed),
            "Couldn't check for updates. Your current Voqora still works. Try again later."
        )
        XCTAssertEqual(
            AppUpdater.statusMessage(forUpdateCheckError: networkFailure),
            "Couldn't check for updates. Your current Voqora still works. Try again later."
        )
    }

    func test_testRuntimeDoesNotStartAnUpdateController() {
        let updater = AppUpdater()

        XCTAssertFalse(updater.canCheckForUpdates)
        XCTAssertFalse(updater.automaticallyChecksForUpdates)
        XCTAssertFalse(updater.isCheckingForUpdates)

        updater.checkForUpdates()
        updater.setAutomaticallyChecksForUpdates(true)

        XCTAssertFalse(updater.isCheckingForUpdates)
        XCTAssertFalse(updater.automaticallyChecksForUpdates)
        XCTAssertNil(updater.updateStatusMessage)
    }

    func test_gitHubCheckThrottleAllowsFirstCheckThenSuppressesRepeats() {
        let now = Date()

        XCTAssertTrue(
            AppUpdater.shouldCheckGitHubRelease(lastChecked: nil, now: now),
            "A session that has never checked must always be allowed to"
        )
        XCTAssertFalse(
            AppUpdater.shouldCheckGitHubRelease(lastChecked: now, now: now),
            "Re-opening the tab immediately must not re-issue the request"
        )
        XCTAssertFalse(
            AppUpdater.shouldCheckGitHubRelease(
                lastChecked: now.addingTimeInterval(-60),
                now: now
            ),
            "A check from a minute ago is still current"
        )
    }

    func test_gitHubCheckThrottleExpiresExactlyAtTheInterval() {
        let now = Date()
        let interval = AppUpdater.gitHubCheckMinimumInterval

        XCTAssertFalse(
            AppUpdater.shouldCheckGitHubRelease(
                lastChecked: now.addingTimeInterval(-interval + 1),
                now: now
            ),
            "One second short of the interval must still be suppressed"
        )
        XCTAssertTrue(
            AppUpdater.shouldCheckGitHubRelease(
                lastChecked: now.addingTimeInterval(-interval),
                now: now
            ),
            "`>= minimumInterval` must include the boundary itself"
        )
        XCTAssertTrue(
            AppUpdater.shouldCheckGitHubRelease(
                lastChecked: now.addingTimeInterval(-interval * 2),
                now: now
            )
        )
    }

    func test_aCheckThatNeverReachedGitHubLeavesTheThrottleOpen() async {
        let updater = AppUpdater()
        await updater.checkGitHubReleaseForUpdateIfStale()
        await updater.checkGitHubReleaseForUpdateIfStale()

        XCTAssertNil(
            updater.latestGitHubVersion,
            "The test runner short-circuits before any network access"
        )
    }

    func test_isVersionNewerThan_comparesNumericComponents() {
        XCTAssertTrue(AppUpdater.isVersion("1.0.1", newerThan: "1.0.0"))
        XCTAssertTrue(AppUpdater.isVersion("1.1.0", newerThan: "1.0.9"))
        XCTAssertTrue(AppUpdater.isVersion("2.0.0", newerThan: "1.9.9"))
        XCTAssertTrue(AppUpdater.isVersion("1.0.10", newerThan: "1.0.9"))
    }

    func test_isVersionNewerThan_falseWhenEqualOrOlder() {
        XCTAssertFalse(AppUpdater.isVersion("1.0.0", newerThan: "1.0.0"))
        XCTAssertFalse(AppUpdater.isVersion("1.0.0", newerThan: "1.0.1"))
        XCTAssertFalse(AppUpdater.isVersion("0.9.9", newerThan: "1.0.0"))
    }

    func test_isVersionNewerThan_handlesMissingComponents() {
        XCTAssertTrue(AppUpdater.isVersion("1.1", newerThan: "1.0.5"))
        XCTAssertFalse(AppUpdater.isVersion("1.0", newerThan: "1.0.0"))
    }

    func test_checkGitHubReleaseForUpdate_isNoOpInTestRunner() async {
        let updater = AppUpdater()
        await updater.checkGitHubReleaseForUpdate()
        XCTAssertNil(updater.latestGitHubVersion)
    }
}
