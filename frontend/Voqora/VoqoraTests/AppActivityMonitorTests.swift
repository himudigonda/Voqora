import AppKit
@testable import Voqora
import XCTest

@MainActor
final class AppActivityMonitorTests: XCTestCase {
    func test_isBackgrounded_reflectsAppActivationNotifications() {
        let monitor = AppActivityMonitor()
        XCTAssertFalse(monitor.isBackgrounded)

        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
        XCTAssertTrue(monitor.isBackgrounded)

        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        XCTAssertFalse(monitor.isBackgrounded)
    }
}
