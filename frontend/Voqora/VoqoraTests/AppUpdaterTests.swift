@testable import Voqora
import Sparkle
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

    func test_isVersionNewerThan_comparesNumericComponents() {
        XCTAssertTrue(AppUpdater.isVersion("1.0.1", newerThan: "1.0.0"))
        XCTAssertTrue(AppUpdater.isVersion("1.1.0", newerThan: "1.0.9"))
        XCTAssertTrue(AppUpdater.isVersion("2.0.0", newerThan: "1.9.9"))
        // Numeric comparison, not lexical — "1.0.10" must beat "1.0.9".
        XCTAssertTrue(AppUpdater.isVersion("1.0.10", newerThan: "1.0.9"))
    }

    func test_isVersionNewerThan_falseWhenEqualOrOlder() {
        XCTAssertFalse(AppUpdater.isVersion("1.0.0", newerThan: "1.0.0"))
        XCTAssertFalse(AppUpdater.isVersion("1.0.0", newerThan: "1.0.1"))
        XCTAssertFalse(AppUpdater.isVersion("0.9.9", newerThan: "1.0.0"))
    }

    func test_isVersionNewerThan_handlesMissingComponents() {
        // "1.1" vs "1.0.5" — missing patch component defaults to 0.
        XCTAssertTrue(AppUpdater.isVersion("1.1", newerThan: "1.0.5"))
        XCTAssertFalse(AppUpdater.isVersion("1.0", newerThan: "1.0.0"))
    }

    func test_checkGitHubReleaseForUpdate_isNoOpInTestRunner() async {
        let updater = AppUpdater()
        // Same XCTestCase guard as PermissionsService's network-touching
        // methods — a real GitHub API call during a unit test run would be
        // flaky, slow, and rate-limited.
        await updater.checkGitHubReleaseForUpdate()
        XCTAssertNil(updater.latestGitHubVersion)
    }
}
