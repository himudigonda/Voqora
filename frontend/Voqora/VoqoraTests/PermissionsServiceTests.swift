@testable import Voqora
import XCTest

@MainActor
final class PermissionsServiceTests: XCTestCase {
    func test_init_readsAccessibilityStateImmediately() {
        let svc = PermissionsService()
        XCTAssertEqual(svc.accessibilityGranted, AXIsProcessTrusted())
    }

    func test_init_notificationsStatusIsUnknownInTestRunner() async {
        let svc = PermissionsService()
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

    func test_scheduleNotification_isNoOpInTestRunner() {
        let svc = PermissionsService()
        svc.scheduleNotification(title: "Test", body: "Test body")
        XCTAssertEqual(svc.notificationsStatus, .unknown)
    }
}
