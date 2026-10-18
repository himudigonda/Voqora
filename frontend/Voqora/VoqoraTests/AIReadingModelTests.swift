import Foundation
@testable import Voqora
import XCTest

final class AIReadingErrorMapperTests: XCTestCase {
    private func map(_ status: Int, _ json: String) -> AIReadingError {
        AIReadingErrorMapper.error(statusCode: status, data: Data(json.utf8))
    }

    func test_providerRequiredUsesPreferencesWording() {
        let error = map(400, #"{"detail": "Choose an AI provider in Settings to use AI tools.", "code": "ai_provider_required"}"#)
        XCTAssertEqual(error, .providerRequired)
        XCTAssertTrue(error.message.contains("Preferences > AI"))
    }

    func test_providerProblemKeepsTheBackendReason() {
        let error = map(400, #"{"detail": "Enter a server URL for Ollama.", "code": "ai_provider_required"}"#)
        XCTAssertEqual(error.kind, .providerSettings)
        XCTAssertEqual(error.message, "Enter a server URL for Ollama.")
    }

    func test_settingsWordingPointsToPreferences() {
        let error = map(502, #"{"detail": "OpenAI has no model named x. Choose another model in Settings.", "code": "llm_model_not_found"}"#)
        XCTAssertEqual(error.message, "OpenAI has no model named x. Choose another model in Preferences > AI.")
    }

    func test_sizeAndBudgetLimitsMapToTooLarge() {
        for code in ["book_too_long", "text_too_long", "ai_budget_exceeded"] {
            let error = map(413, #"{"detail": "Too big.", "code": "\#(code)"}"#)
            XCTAssertEqual(error.kind, .tooLarge, code)
            XCTAssertEqual(error.message, "Too big.")
            XCTAssertFalse(error.isRetryable)
        }
    }

    func test_providerFailuresKeepTheProviderMessage() {
        let error = map(502, #"{"detail": "OpenAI rejected the API key.", "code": "llm_auth_failed"}"#)
        XCTAssertEqual(error.kind, .provider)
        XCTAssertEqual(error.message, "OpenAI rejected the API key.")
    }

    func test_busyCodesAreRetryable() {
        for code in ["ai_busy", "ai_rate_limited", "llm_busy"] {
            let error = map(429, #"{"detail": "Busy.", "code": "\#(code)"}"#)
            XCTAssertEqual(error.kind, .busy, code)
            XCTAssertTrue(error.isRetryable)
        }
    }

    func test_validationListDetailGetsAFriendlyMessage() {
        let error = map(422, #"{"detail": [{"loc": ["body", "text"], "msg": "too long"}]}"#)
        XCTAssertEqual(error.kind, .invalidRequest)
        XCTAssertFalse(error.message.isEmpty)
    }

    func test_headerCheckFailureWithoutCodeMapsToProviderSettings() {
        let error = map(400, #"{"detail": "Unknown AI provider."}"#)
        XCTAssertEqual(error.kind, .providerSettings)
        XCTAssertEqual(error.message, "Unknown AI provider.")
    }

    func test_plainTextUnauthorizedMapsToEngineUnavailable() {
        XCTAssertEqual(map(401, "Unauthorized"), .engineUnavailable)
    }

    func test_missingDetailFallsBackToCodeMessage() {
        let error = map(504, #"{"code": "ai_timeout"}"#)
        XCTAssertEqual(error.kind, .timeout)
        XCTAssertEqual(error.message, "The AI request took too long. Try again.")
    }
}

final class AIStudySessionTests: XCTestCase {
    func test_quizScoresOnlyFirstAnswerPerQuestion() {
        var session = QuizSession(questions: [AIReadingFixtures.question("One?", answer: 0), AIReadingFixtures.question("Two?", answer: 3)])
        session.select(0, for: 0)
        session.select(1, for: 0)
        XCTAssertEqual(session.choice(for: 0), 0)
        XCTAssertEqual(session.isCorrect(0), true)
        XCTAssertFalse(session.isComplete)

        session.select(2, for: 1)
        XCTAssertTrue(session.isComplete)
        XCTAssertEqual(session.score, 1)
        XCTAssertEqual(session.isCorrect(1), false)

        session.restart()
        XCTAssertEqual(session.answeredCount, 0)
        XCTAssertEqual(session.score, 0)
    }

    func test_quizIgnoresOutOfRangeSelections() {
        var session = QuizSession(questions: [AIReadingFixtures.question("One?")])
        session.select(7, for: 0)
        session.select(0, for: 4)
        XCTAssertEqual(session.answeredCount, 0)
    }

    func test_flashcardsNavigateFlipAndTrackKnownCards() {
        let cards = (1 ... 3).map { AIFlashcard(front: "F\($0)", back: "B\($0)") }
        var session = FlashcardSession(cards: cards)
        XCTAssertFalse(session.canGoBack)
        session.flip()
        XCTAssertTrue(session.isFlipped)

        session.next()
        XCTAssertEqual(session.current?.front, "F2")
        XCTAssertFalse(session.isFlipped)

        session.toggleKnown()
        XCTAssertEqual(session.knownCount, 1)
        XCTAssertEqual(session.current?.front, "F3")
        XCTAssertFalse(session.canGoForward)

        session.next()
        XCTAssertEqual(session.current?.front, "F3")
        session.previous()
        XCTAssertTrue(session.isCurrentKnown)
        session.toggleKnown()
        XCTAssertEqual(session.knownCount, 0)
    }

    func test_flashcardsCompleteWhenEveryCardIsKnown() {
        var session = FlashcardSession(cards: [AIFlashcard(front: "F", back: "B"), AIFlashcard(front: " ", back: "Empty")])
        XCTAssertEqual(session.cards.count, 1)
        session.toggleKnown()
        XCTAssertTrue(session.isComplete)
        session.restart()
        XCTAssertFalse(session.isComplete)
    }
}

final class AICitationLocatorTests: XCTestCase {
    private func line(_ id: Int, _ text: String, page: Int, start: Double) -> TranscriptLine {
        TranscriptLine(id: id, text: text, start: start, end: start + 2, page: page, block: id, isHeading: false, isNarrated: true, isExactlyTimed: true)
    }

    private var document: TranscriptDocument {
        TranscriptDocument(lines: [
            line(0, "The storm arrived at night.", page: 1, start: 0),
            line(1, "Ana closed the shutters.", page: 2, start: 10),
            line(2, "It rained for three days, and the river rose.", page: 2, start: 12),
            line(3, "Nobody left the village.", page: 2, start: 14),
        ])
    }

    func test_findsTheSentenceThatContainsTheQuote() {
        let citation = AICitation(sectionTitle: nil, page: 2, passageIndex: 0, quote: "It rained for three days")
        XCTAssertEqual(AICitationLocator.line(for: citation, in: document)?.id, 2)
    }

    func test_matchesQuotesThatSpanPunctuationAndCase() {
        let citation = AICitation(sectionTitle: nil, page: 2, passageIndex: 0, quote: "ana CLOSED the shutters!")
        XCTAssertEqual(AICitationLocator.line(for: citation, in: document)?.id, 1)
    }

    func test_fallsBackToBestWordOverlapThenFirstLineOfPage() {
        let overlap = AICitation(sectionTitle: nil, page: 2, passageIndex: 0, quote: "the village waited")
        XCTAssertEqual(AICitationLocator.line(for: overlap, in: document)?.id, 3)
        let unknown = AICitation(sectionTitle: nil, page: 2, passageIndex: 0, quote: "zzz")
        XCTAssertEqual(AICitationLocator.line(for: unknown, in: document)?.id, 1)
    }

    func test_shortLinesOnlyMatchWholeWords() {
        let lines = TranscriptDocument(lines: [
            line(0, "I.", page: 5, start: 0),
            line(1, "It rained all week.", page: 5, start: 2),
        ])
        let citation = AICitation(sectionTitle: nil, page: 5, passageIndex: 0, quote: "it rained")
        XCTAssertEqual(AICitationLocator.line(for: citation, in: lines)?.id, 1)
    }

    func test_returnsNilWhenThePageIsNotInTheTranscript() {
        let citation = AICitation(sectionTitle: nil, page: 9, passageIndex: 0, quote: "storm")
        XCTAssertNil(AICitationLocator.line(for: citation, in: document))
    }
}

final class AIReadingPreferencesTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "AIReadingPreferencesTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func test_defaultTargetIsFirstNonEnglishPreferredLanguage() {
        XCTAssertEqual(AIReadingPreferences.defaultTranslateTarget(preferredLanguages: ["en-US", "fr-CA", "es-ES"]), .french)
        XCTAssertEqual(AIReadingPreferences.defaultTranslateTarget(preferredLanguages: ["en-GB", "zh-Hans-CN"]), .mandarin)
    }

    func test_defaultTargetFallsBackToSpanish() {
        XCTAssertEqual(AIReadingPreferences.defaultTranslateTarget(preferredLanguages: ["en-US", "de-DE", "ja-JP"]), .spanish)
        XCTAssertEqual(AIReadingPreferences.defaultTranslateTarget(preferredLanguages: []), .spanish)
    }

    func test_storedTargetWinsOverDefault() {
        defaults.set("hi", forKey: AIReadingPreferences.translateTargetKey)
        XCTAssertEqual(AIReadingPreferences.translateTarget(defaults: defaults, preferredLanguages: ["fr-FR"]), .hindi)
        defaults.set("klingon", forKey: AIReadingPreferences.translateTargetKey)
        XCTAssertEqual(AIReadingPreferences.translateTarget(defaults: defaults, preferredLanguages: ["fr-FR"]), .french)
    }

    func test_localeIdentifiersMapToAppLanguages() {
        XCTAssertEqual(AILanguage(localeIdentifier: "pt_BR"), .portuguese)
        XCTAssertEqual(AILanguage(localeIdentifier: "en-GB"), .englishUK)
        XCTAssertEqual(AILanguage(localeIdentifier: "en"), .englishUS)
        XCTAssertNil(AILanguage(localeIdentifier: "de-DE"))
    }

    func test_voiceMatcherKeepsCurrentVoiceWhenLanguageMatches() {
        XCTAssertEqual(AIVoiceMatcher.voice(for: .spanish, current: "em_alex"), "em_alex")
        XCTAssertEqual(AIVoiceMatcher.voice(for: .englishUK, current: "af_bella"), "af_bella")
    }

    func test_voiceMatcherPicksAVoiceForTheOutputLanguage() {
        XCTAssertEqual(AIVoiceMatcher.voice(for: .french, current: "af_bella"), "ff_siwis")
        XCTAssertEqual(AIVoiceMatcher.voice(for: .englishUS, current: "ef_dora"), "af_bella")
    }

    func test_usageSummaryNamesProviderTokensAndCost() {
        let usage = AIUsage(tokens: 1500, tokensEstimated: true, costUSD: 0.004, provider: "anthropic", model: "claude-test")
        let summary = AIUsageFormatter.summary(usage)
        XCTAssertTrue(summary.hasPrefix("Anthropic · claude-test"))
        XCTAssertTrue(summary.contains("about"))
        XCTAssertTrue(summary.contains("under $0.01"))
    }
}
