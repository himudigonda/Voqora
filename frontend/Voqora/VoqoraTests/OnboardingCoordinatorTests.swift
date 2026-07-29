@testable import Voqora
import XCTest

/// Tests for OnboardingCoordinator (S1-E3 / G6).
@MainActor
final class OnboardingCoordinatorTests: XCTestCase {
    override func setUp() async throws {
        // Each test starts with a clean flag + version baseline so the
        // upgrade-reset path doesn't fire spuriously.
        UserDefaults.standard.removeObject(forKey: "hasOnboarded")
        UserDefaults.standard.set(99, forKey: "onboardingVersion")
    }

    func test_freshInstall_needsOnboarding() {
        let coord = OnboardingCoordinator()
        XCTAssertTrue(coord.needsOnboarding)
    }

    func test_afterMarkCompleted_doesNotNeedOnboarding() {
        let coord = OnboardingCoordinator()
        coord.markCompleted()
        XCTAssertFalse(coord.needsOnboarding)
    }

    func test_resetRestoresOnboarding() {
        let coord = OnboardingCoordinator()
        coord.markCompleted()
        XCTAssertFalse(coord.needsOnboarding)
        coord.reset()
        XCTAssertTrue(coord.needsOnboarding)
    }

    func test_versionBumpsOnStateChange() {
        let coord = OnboardingCoordinator()
        let v0 = coord.version
        coord.markCompleted()
        XCTAssertNotEqual(v0, coord.version, "version should bump so SwiftUI can react")
    }

    func test_upgrade_resetsHasOnboardedFromOlderVersion() {
        // Simulate an existing install that had completed v1 onboarding.
        UserDefaults.standard.set(true, forKey: "hasOnboarded")
        UserDefaults.standard.set(1, forKey: "onboardingVersion")

        let coord = OnboardingCoordinator()
        XCTAssertTrue(coord.needsOnboarding,
                      "users on an older onboarding version must see the wizard again once")
    }
}
