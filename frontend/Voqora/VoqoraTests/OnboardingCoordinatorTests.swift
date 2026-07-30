@testable import Voqora
import XCTest

/// Tests for OnboardingCoordinator (S1-E3 / G6).
@MainActor
final class OnboardingCoordinatorTests: XCTestCase {

    private func makeCoordinator(accessibilityTrusted: @escaping () -> Bool = { true }) -> OnboardingCoordinator {
        OnboardingCoordinator(accessibilityTrusted: accessibilityTrusted)
    }

    override func setUp() async throws {
        // Each test starts with a clean flag + version baseline so the
        // upgrade-reset path doesn't fire spuriously.
        UserDefaults.standard.removeObject(forKey: "hasOnboarded")
        UserDefaults.standard.set(99, forKey: "onboardingVersion")
    }

    func test_freshInstall_needsOnboarding() {
        let coord = makeCoordinator()
        XCTAssertTrue(coord.needsOnboarding)
    }

    func test_afterMarkCompleted_doesNotNeedOnboarding() {
        let coord = makeCoordinator()
        coord.markCompleted()
        XCTAssertFalse(coord.needsOnboarding)
    }

    func test_resetRestoresOnboarding() {
        let coord = makeCoordinator()
        coord.markCompleted()
        XCTAssertFalse(coord.needsOnboarding)
        coord.reset()
        XCTAssertTrue(coord.needsOnboarding)
    }

    func test_versionBumpsOnStateChange() {
        let coord = makeCoordinator()
        let v0 = coord.version
        coord.markCompleted()
        XCTAssertNotEqual(v0, coord.version, "version should bump so SwiftUI can react")
    }

    func test_upgrade_resetsHasOnboardedFromOlderVersion() {
        // Simulate an install that completed the preceding v2 onboarding.
        UserDefaults.standard.set(true, forKey: "hasOnboarded")
        UserDefaults.standard.set(2, forKey: "onboardingVersion")

        let coord = makeCoordinator()
        XCTAssertTrue(coord.needsOnboarding,
                      "users on an older onboarding version must see the wizard again once")
    }

    func test_revokedAccessibility_requiresOnboardingEvenAfterCompletion() {
        UserDefaults.standard.set(true, forKey: "hasOnboarded")
        UserDefaults.standard.set(3, forKey: "onboardingVersion")

        let coord = makeCoordinator(accessibilityTrusted: { false })
        XCTAssertTrue(coord.needsOnboarding,
                      "a revoked Accessibility grant must not leave selected-text speech unusable")
    }
}
