@testable import Voqora
import XCTest

@MainActor
final class AppUpdaterTests: XCTestCase {
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
