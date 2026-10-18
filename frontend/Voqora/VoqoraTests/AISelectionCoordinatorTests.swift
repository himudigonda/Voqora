import Foundation
@testable import Voqora
import XCTest

@MainActor
private final class AISpeakerSpy: SpeechInputSpeaking {
    struct Spoken: Equatable {
        let text: String
        let voice: String?
    }

    var isBackendOnline = true
    var selectedVoice = "af_bella"
    var speechSpeed = 1.0
    private(set) var spoken: [Spoken] = []
    private(set) var errors: [String] = []

    func speak(text: String, voice: String?) async {
        spoken.append(Spoken(text: text, voice: voice))
    }

    func togglePlayback() {}

    func stopPlayback() {}

    func showTransientError(_ message: String) {
        errors.append(message)
    }
}

@MainActor
final class AISelectionCoordinatorTests: XCTestCase {
    private var speaker: AISpeakerSpy!
    private var service: AIReadingServiceStub!
    private var credential: LLMCredential?
    private var selection: String?
    private var trusted = true
    private var target: AILanguage = .french
    private var openedPreferences = 0
    private var openedAccessibility = 0
    private var announcements: [String] = []

    override func setUp() {
        super.setUp()
        speaker = AISpeakerSpy()
        service = AIReadingServiceStub()
        credential = AIReadingFixtures.credential
        selection = "  The selected passage.  "
        trusted = true
        target = .french
        openedPreferences = 0
        openedAccessibility = 0
        announcements = []
    }

    private func makeCoordinator() -> AISelectionCoordinator {
        AISelectionCoordinator(
            speaker: speaker,
            credential: { [unowned self] in credential },
            dependencies: AISelectionCoordinator.Dependencies(
                readSelection: { [unowned self] in selection },
                isAccessibilityTrusted: { [unowned self] in trusted },
                openAccessibilitySettings: { [unowned self] in openedAccessibility += 1 },
                openAIPreferences: { [unowned self] in openedPreferences += 1 },
                announce: { [unowned self] in announcements.append($0) },
                translateTarget: { [unowned self] in target }
            ),
            client: service
        )
    }

    func test_summarizeSendsTrimmedSelectionAndSpeaksTheSummary() async {
        service.summaryResult = .success(AISummary(summary: "A brief overview of the passage.", usage: AIReadingFixtures.usage))
        let coordinator = makeCoordinator()

        await coordinator.summarizeSelection()
        await aiWaitUntil { !self.speaker.spoken.isEmpty && coordinator.activeAction == nil }

        XCTAssertEqual(service.calls, [.summarize(.text("The selected passage."), .short, nil)])
        XCTAssertEqual(speaker.spoken, [.init(text: "A brief overview of the passage.", voice: "af_bella")])
        XCTAssertEqual(announcements.count, 1)
        XCTAssertNil(coordinator.activeAction)
    }

    func test_translateUsesTargetLanguageAndAMatchingVoice() async {
        service.translationResult = .success(AITranslation(text: "Le passage choisi.", detectedSourceLanguage: "en", usage: AIReadingFixtures.usage))
        let coordinator = makeCoordinator()

        await coordinator.translateSelection()
        await aiWaitUntil { !self.speaker.spoken.isEmpty && coordinator.activeAction == nil }

        XCTAssertEqual(service.calls, [.translate("The selected passage.", .french)])
        XCTAssertEqual(speaker.spoken, [.init(text: "Le passage choisi.", voice: "ff_siwis")])
    }

    func test_missingProviderExplainsAndOpensPreferences() async {
        credential = nil
        await makeCoordinator().summarizeSelection()

        XCTAssertEqual(speaker.errors, [AISelectionCoordinator.Message.needsProvider])
        XCTAssertEqual(openedPreferences, 1)
        XCTAssertTrue(service.calls.isEmpty)
    }

    func test_emptySelectionAsksForText() async {
        selection = "   "
        await makeCoordinator().translateSelection()

        XCTAssertEqual(speaker.errors, [AISelectionCoordinator.Message.noSelection])
        XCTAssertTrue(service.calls.isEmpty)
    }

    func test_untrustedAccessibilityOpensSettings() async {
        selection = nil
        trusted = false
        await makeCoordinator().summarizeSelection()

        XCTAssertEqual(speaker.errors, [AISelectionCoordinator.Message.needsAccessibility])
        XCTAssertEqual(openedAccessibility, 1)
    }

    func test_overlongTranslationIsRejectedBeforeCallingTheProvider() async {
        selection = String(repeating: "a", count: AIReadingLimits.translateCharacters + 1)
        await makeCoordinator().translateSelection()

        XCTAssertEqual(speaker.errors, [AISelectionCoordinator.Message.translationTooLong])
        XCTAssertTrue(service.calls.isEmpty)
    }

    func test_offlineEngineIsReported() async {
        speaker.isBackendOnline = false
        await makeCoordinator().summarizeSelection()

        XCTAssertEqual(speaker.errors, [AISelectionCoordinator.Message.engineStarting])
    }

    func test_backendFailureShowsMessageAndDoesNotSpeak() async {
        service.summaryResult = .failure(AIReadingError(kind: .tooLarge, message: "Too big.", code: "ai_budget_exceeded"))
        let coordinator = makeCoordinator()

        await coordinator.summarizeSelection()
        await aiWaitUntil { !self.speaker.errors.isEmpty }

        XCTAssertEqual(speaker.errors, ["Too big."])
        XCTAssertTrue(speaker.spoken.isEmpty)
        XCTAssertEqual(openedPreferences, 0)
    }

    func test_cancelStopsPendingWork() async {
        service.suspends = true
        let coordinator = makeCoordinator()

        await coordinator.summarizeSelection()
        XCTAssertEqual(coordinator.activeAction, .summarize)
        coordinator.cancel()
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertNil(coordinator.activeAction)
        XCTAssertTrue(speaker.spoken.isEmpty)
        XCTAssertTrue(speaker.errors.isEmpty)
    }
}
