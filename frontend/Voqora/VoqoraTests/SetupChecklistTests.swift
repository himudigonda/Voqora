@testable import Voqora
import XCTest

@MainActor
final class SetupChecklistTests: XCTestCase {
    private func items(
        accessibility: PermissionState = .granted,
        notifications: PermissionState = .granted,
        microphone: PermissionState = .granted,
        speech: PermissionState = .granted,
        hasAIProvider: Bool = true,
        analyticsDecided: Bool = true,
        engine: DictationEngineChoice = .apple
    ) -> [SetupChecklistItem] {
        SetupChecklist.items(
            permissions: [
                .accessibility: accessibility,
                .notifications: notifications,
                .microphone: microphone,
                .speechRecognition: speech,
            ],
            hasAIProvider: hasAIProvider,
            analyticsDecided: analyticsDecided,
            dictationEngine: engine
        )
    }

    func test_parakeetDictationDoesNotNeedSpeechRecognition() {
        XCTAssertTrue(items(speech: .notDetermined, engine: .parakeet).isEmpty)
        XCTAssertEqual(items(microphone: .denied, engine: .parakeet).map(\.gap), [.dictationAccess])
    }

    func test_checklistListsOnlyLiveGaps() {
        XCTAssertTrue(items().isEmpty)
        XCTAssertEqual(items(accessibility: .denied).map(\.gap), [.accessibility])
        XCTAssertEqual(items(notifications: .notDetermined).map(\.gap), [.notifications])
        XCTAssertEqual(items(microphone: .denied).map(\.gap), [.dictationAccess])
        XCTAssertEqual(items(hasAIProvider: false).map(\.gap), [.aiProvider])
        XCTAssertEqual(
            items(accessibility: .denied, speech: .notDetermined, hasAIProvider: false).map(\.gap),
            [.accessibility, .dictationAccess, .aiProvider]
        )
    }

    func test_decidedOrUnreadablePermissionsAreNotGaps() {
        XCTAssertTrue(items(notifications: .denied).isEmpty)
        XCTAssertTrue(items(accessibility: .unknown, notifications: .unknown, microphone: .unknown, speech: .unknown).isEmpty)
    }

    func test_analyticsUndecidedAppearsOnce() {
        let undecided = items(analyticsDecided: false)
        XCTAssertEqual(undecided.map(\.gap), [.analytics])
        XCTAssertEqual(undecided.filter { $0.gap == .analytics }.count, 1)
        XCTAssertEqual(undecided.first?.target, TabKey.settings(.privacy))
        XCTAssertTrue(items(analyticsDecided: true).isEmpty)
    }

    func test_dictationAccessAppearsOnceWhenBothMissing() {
        XCTAssertEqual(items(microphone: .denied, speech: .denied).map(\.gap), [.dictationAccess])
    }

    func test_analyticsDecidedReadsDefaultsKey() throws {
        let suite = "SetupChecklistTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(SetupChecklist.analyticsDecided(defaults: defaults))
        defaults.set(false, forKey: MetricsService.analyticsEnabledKey)
        XCTAssertTrue(SetupChecklist.analyticsDecided(defaults: defaults))
    }

    func test_itemsCarryUniqueIDsAndTargets() {
        let all = items(
            accessibility: .denied,
            notifications: .notDetermined,
            microphone: .denied,
            hasAIProvider: false,
            analyticsDecided: false
        )
        XCTAssertEqual(Set(all.map(\.id)).count, all.count)
        XCTAssertEqual(all.count, 5)
        XCTAssertTrue(all.allSatisfy { !$0.title.isEmpty && !$0.detail.isEmpty && !$0.target.isEmpty })
    }
}
