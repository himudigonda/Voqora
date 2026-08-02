@testable import Voqora
import XCTest

/// Tests for OnboardingCoordinator (S1-E3 / G6).
@MainActor
final class OnboardingCoordinatorTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName = ""

    private func makeCoordinator() -> OnboardingCoordinator {
        OnboardingCoordinator(defaults: defaults)
    }

    override func setUp() async throws {
        suiteName = "OnboardingCoordinatorTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        // Each test starts with a clean flag + version baseline so the
        // upgrade-reset path doesn't fire spuriously.
        defaults.removeObject(forKey: "hasOnboarded")
        defaults.set(99, forKey: "onboardingVersion")
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
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
        defaults.set(true, forKey: "hasOnboarded")
        defaults.set(2, forKey: "onboardingVersion")

        let coord = makeCoordinator()
        XCTAssertTrue(coord.needsOnboarding,
                      "users on an older onboarding version must see the wizard again once")
    }

    func test_brokenPublicProfile_rerunsRepairedOnboardingEvenWhenAccessibilityIsGranted() {
        // This matches an early public profile that claimed setup was complete
        // but opened into an unusable player instead of showing the guide.
        defaults.set(true, forKey: "hasOnboarded")
        defaults.set(3, forKey: "onboardingVersion")

        let coord = makeCoordinator()

        XCTAssertTrue(coord.needsOnboarding)
    }

    func test_revokedAccessibility_keepsCompletedOnboardingAndUsesDashboardRecovery() {
        defaults.set(true, forKey: "hasOnboarded")
        // This represents a person who already completed the repaired v4
        // onboarding and later revokes Accessibility in System Settings.
        defaults.set(4, forKey: "onboardingVersion")

        let coord = makeCoordinator()
        XCTAssertFalse(coord.needsOnboarding,
                       "a completed setup must not trap someone in onboarding when Accessibility is revoked")
    }

    func test_resumeStep_defaultsToZero() {
        let coord = makeCoordinator()
        XCTAssertEqual(coord.resumeStep, 0)
    }

    func test_recordStep_persistsForResume() {
        let coord = makeCoordinator()
        coord.recordStep(3)
        XCTAssertEqual(coord.resumeStep, 3, "quitting mid-wizard must resume, not restart from step 0")
    }

    func test_markCompleted_clearsResumeStep() {
        let coord = makeCoordinator()
        coord.recordStep(3)
        coord.markCompleted()
        XCTAssertEqual(coord.resumeStep, 0, "a finished wizard must not carry stale progress into a future forced re-run")
    }

    func test_reset_clearsResumeStep() {
        let coord = makeCoordinator()
        coord.recordStep(3)
        coord.reset()
        XCTAssertEqual(coord.resumeStep, 0, "'Run onboarding again' is a deliberate full replay, not a resume")
    }
}
