@testable import Voqora
import AppKit
import XCTest

@MainActor
final class AppDelegateTests: XCTestCase {
    func test_terminationStopsOnlyTheOwnedBackendCallback() {
        let delegate = AppDelegate()
        var stopped = 0
        delegate.stopOwnedBackend = { stopped += 1 }

        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))

        XCTAssertEqual(stopped, 1)
    }

    func test_terminationWithoutAnOwnedBackendIsSafe() {
        let delegate = AppDelegate()
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
    }
}
