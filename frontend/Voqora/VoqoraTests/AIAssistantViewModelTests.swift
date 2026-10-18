import Foundation
@testable import Voqora
import XCTest

@MainActor
final class AIAssistantViewModelTests: XCTestCase {
    private var service: AIReadingServiceStub!
    private var credential: LLMCredential?

    override func setUp() {
        super.setUp()
        service = AIReadingServiceStub()
        credential = AIReadingFixtures.credential
    }

    private func makeModel() -> AIAssistantViewModel {
        AIAssistantViewModel(bookID: AIReadingFixtures.bookID, client: service) { [unowned self] in credential }
    }

    func test_summaryUsesBookSourceAndChosenOptions() async {
        let model = makeModel()
        model.summary.length = .short
        model.summary.language = .hindi
        model.summary.generate()
        XCTAssertTrue(model.summary.state.isLoading)

        await aiWaitUntil { !model.summary.state.isLoading }

        XCTAssertEqual(model.summary.state.value?.summary, "A short summary.")
        XCTAssertEqual(model.summary.resultLanguage, .hindi)
        XCTAssertEqual(service.calls, [.summarize(.book(AIReadingFixtures.bookID), .short, .hindi)])
    }

    func test_missingProviderShowsProviderRequiredWithoutCallingBackend() {
        credential = nil
        let model = makeModel()
        model.summary.generate()
        model.quiz.generate()
        model.flashcards.generate()
        model.ask.draft = "Who is Ana?"
        model.ask.send()

        XCTAssertEqual(model.summary.state.error, .providerRequired)
        XCTAssertEqual(model.quiz.state.error, .providerRequired)
        XCTAssertEqual(model.flashcards.state.error, .providerRequired)
        XCTAssertEqual(model.ask.error, .providerRequired)
        XCTAssertTrue(service.calls.isEmpty)
    }

    func test_summaryFailureSurfacesMappedError() async {
        let busy = AIReadingError(kind: .busy, message: "Busy.", code: "ai_busy")
        service.summaryResult = .failure(busy)
        let model = makeModel()
        model.summary.generate()

        await aiWaitUntil { !model.summary.state.isLoading }

        XCTAssertEqual(model.summary.state.error, busy)
    }

    func test_unexpectedErrorsAreWrapped() async {
        service.summaryResult = .failure(AIStubFailure())
        let model = makeModel()
        model.summary.generate()

        await aiWaitUntil { !model.summary.state.isLoading }

        XCTAssertEqual(model.summary.state.error?.kind, .failed)
    }

    func test_cancellationNotRequestedByTheUserShowsAnError() async {
        service.summaryResult = .failure(CancellationError())
        let model = makeModel()
        model.summary.generate()

        await aiWaitUntil { !model.summary.state.isLoading }

        XCTAssertEqual(model.summary.state.error?.kind, .failed)
    }

    func test_restoringKeepsResultsForTheSameBook() {
        let first = AIAssistantViewModel.restoring(bookID: AIReadingFixtures.bookID)
        XCTAssertTrue(AIAssistantViewModel.restoring(bookID: AIReadingFixtures.bookID) === first)
        XCTAssertFalse(AIAssistantViewModel.restoring(bookID: String(repeating: "b", count: 32)) === first)
    }

    func test_questionLimitCountsUnicodeScalarsLikeTheBackend() {
        let syllable = "\u{0928}\u{094D}"
        let model = makeModel()
        model.ask.draft = String(repeating: syllable, count: AIReadingLimits.questionCharacters / 2 + 1)
        XCTAssertFalse(model.ask.canSend)
        let long = AIAskModel.Message(role: .assistant, text: String(repeating: syllable, count: AIReadingLimits.historyTurnCharacters))
        let history = AIAskModel.history(from: [long])
        XCTAssertEqual(history.first.map { AIReadingLimits.length(of: $0.content) }, AIReadingLimits.historyTurnCharacters)
    }

    func test_cancelAllStopsInFlightWorkAndReturnsToIdle() async {
        service.suspends = true
        let model = makeModel()
        model.summary.generate()
        model.quiz.generate()
        model.ask.draft = "Where?"
        model.ask.send()

        model.cancelAll()

        XCTAssertEqual(model.summary.state, .idle)
        XCTAssertEqual(model.quiz.state, .idle)
        XCTAssertFalse(model.ask.isSending)
        XCTAssertTrue(model.ask.messages.isEmpty)
        XCTAssertEqual(model.ask.draft, "Where?")
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(model.summary.state, .idle)
    }

    func test_askAppendsAnswerAndSendsPriorTurnsAsHistory() async {
        let citation = AICitation(sectionTitle: "One", page: 3, passageIndex: 1, quote: "Quote")
        service.answerResult = .success(AIAnswer(answer: "First answer.", found: true, citations: [citation], usage: AIReadingFixtures.usage))
        let model = makeModel()
        model.ask.draft = "  First question?  "
        model.ask.send()
        XCTAssertEqual(model.ask.draft, "")
        await aiWaitUntil { !model.ask.isSending }

        XCTAssertEqual(model.ask.messages.map(\.text), ["First question?", "First answer."])
        XCTAssertEqual(model.ask.messages.last?.citations, [citation])

        model.ask.draft = "Second?"
        model.ask.send()
        await aiWaitUntil { !model.ask.isSending }

        XCTAssertEqual(service.calls.last, .ask(
            AIReadingFixtures.bookID,
            "Second?",
            [AIChatTurn(role: .user, content: "First question?"), AIChatTurn(role: .assistant, content: "First answer.")]
        ))
    }

    func test_askFailureRestoresTheQuestion() async {
        service.answerResult = .failure(AIReadingError(kind: .timeout, message: "Slow.", code: "ai_timeout"))
        let model = makeModel()
        model.ask.draft = "Why?"
        model.ask.send()
        await aiWaitUntil { !model.ask.isSending }

        XCTAssertTrue(model.ask.messages.isEmpty)
        XCTAssertEqual(model.ask.draft, "Why?")
        XCTAssertEqual(model.ask.error?.kind, .timeout)
    }

    func test_askRejectsBlankAndOverlongQuestions() {
        let model = makeModel()
        model.ask.draft = "   "
        XCTAssertFalse(model.ask.canSend)
        model.ask.send()
        model.ask.draft = String(repeating: "a", count: AIReadingLimits.questionCharacters + 1)
        XCTAssertFalse(model.ask.canSend)
        model.ask.send()

        XCTAssertEqual(model.ask.error?.kind, .tooLarge)
        XCTAssertTrue(service.calls.isEmpty)
    }

    func test_historyKeepsTheLastTenTurns() {
        let messages = (0 ..< 14).map { AIAskModel.Message(role: $0.isMultiple(of: 2) ? .user : .assistant, text: "Turn \($0)") }
        let history = AIAskModel.history(from: messages)
        XCTAssertEqual(history.count, AIReadingLimits.historyTurns)
        XCTAssertEqual(history.first?.content, "Turn 4")
    }

    func test_quizClampsCountAndStartsAFreshSession() async {
        let model = makeModel()
        model.quiz.count = 99
        model.quiz.difficulty = .easy
        model.quiz.generate()
        await aiWaitUntil { !model.quiz.state.isLoading }

        XCTAssertEqual(service.calls, [.quiz(.book(AIReadingFixtures.bookID), 20, .easy)])
        XCTAssertEqual(model.quiz.session.questions.count, 2)
        model.quiz.select(1, for: 0)
        XCTAssertEqual(model.quiz.session.score, 1)
        model.quiz.restart()
        XCTAssertEqual(model.quiz.session.answeredCount, 0)
    }

    func test_flashcardsClampCountAndLoadDeck() async {
        let model = makeModel()
        model.flashcards.count = 1
        model.flashcards.generate()
        await aiWaitUntil { !model.flashcards.state.isLoading }

        XCTAssertEqual(service.calls, [.flashcards(.book(AIReadingFixtures.bookID), 5)])
        XCTAssertEqual(model.flashcards.session.current?.front, "Front")
        model.flashcards.flip()
        XCTAssertTrue(model.flashcards.session.isFlipped)
    }
}
