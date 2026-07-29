@testable import Voqora
import XCTest

@MainActor
final class PermissionsServiceTests: XCTestCase {

    func test_init_readsAccessibilityStateImmediately() {
        let svc = PermissionsService()
        // The actual bool depends on the host's AX state — we can't assert
        // grant/deny, only that init populated some value without crashing.
        XCTAssertEqual(svc.accessibilityGranted, AXIsProcessTrusted())
    }

    func test_init_notificationsStatusIsUnknownInTestRunner() async {
        let svc = PermissionsService()
        // Test runner short-circuits the UNUserNotificationCenter calls to
        // avoid the macOS 27 beta crash. Status should remain "unknown".
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(svc.notificationsStatus, .unknown)
    }

    func test_requestNotifications_isNoOpInTestRunner() async {
        let svc = PermissionsService()
        await svc.requestNotifications()
        XCTAssertEqual(svc.notificationsStatus, .unknown)
    }

    func test_startPolling_doesNotCrash() {
        let svc = PermissionsService()
        svc.startPolling()
        svc.stopPolling()
    }
}
