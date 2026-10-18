import Foundation
@testable import Voqora
import XCTest

private final class TransportRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequests: [URLRequest] = []
    private let status: Int
    private let body: Data
    private let failure: Error?

    init(status: Int = 200, json: String = "{}", failure: Error? = nil) {
        self.status = status
        body = Data(json.utf8)
        self.failure = failure
    }

    var requests: [URLRequest] {
        lock.withLock { storedRequests }
    }

    var transport: AIReadingTransport {
        { [self] request in
            lock.withLock { storedRequests.append(request) }
            if let failure {
                throw failure
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (body, response)
        }
    }
}

@MainActor
final class AIReadingClientTests: XCTestCase {
    private let usageJSON = #""tokens": 42, "tokens_estimated": true, "cost_usd": null, "provider": "openai", "model": "gpt-test""#

    private func makeClient(_ recorder: TransportRecorder) -> AIReadingClient {
        let connection = BackendConnection(baseURL: URL(string: "http://127.0.0.1:9000")!, token: "ipc-secret")
        return AIReadingClient(connection: connection, transport: recorder.transport)
    }

    private func jsonBody(_ request: URLRequest?) throws -> [String: Any] {
        let data = try XCTUnwrap(request?.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func test_summarizeBookSendsCredentialHeadersAndDecodesSummary() async throws {
        let recorder = TransportRecorder(json: #"{"summary": "Short.", "chunks": 2, \#(usageJSON)}"#)
        let summary = try await makeClient(recorder).summarize(
            .book(AIReadingFixtures.bookID),
            length: .detailed,
            language: .french,
            credential: AIReadingFixtures.credential
        )

        XCTAssertEqual(summary.summary, "Short.")
        XCTAssertEqual(summary.usage.tokens, 42)
        XCTAssertTrue(summary.usage.tokensEstimated)
        XCTAssertNil(summary.usage.costUSD)
        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/ai/summarize")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Voqora-IPC-Token"), "ipc-secret")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Voqora-LLM-Provider"), "openai")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Voqora-LLM-Key"), "sk-test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Voqora-LLM-Model"), "gpt-test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertGreaterThan(request.timeoutInterval, 600)
        let body = try jsonBody(request)
        XCTAssertEqual(body["book_id"] as? String, AIReadingFixtures.bookID)
        XCTAssertEqual(body["length"] as? String, "detailed")
        XCTAssertEqual(body["language"] as? String, "fr-fr")
        XCTAssertNil(body["text"])
    }

    func test_summarizeTextOmitsBookAndLanguage() async throws {
        let recorder = TransportRecorder(json: #"{"summary": "Short.", \#(usageJSON)}"#)
        _ = try await makeClient(recorder).summarize(.text("Some text"), length: .short, language: nil, credential: AIReadingFixtures.credential)

        let body = try jsonBody(recorder.requests.first)
        XCTAssertEqual(body["text"] as? String, "Some text")
        XCTAssertEqual(body["length"] as? String, "short")
        XCTAssertNil(body["book_id"])
        XCTAssertNil(body["language"])
    }

    func test_translateSendsTargetLanguageAndDecodesText() async throws {
        let recorder = TransportRecorder(json: #"{"text": "Hola.\n\nAdiós.", "detected_source_language": "en", \#(usageJSON)}"#)
        let translation = try await makeClient(recorder).translate("Hello.", to: .spanish, credential: AIReadingFixtures.credential)

        XCTAssertEqual(translation.text, "Hola.\n\nAdiós.")
        XCTAssertEqual(translation.detectedSourceLanguage, "en")
        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.url?.path, "/ai/translate")
        let body = try jsonBody(request)
        XCTAssertEqual(body["target_language"] as? String, "es")
        XCTAssertEqual(body["text"] as? String, "Hello.")
    }

    func test_askSendsHistoryAndDecodesCitations() async throws {
        let json = #"""
        {"answer": "Because.", "found": true, "citations": [{"section_title": "Chapter 2", "page": 4, "passage_index": 7, "quote": "It rained."}], \#(usageJSON)}
        """#
        let recorder = TransportRecorder(json: json)
        let answer = try await makeClient(recorder).ask(
            bookID: AIReadingFixtures.bookID,
            question: "Why?",
            history: [AIChatTurn(role: .user, content: "Who?"), AIChatTurn(role: .assistant, content: "Ana.")],
            credential: AIReadingFixtures.credential
        )

        XCTAssertTrue(answer.found)
        XCTAssertEqual(answer.citations, [AICitation(sectionTitle: "Chapter 2", page: 4, passageIndex: 7, quote: "It rained.")])
        let body = try jsonBody(recorder.requests.first)
        XCTAssertEqual(body["question"] as? String, "Why?")
        let history = try XCTUnwrap(body["history"] as? [[String: String]])
        XCTAssertEqual(history, [["role": "user", "content": "Who?"], ["role": "assistant", "content": "Ana."]])
    }

    func test_quizDropsMalformedQuestionsAndSendsOptions() async throws {
        let json = #"""
        {"questions": [
            {"question": "Good?", "choices": ["a", "b", "c", "d"], "answer_index": 2, "explanation": "c"},
            {"question": "Bad?", "choices": ["a", "b", "c", "d"], "answer_index": 9, "explanation": ""}
        ], \#(usageJSON)}
        """#
        let recorder = TransportRecorder(json: json)
        let quiz = try await makeClient(recorder).quiz(.book(AIReadingFixtures.bookID), count: 5, difficulty: .hard, credential: AIReadingFixtures.credential)

        XCTAssertEqual(quiz.questions.map(\.question), ["Good?"])
        let body = try jsonBody(recorder.requests.first)
        XCTAssertEqual(body["count"] as? Int, 5)
        XCTAssertEqual(body["difficulty"] as? String, "hard")
    }

    func test_emptyQuizIsAnInvalidResponse() async {
        let recorder = TransportRecorder(json: #"{"questions": [], \#(usageJSON)}"#)
        do {
            _ = try await makeClient(recorder).quiz(.book(AIReadingFixtures.bookID), count: 5, difficulty: .easy, credential: AIReadingFixtures.credential)
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error as? AIReadingError, .invalidResponse)
        }
    }

    func test_flashcardsOmitDifficulty() async throws {
        let recorder = TransportRecorder(json: #"{"cards": [{"front": "F", "back": "B"}], \#(usageJSON)}"#)
        let deck = try await makeClient(recorder).flashcards(.text("Notes"), count: 12, credential: AIReadingFixtures.credential)

        XCTAssertEqual(deck.cards, [AIFlashcard(front: "F", back: "B")])
        let body = try jsonBody(recorder.requests.first)
        XCTAssertEqual(body["count"] as? Int, 12)
        XCTAssertNil(body["difficulty"])
        XCTAssertEqual(recorder.requests.first?.url?.path, "/ai/flashcards")
    }

    func test_busyResponseMapsToBusyErrorWithBackendMessage() async {
        let recorder = TransportRecorder(status: 429, json: #"{"detail": "Voqora is already working on other AI requests. Try again shortly.", "code": "ai_busy"}"#)
        do {
            _ = try await makeClient(recorder).translate("Hi", to: .italian, credential: AIReadingFixtures.credential)
            XCTFail("Expected an error")
        } catch let error as AIReadingError {
            XCTAssertEqual(error.kind, .busy)
            XCTAssertEqual(error.code, "ai_busy")
            XCTAssertEqual(error.message, "Voqora is already working on other AI requests. Try again shortly.")
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    func test_cancelledTransportBecomesCancellationError() async {
        let recorder = TransportRecorder(failure: URLError(.cancelled))
        do {
            _ = try await makeClient(recorder).translate("Hi", to: .italian, credential: AIReadingFixtures.credential)
            XCTFail("Expected an error")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func test_unreachableEngineMapsToEngineUnavailable() async {
        let recorder = TransportRecorder(failure: URLError(.cannotConnectToHost))
        do {
            _ = try await makeClient(recorder).translate("Hi", to: .italian, credential: AIReadingFixtures.credential)
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error as? AIReadingError, .engineUnavailable)
        }
    }

    func test_undecodableSuccessIsAnInvalidResponse() async {
        let recorder = TransportRecorder(json: #"{"unexpected": true}"#)
        do {
            _ = try await makeClient(recorder).summarize(.text("x"), length: .short, language: nil, credential: AIReadingFixtures.credential)
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error as? AIReadingError, .invalidResponse)
        }
    }
}
