import Foundation

typealias AIReadingTransport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

@MainActor
protocol AIReadingServing: AnyObject {
    func summarize(_ source: AISource, length: AISummaryLength, language: AILanguage?, credential: LLMCredential) async throws -> AISummary
    func translate(_ text: String, to language: AILanguage, credential: LLMCredential) async throws -> AITranslation
    func ask(bookID: String, question: String, history: [AIChatTurn], credential: LLMCredential) async throws -> AIAnswer
    func quiz(_ source: AISource, count: Int, difficulty: AIQuizDifficulty, credential: LLMCredential) async throws -> AIQuiz
    func flashcards(_ source: AISource, count: Int, credential: LLMCredential) async throws -> AIFlashcardDeck
}

nonisolated enum AIReadingLimits {
    static let sourceCharacters = 200_000
    static let translateCharacters = 20000
    static let questionCharacters = 1000
    static let historyTurns = 10
    static let historyTurnCharacters = 4000
    static let quizCounts = 3 ... 20
    static let flashcardCounts = 5 ... 40
    static let summaryTimeout: TimeInterval = 660
    static let toolTimeout: TimeInterval = 330
}

@MainActor
final class AIReadingClient: AIReadingServing {
    private let connection: BackendConnection
    private let transport: AIReadingTransport

    init(connection: BackendConnection? = nil, transport: AIReadingTransport? = nil) {
        self.connection = connection ?? .shared
        self.transport = transport ?? { request in
            try await URLSession.shared.data(for: request)
        }
    }

    func summarize(_ source: AISource, length: AISummaryLength, language: AILanguage?, credential: LLMCredential) async throws -> AISummary {
        try await send(
            "summarize",
            body: SummarizeBody(source: source, length: length.rawValue, language: language?.rawValue),
            credential: credential,
            timeout: AIReadingLimits.summaryTimeout
        )
    }

    func translate(_ text: String, to language: AILanguage, credential: LLMCredential) async throws -> AITranslation {
        try await send(
            "translate",
            body: TranslateBody(text: text, targetLanguage: language.rawValue),
            credential: credential,
            timeout: AIReadingLimits.toolTimeout
        )
    }

    func ask(bookID: String, question: String, history: [AIChatTurn], credential: LLMCredential) async throws -> AIAnswer {
        try await send(
            "ask",
            body: AskBody(bookID: bookID, question: question, history: history),
            credential: credential,
            timeout: AIReadingLimits.toolTimeout
        )
    }

    func quiz(_ source: AISource, count: Int, difficulty: AIQuizDifficulty, credential: LLMCredential) async throws -> AIQuiz {
        let quiz: AIQuiz = try await send(
            "quiz",
            body: StudyBody(source: source, count: count, difficulty: difficulty.rawValue),
            credential: credential,
            timeout: AIReadingLimits.toolTimeout
        )
        guard !quiz.questions.isEmpty else { throw AIReadingError.invalidResponse }
        return quiz
    }

    func flashcards(_ source: AISource, count: Int, credential: LLMCredential) async throws -> AIFlashcardDeck {
        let deck: AIFlashcardDeck = try await send(
            "flashcards",
            body: StudyBody(source: source, count: count, difficulty: nil),
            credential: credential,
            timeout: AIReadingLimits.toolTimeout
        )
        guard !deck.cards.isEmpty else { throw AIReadingError.invalidResponse }
        return deck
    }

    private func send<Response: Decodable>(
        _ tool: String,
        body: some Encodable,
        credential: LLMCredential,
        timeout: TimeInterval
    ) async throws -> Response {
        var request: URLRequest
        do {
            request = try connection.request(path: "ai/\(tool)", method: "POST", timeout: timeout)
        } catch {
            throw AIReadingError.engineUnavailable
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        credential.apply(to: &request)
        request.httpBody = try JSONEncoder().encode(body)

        let exchange: (Data, URLResponse)
        do {
            exchange = try await transport(request)
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled || error is CancellationError {
                throw CancellationError()
            }
            VoqoraLog.warn("AIReadingClient", "AI request did not reach the engine", ["tool": tool, "failureCode": "ai_transport_failed"])
            throw AIReadingError.wrapping(error)
        }
        try Task.checkCancellation()

        let (data, response) = exchange
        guard let http = response as? HTTPURLResponse else { throw AIReadingError.invalidResponse }
        guard (200 ..< 300).contains(http.statusCode) else {
            let failure = AIReadingErrorMapper.error(statusCode: http.statusCode, data: data)
            VoqoraLog.warn(
                "AIReadingClient",
                "AI request failed",
                ["tool": tool, "status": "\(http.statusCode)", "failureCode": failure.code ?? "http_\(http.statusCode)"]
            )
            throw failure
        }
        do {
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            VoqoraLog.info("AIReadingClient", "AI request finished", ["tool": tool, "provider": credential.provider.rawValue])
            return decoded
        } catch {
            VoqoraLog.warn("AIReadingClient", "AI response could not be decoded", ["tool": tool, "failureCode": "ai_decode_failed"])
            throw AIReadingError.invalidResponse
        }
    }
}

private nonisolated struct SummarizeBody: Encodable {
    let source: AISource
    let length: String
    let language: String?

    enum CodingKeys: String, CodingKey {
        case text
        case bookID = "book_id"
        case length
        case language
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try source.encode(into: &container, text: .text, book: .bookID)
        try container.encode(length, forKey: .length)
        try container.encodeIfPresent(language, forKey: .language)
    }
}

private nonisolated struct StudyBody: Encodable {
    let source: AISource
    let count: Int
    let difficulty: String?

    enum CodingKeys: String, CodingKey {
        case text
        case bookID = "book_id"
        case count
        case difficulty
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try source.encode(into: &container, text: .text, book: .bookID)
        try container.encode(count, forKey: .count)
        try container.encodeIfPresent(difficulty, forKey: .difficulty)
    }
}

private nonisolated struct TranslateBody: Encodable {
    let text: String
    let targetLanguage: String

    enum CodingKeys: String, CodingKey {
        case text
        case targetLanguage = "target_language"
    }
}

private nonisolated struct AskBody: Encodable {
    let bookID: String
    let question: String
    let history: [AIChatTurn]

    enum CodingKeys: String, CodingKey {
        case bookID = "book_id"
        case question
        case history
    }
}

private nonisolated extension AISource {
    func encode<Key: CodingKey>(into container: inout KeyedEncodingContainer<Key>, text textKey: Key, book bookKey: Key) throws {
        switch self {
        case let .text(text): try container.encode(text, forKey: textKey)
        case let .book(bookID): try container.encode(bookID, forKey: bookKey)
        }
    }
}
