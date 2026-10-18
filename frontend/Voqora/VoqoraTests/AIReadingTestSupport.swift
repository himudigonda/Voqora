import Foundation
@testable import Voqora
import XCTest

enum AIReadingFixtures {
    static let credential = LLMCredential(provider: .openai, apiKey: "sk-test", model: "gpt-test", serverURL: "")
    static let usage = AIUsage(tokens: 120, tokensEstimated: false, costUSD: 0.002, provider: "openai", model: "gpt-test")
    static let bookID = String(repeating: "a", count: 32)

    static func question(_ text: String, answer: Int = 1) -> AIQuizQuestion {
        AIQuizQuestion(question: text, choices: ["A", "B", "C", "D"], answerIndex: answer, explanation: "Because.")
    }
}

struct AIStubFailure: Error {}

@MainActor
final class AIReadingServiceStub: AIReadingServing {
    enum Call: Equatable {
        case summarize(AISource, AISummaryLength, AILanguage?)
        case translate(String, AILanguage)
        case ask(String, String, [AIChatTurn])
        case quiz(AISource, Int, AIQuizDifficulty)
        case flashcards(AISource, Int)
    }

    private(set) var calls: [Call] = []
    var summaryResult: Result<AISummary, Error> = .success(AISummary(summary: "A short summary.", usage: AIReadingFixtures.usage))
    var translationResult: Result<AITranslation, Error> = .success(
        AITranslation(text: "Hola mundo.", detectedSourceLanguage: "en", usage: AIReadingFixtures.usage)
    )
    var answerResult: Result<AIAnswer, Error> = .success(
        AIAnswer(answer: "The answer.", found: true, citations: [], usage: AIReadingFixtures.usage)
    )
    var quizResult: Result<AIQuiz, Error> = .success(
        AIQuiz(questions: [AIReadingFixtures.question("One?"), AIReadingFixtures.question("Two?")], usage: AIReadingFixtures.usage)
    )
    var deckResult: Result<AIFlashcardDeck, Error> = .success(
        AIFlashcardDeck(cards: [AIFlashcard(front: "Front", back: "Back")], usage: AIReadingFixtures.usage)
    )
    var suspends = false

    func summarize(_ source: AISource, length: AISummaryLength, language: AILanguage?, credential _: LLMCredential) async throws -> AISummary {
        calls.append(.summarize(source, length, language))
        try await suspendIfNeeded()
        return try summaryResult.get()
    }

    func translate(_ text: String, to language: AILanguage, credential _: LLMCredential) async throws -> AITranslation {
        calls.append(.translate(text, language))
        try await suspendIfNeeded()
        return try translationResult.get()
    }

    func ask(bookID: String, question: String, history: [AIChatTurn], credential _: LLMCredential) async throws -> AIAnswer {
        calls.append(.ask(bookID, question, history))
        try await suspendIfNeeded()
        return try answerResult.get()
    }

    func quiz(_ source: AISource, count: Int, difficulty: AIQuizDifficulty, credential _: LLMCredential) async throws -> AIQuiz {
        calls.append(.quiz(source, count, difficulty))
        try await suspendIfNeeded()
        return try quizResult.get()
    }

    func flashcards(_ source: AISource, count: Int, credential _: LLMCredential) async throws -> AIFlashcardDeck {
        calls.append(.flashcards(source, count))
        try await suspendIfNeeded()
        return try deckResult.get()
    }

    private func suspendIfNeeded() async throws {
        if suspends {
            try await Task.sleep(nanoseconds: 30_000_000_000)
        }
    }
}

@MainActor
func aiWaitUntil(timeout: TimeInterval = 2, _ condition: @MainActor () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
}
