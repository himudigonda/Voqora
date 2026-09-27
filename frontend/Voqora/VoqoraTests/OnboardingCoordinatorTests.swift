@testable import Voqora
import XCTest

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
        defaults.set(true, forKey: "hasOnboarded")
        defaults.set(2, forKey: "onboardingVersion")

        let coord = makeCoordinator()
        XCTAssertTrue(coord.needsOnboarding,
                      "users on an older onboarding version must see the wizard again once")
    }

    func test_brokenPublicProfile_rerunsRepairedOnboardingEvenWhenAccessibilityIsGranted() {
        defaults.set(true, forKey: "hasOnboarded")
        defaults.set(3, forKey: "onboardingVersion")

        let coord = makeCoordinator()

        XCTAssertTrue(coord.needsOnboarding)
    }

    func test_revokedAccessibility_keepsCompletedOnboardingAndUsesDashboardRecovery() {
        defaults.set(true, forKey: "hasOnboarded")
        defaults.set(5, forKey: "onboardingVersion")

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
