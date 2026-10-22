@testable import Voqora
import XCTest

@MainActor
final class OnboardingStepTests: XCTestCase {
    func test_everyStepHasUniqueKeyAndGroup() {
        let keys = OnboardingStep.allCases.map(\.key)
        XCTAssertEqual(Set(keys).count, keys.count)
        XCTAssertTrue(keys.allSatisfy { !$0.isEmpty })
        for step in OnboardingStep.allCases {
            XCTAssertTrue(OnboardingStep.groups.contains(step.group), "\(step.key) has unknown group \(step.group)")
            XCTAssertEqual(OnboardingStep(key: step.key), step)
        }
        XCTAssertEqual(Set(OnboardingStep.allCases.map(\.group)), Set(OnboardingStep.groups))
    }

    func test_rawValuesFollowPlannedOrder() {
        XCTAssertEqual(
            OnboardingStep.allCases.map(\.key),
            ["welcome", "privacy", "permissions", "engine", "voice", "shortcuts", "dictation", "audiobooks", "ai", "appearance", "done"]
        )
        XCTAssertEqual(OnboardingStep.allCases.map(\.rawValue), Array(0 ... 10))
    }

    func test_optionalSteps() {
        let optional = OnboardingStep.allCases.filter(\.isOptional)
        XCTAssertEqual(Set(optional), [.privacy, .dictation, .audiobooks, .ai])
    }

    func test_version6Keys_areAllRealStepKeys() {
        for key in OnboardingCoordinator.keysSeenInVersion6 {
            XCTAssertNotNil(OnboardingStep(key: key), "\(key) is not a step")
        }
        XCTAssertFalse(OnboardingCoordinator.keysSeenInVersion6.contains(OnboardingStep.privacy.key))
        XCTAssertFalse(OnboardingCoordinator.keysSeenInVersion6.contains(OnboardingStep.dictation.key))
    }

    func test_nextUnseenSkipsSeenStepsAndFallsBackToNextStep() {
        let seen: Set = ["permissions", "engine"]
        XCTAssertEqual(OnboardingStep.privacy.nextUnseen(in: seen), .voice)
        XCTAssertEqual(OnboardingStep.welcome.nextUnseen(in: seen), .privacy)
        let allSeen = Set(OnboardingStep.allCases.map(\.key))
        XCTAssertEqual(OnboardingStep.voice.nextUnseen(in: allSeen), .shortcuts)
        XCTAssertEqual(OnboardingStep.done.nextUnseen(in: allSeen), .done)
    }

    func test_identityDraft_blankPairContinuesWithoutCommitting() {
        let blank = IdentityDraft()
        XCTAssertTrue(blank.allowsContinue)
        XCTAssertEqual(blank.validation, .blank)
        XCTAssertFalse(blank.canSave(storedName: nil, storedEmail: nil))
    }

    func test_identityDraft_partialPairBlocksContinue() {
        XCTAssertFalse(IdentityDraft(name: "Ada", email: "").allowsContinue)
        XCTAssertFalse(IdentityDraft(name: "", email: "ada@example.com").allowsContinue)
        XCTAssertFalse(IdentityDraft(name: "Ada", email: "not-an-email").allowsContinue)
        XCTAssertTrue(IdentityDraft(name: "Ada Lovelace", email: "ada@example.com").allowsContinue)
    }
}
