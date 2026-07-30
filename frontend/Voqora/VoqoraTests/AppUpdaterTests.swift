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
}
