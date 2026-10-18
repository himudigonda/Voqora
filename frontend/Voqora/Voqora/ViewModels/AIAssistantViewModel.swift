import Combine
import Foundation

typealias AICredentialSource = @MainActor () -> LLMCredential?

@MainActor
final class AIAssistantViewModel: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable {
        case summary = "Summary"
        case ask = "Ask"
        case quiz = "Quiz"
        case flashcards = "Flashcards"

        var id: String {
            rawValue
        }
    }

    @Published var tab: Tab = .summary
    let bookID: String
    let summary: AISummaryModel
    let ask: AIAskModel
    let quiz: AIQuizModel
    let flashcards: AIFlashcardsModel
    private let credentials: AICredentialBox

    init(bookID: String, client: (any AIReadingServing)? = nil, credential: AICredentialSource? = nil) {
        let resolved = client ?? AIReadingClient()
        let box = AICredentialBox(fixedSource: credential)
        let source: AICredentialSource = { [box] in box.resolve() }
        self.bookID = bookID
        credentials = box
        summary = AISummaryModel(bookID: bookID, client: resolved, credential: source)
        ask = AIAskModel(bookID: bookID, client: resolved, credential: source)
        quiz = AIQuizModel(bookID: bookID, client: resolved, credential: source)
        flashcards = AIFlashcardsModel(bookID: bookID, client: resolved, credential: source)
    }

    func connect(_ providers: LLMProviderStore) {
        credentials.providers = providers
    }

    func cancelAll() {
        summary.cancel()
        ask.cancel()
        quiz.cancel()
        flashcards.cancel()
    }
}

@MainActor
final class AICredentialBox {
    weak var providers: LLMProviderStore?
    private let fixedSource: AICredentialSource?

    init(fixedSource: AICredentialSource? = nil) {
        self.fixedSource = fixedSource
    }

    func resolve() -> LLMCredential? {
        if let fixedSource {
            return fixedSource()
        }
        return providers?.activeCredential
    }
}

@MainActor
final class AISummaryModel: ObservableObject {
    @Published var length: AISummaryLength = .medium
    @Published var language: AILanguage?
    @Published private(set) var state: AIRequestState<AISummary> = .idle
    @Published private(set) var resultLanguage: AILanguage?

    private let bookID: String
    private let client: any AIReadingServing
    private let credentialSource: AICredentialSource
    private let runner = AIRequestRunner()

    init(bookID: String, client: any AIReadingServing, credential: @escaping AICredentialSource) {
        self.bookID = bookID
        self.client = client
        credentialSource = credential
    }

    func generate() {
        guard let credential = credentialSource() else {
            state = .failed(.providerRequired)
            return
        }
        let request = (bookID: bookID, length: length, language: language)
        state = .loading
        runner.run { [client] in
            try await client.summarize(.book(request.bookID), length: request.length, language: request.language, credential: credential)
        } completion: { [weak self] result in
            guard let self else { return }
            if case .success = result {
                resultLanguage = request.language
            }
            state = result.aiState
        }
    }

    func cancel() {
        guard state.isLoading else { return }
        runner.cancel()
        state = .idle
    }
}

@MainActor
final class AIAskModel: ObservableObject {
    struct Message: Identifiable, Equatable {
        let id = UUID()
        let role: AIChatRole
        let text: String
        var citations: [AICitation] = []
    }

    @Published var draft = ""
    @Published private(set) var messages: [Message] = []
    @Published private(set) var isSending = false
    @Published private(set) var error: AIReadingError?

    private let bookID: String
    private let client: any AIReadingServing
    private let credentialSource: AICredentialSource
    private let runner = AIRequestRunner()

    init(bookID: String, client: any AIReadingServing, credential: @escaping AICredentialSource) {
        self.bookID = bookID
        self.client = client
        credentialSource = credential
    }

    var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var canSend: Bool {
        !isSending && !trimmedDraft.isEmpty && trimmedDraft.count <= AIReadingLimits.questionCharacters
    }

    func send() {
        let question = trimmedDraft
        guard !isSending, !question.isEmpty else { return }
        guard question.count <= AIReadingLimits.questionCharacters else {
            error = .tooLong("Questions can be up to \(AIReadingLimits.questionCharacters) characters.")
            return
        }
        guard let credential = credentialSource() else {
            error = .providerRequired
            return
        }
        let history = Self.history(from: messages)
        let bookID = bookID
        error = nil
        draft = ""
        messages.append(Message(role: .user, text: question))
        isSending = true
        runner.run { [client] in
            try await client.ask(bookID: bookID, question: question, history: history, credential: credential)
        } completion: { [weak self] result in
            guard let self else { return }
            isSending = false
            switch result {
            case let .success(answer):
                messages.append(Message(role: .assistant, text: answer.answer, citations: answer.citations))
            case let .failure(failure):
                restoreDraft(question)
                error = failure
            }
        }
    }

    func cancel() {
        guard isSending else { return }
        runner.cancel()
        isSending = false
        if let last = messages.last, last.role == .user {
            restoreDraft(last.text)
        }
    }

    func clear() {
        runner.cancel()
        isSending = false
        messages = []
        error = nil
    }

    private func restoreDraft(_ question: String) {
        if let last = messages.last, last.role == .user, last.text == question {
            messages.removeLast()
        }
        if draft.isEmpty {
            draft = question
        }
    }

    static func history(from messages: [Message]) -> [AIChatTurn] {
        messages
            .suffix(AIReadingLimits.historyTurns)
            .map { AIChatTurn(role: $0.role, content: String($0.text.prefix(AIReadingLimits.historyTurnCharacters))) }
            .filter { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

@MainActor
final class AIQuizModel: ObservableObject {
    @Published var count = 5
    @Published var difficulty: AIQuizDifficulty = .medium
    @Published private(set) var state: AIRequestState<AIQuiz> = .idle
    @Published private(set) var session = QuizSession(questions: [])

    private let bookID: String
    private let client: any AIReadingServing
    private let credentialSource: AICredentialSource
    private let runner = AIRequestRunner()

    init(bookID: String, client: any AIReadingServing, credential: @escaping AICredentialSource) {
        self.bookID = bookID
        self.client = client
        credentialSource = credential
    }

    func generate() {
        guard let credential = credentialSource() else {
            state = .failed(.providerRequired)
            return
        }
        let request = (bookID: bookID, count: AIReadingLimits.quizCounts.clamped(count), difficulty: difficulty)
        state = .loading
        runner.run { [client] in
            try await client.quiz(.book(request.bookID), count: request.count, difficulty: request.difficulty, credential: credential)
        } completion: { [weak self] result in
            guard let self else { return }
            if case let .success(quiz) = result {
                session = QuizSession(questions: quiz.questions)
            }
            state = result.aiState
        }
    }

    func select(_ choice: Int, for index: Int) {
        session.select(choice, for: index)
    }

    func restart() {
        session.restart()
    }

    func cancel() {
        guard state.isLoading else { return }
        runner.cancel()
        state = .idle
    }
}

@MainActor
final class AIFlashcardsModel: ObservableObject {
    @Published var count = 10
    @Published private(set) var state: AIRequestState<AIFlashcardDeck> = .idle
    @Published private(set) var session = FlashcardSession(cards: [])

    private let bookID: String
    private let client: any AIReadingServing
    private let credentialSource: AICredentialSource
    private let runner = AIRequestRunner()

    init(bookID: String, client: any AIReadingServing, credential: @escaping AICredentialSource) {
        self.bookID = bookID
        self.client = client
        credentialSource = credential
    }

    func generate() {
        guard let credential = credentialSource() else {
            state = .failed(.providerRequired)
            return
        }
        let request = (bookID: bookID, count: AIReadingLimits.flashcardCounts.clamped(count))
        state = .loading
        runner.run { [client] in
            try await client.flashcards(.book(request.bookID), count: request.count, credential: credential)
        } completion: { [weak self] result in
            guard let self else { return }
            if case let .success(deck) = result {
                session = FlashcardSession(cards: deck.cards)
            }
            state = result.aiState
        }
    }

    func flip() {
        session.flip()
    }

    func next() {
        session.next()
    }

    func previous() {
        session.previous()
    }

    func toggleKnown() {
        session.toggleKnown()
    }

    func restart() {
        session.restart()
    }

    func cancel() {
        guard state.isLoading else { return }
        runner.cancel()
        state = .idle
    }
}

private extension Result where Failure == AIReadingError, Success: Equatable & Sendable {
    var aiState: AIRequestState<Success> {
        switch self {
        case let .success(value): .loaded(value)
        case let .failure(error): .failed(error)
        }
    }
}

extension ClosedRange<Int> {
    func clamped(_ value: Int) -> Int {
        Swift.min(upperBound, Swift.max(lowerBound, value))
    }
}
