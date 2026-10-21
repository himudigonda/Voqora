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

    func test_revokedAccessibility_keepsCompletedOnboarding() {
        defaults.set(true, forKey: OnboardingCoordinator.hasOnboardedKey)
        defaults.set(7, forKey: OnboardingCoordinator.versionKey)

        let coord = makeCoordinator()
        XCTAssertFalse(coord.needsOnboarding,
                       "a completed setup must not trap someone in onboarding when Accessibility is revoked")
    }

    func test_v6Upgrade_showsOnlyNewSteps() {
        defaults.set(true, forKey: OnboardingCoordinator.hasOnboardedKey)
        defaults.set(6, forKey: OnboardingCoordinator.versionKey)
        defaults.set(4, forKey: OnboardingCoordinator.legacyStepKey)

        let coord = makeCoordinator()

        XCTAssertTrue(coord.needsOnboarding)
        XCTAssertEqual(coord.seenStepKeys, OnboardingCoordinator.keysSeenInVersion6)
        XCTAssertNil(defaults.object(forKey: OnboardingCoordinator.legacyStepKey))
        XCTAssertEqual(OnboardingStep.firstUnseen(in: coord.seenStepKeys), .privacy)
        XCTAssertEqual(OnboardingStep.privacy.nextUnseen(in: coord.seenStepKeys), .dictation)
        XCTAssertEqual(OnboardingStep.dictation.nextUnseen(in: coord.seenStepKeys), .done)
        let unseen = OnboardingStep.allCases.filter { !coord.seenStepKeys.contains($0.key) }
        XCTAssertEqual(unseen, [.privacy, .dictation, .done])
    }

    func test_v6UpgradeThatNeverFinished_replaysEverything() {
        defaults.set(false, forKey: OnboardingCoordinator.hasOnboardedKey)
        defaults.set(6, forKey: OnboardingCoordinator.versionKey)

        let coord = makeCoordinator()

        XCTAssertTrue(coord.needsOnboarding)
        XCTAssertTrue(coord.seenStepKeys.isEmpty)
    }

    func test_completedV5Upgrade_showsStepsThatShippedVersionLacked() {
        defaults.set(true, forKey: OnboardingCoordinator.hasOnboardedKey)
        defaults.set(5, forKey: OnboardingCoordinator.versionKey)
        defaults.set(6, forKey: OnboardingCoordinator.legacyStepKey)

        let coord = makeCoordinator()

        XCTAssertTrue(coord.needsOnboarding)
        XCTAssertEqual(coord.seenStepKeys, OnboardingCoordinator.keysSeenInVersion5)
        XCTAssertNil(coord.resumeStepKey)
        XCTAssertNil(defaults.object(forKey: OnboardingCoordinator.legacyStepKey))
        let unseen = OnboardingStep.allCases.filter { !coord.seenStepKeys.contains($0.key) }
        XCTAssertEqual(unseen, [.privacy, .engine, .dictation, .audiobooks, .ai, .done])
    }

    func test_unfinishedV5Upgrade_fullReplay() {
        defaults.set(false, forKey: OnboardingCoordinator.hasOnboardedKey)
        defaults.set(5, forKey: OnboardingCoordinator.versionKey)
        defaults.set(["welcome", "engine"], forKey: OnboardingCoordinator.seenKey)

        let coord = makeCoordinator()

        XCTAssertTrue(coord.needsOnboarding)
        XCTAssertTrue(coord.seenStepKeys.isEmpty)
        XCTAssertEqual(OnboardingStep.firstUnseen(in: coord.seenStepKeys), .welcome)
    }

    func test_upgradeWritesCurrentVersionSoItRunsOnce() {
        defaults.set(true, forKey: OnboardingCoordinator.hasOnboardedKey)
        defaults.set(6, forKey: OnboardingCoordinator.versionKey)

        _ = makeCoordinator()
        let second = makeCoordinator()

        XCTAssertEqual(defaults.integer(forKey: OnboardingCoordinator.versionKey), OnboardingCoordinator.currentVersion)
        XCTAssertEqual(second.seenStepKeys, OnboardingCoordinator.keysSeenInVersion6)
    }

    func test_resumeStepKey_defaultsToNil() {
        XCTAssertNil(makeCoordinator().resumeStepKey)
    }

    func test_recordStep_persistsForResume() {
        let coord = makeCoordinator()
        coord.recordStep(key: "voice")
        XCTAssertEqual(makeCoordinator().resumeStepKey, "voice", "quitting mid-wizard must resume, not restart from the first step")
    }

    func test_resumeByKeySurvivesReorder() {
        let coord = makeCoordinator()
        coord.recordStep(key: OnboardingStep.dictation.key)

        let resumed = makeCoordinator().resumeStepKey.flatMap(OnboardingStep.init(key:))

        XCTAssertEqual(resumed, .dictation)
        XCTAssertNil(OnboardingStep(key: "retired-step"))
    }

    func test_markSeen_persistsAcrossLaunches() {
        let coord = makeCoordinator()
        coord.markSeen(key: "welcome")
        coord.markSeen(key: "welcome")
        XCTAssertEqual(makeCoordinator().seenStepKeys, ["welcome"])
    }

    func test_markCompleted_clearsResumeStep() {
        let coord = makeCoordinator()
        coord.recordStep(key: "voice")
        coord.markCompleted()
        XCTAssertNil(coord.resumeStepKey, "a finished wizard must not carry stale progress into a future forced re-run")
    }

    func test_reset_clearsSeen() {
        let coord = makeCoordinator()
        coord.markSeen(key: "welcome")
        coord.recordStep(key: "voice")
        coord.markCompleted()
        coord.reset()
        XCTAssertTrue(coord.needsOnboarding)
        XCTAssertTrue(coord.seenStepKeys.isEmpty)
        XCTAssertNil(coord.resumeStepKey, "'Run setup again' is a deliberate full replay, not a resume")
        XCTAssertNil(defaults.object(forKey: OnboardingCoordinator.seenKey))
    }
}
