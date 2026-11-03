import Foundation
@testable import Voqora
import XCTest

private final class TidyTransport: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequests: [URLRequest] = []
    private let json: String

    init(json: String) {
        self.json = json
    }

    var requests: [URLRequest] {
        lock.withLock { storedRequests }
    }

    var transport: AIReadingTransport {
        { [self] request in
            lock.withLock { storedRequests.append(request) }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(json.utf8), response)
        }
    }
}

@MainActor
final class AITidyClientTests: XCTestCase {
    private let usageJSON = #""tokens": 42, "tokens_estimated": true, "cost_usd": null, "provider": "openai", "model": "gpt-test""#

    private func makeClient(_ recorder: TidyTransport) -> AIReadingClient {
        let connection = BackendConnection(baseURL: URL(string: "http://127.0.0.1:9000")!, token: "ipc-secret")
        return AIReadingClient(connection: connection, transport: recorder.transport)
    }

    func test_tidyPostsTextAndDecodesCleanedText() async throws {
        let recorder = TidyTransport(json: #"{"text": "Hello, world.", \#(usageJSON)}"#)
        let result = try await makeClient(recorder).tidy(text: "um hello world", credential: AIReadingFixtures.credential)

        XCTAssertEqual(result.text, "Hello, world.")
        XCTAssertEqual(result.usage.tokens, 42)
        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.url?.path, "/ai/tidy")
        XCTAssertEqual(request.httpMethod, "POST")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["text"] as? String, "um hello world")
    }

    func test_tidyRejectsABlankReply() async {
        let recorder = TidyTransport(json: #"{"text": "  ", \#(usageJSON)}"#)
        do {
            _ = try await makeClient(recorder).tidy(text: "hello", credential: AIReadingFixtures.credential)
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error as? AIReadingError, .invalidResponse)
        }
    }
}

private final class AIRunRecorder {
    var runs: [AIRun] = []
}

@MainActor
final class AIReadingWordCountTests: XCTestCase {
    private let usageJSON = #""tokens": 42, "tokens_estimated": true, "cost_usd": null, "provider": "openai", "model": "gpt""#

    private func makeClient(status: Int = 200, json: String, recorder: AIRunRecorder) -> AIReadingClient {
        AIReadingClient(
            connection: BackendConnection(baseURL: URL(string: "http://127.0.0.1:9000")!, token: "ipc-secret"),
            transport: { request in
                (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            },
            recordRun: { recorder.runs.append($0) }
        )
    }

    func test_textSummaryCountsWordsSentAndReturned() async throws {
        let recorder = AIRunRecorder()
        let client = makeClient(json: #"{"summary": "Two words", "chunks": 1, \#(usageJSON)}"#, recorder: recorder)

        _ = try await client.summarize(.text("one two  three\nfour"), length: .short, language: nil, credential: AIReadingFixtures.credential)

        let run = try XCTUnwrap(recorder.runs.first)
        XCTAssertTrue(run.ok)
        XCTAssertEqual(run.wordsIn, 4)
        XCTAssertEqual(run.wordsOut, 2)
    }

    func test_bookSummaryUsesTheBackendsSourceWordCount() async throws {
        let recorder = AIRunRecorder()
        let client = makeClient(json: #"{"summary": "Short", "chunks": 1, "source_words": 5000, \#(usageJSON)}"#, recorder: recorder)

        _ = try await client.summarize(.book(AIReadingFixtures.bookID), length: .short, language: nil, credential: AIReadingFixtures.credential)

        XCTAssertEqual(recorder.runs.first?.wordsIn, 5000)
        XCTAssertEqual(recorder.runs.first?.wordsOut, 1)
    }

    func test_olderBackendWithoutSourceWordsFallsBackToTheRequest() async throws {
        let recorder = AIRunRecorder()
        let client = makeClient(json: #"{"summary": "Short", "chunks": 1, \#(usageJSON)}"#, recorder: recorder)

        _ = try await client.summarize(.book(AIReadingFixtures.bookID), length: .short, language: nil, credential: AIReadingFixtures.credential)

        XCTAssertEqual(recorder.runs.first?.wordsIn, 0)
    }

    func test_askCountsTheQuestionAndHistory() async throws {
        let recorder = AIRunRecorder()
        let client = makeClient(json: #"{"answer": "It is red", "citations": [], "found": true, \#(usageJSON)}"#, recorder: recorder)

        _ = try await client.ask(
            bookID: AIReadingFixtures.bookID,
            question: "What color",
            history: [AIChatTurn(role: .user, content: "one two"), AIChatTurn(role: .assistant, content: "three")],
            credential: AIReadingFixtures.credential
        )

        XCTAssertEqual(recorder.runs.first?.wordsIn, 5)
        XCTAssertEqual(recorder.runs.first?.wordsOut, 3)
    }

    func test_quizAndFlashcardsCountEveryGeneratedField() async throws {
        let recorder = AIRunRecorder()
        let quizClient = makeClient(
            json: #"{"questions": [{"question": "Why so", "choices": ["a b", "c", "d", "e"], "answer_index": 0, "explanation": "Because"}], \#(usageJSON)}"#,
            recorder: recorder
        )
        _ = try await quizClient.quiz(.text("x"), count: 3, difficulty: .easy, credential: AIReadingFixtures.credential)
        let cardClient = makeClient(json: #"{"cards": [{"front": "a b", "back": "c d e"}], \#(usageJSON)}"#, recorder: recorder)
        _ = try await cardClient.flashcards(.text("x"), count: 5, credential: AIReadingFixtures.credential)

        XCTAssertEqual(recorder.runs.map(\.wordsOut), [8, 5])
    }

    func test_failedRequestCountsWordsSentAndNoneReturned() async throws {
        let recorder = AIRunRecorder()
        let client = makeClient(status: 500, json: "{}", recorder: recorder)

        do {
            _ = try await client.translate("one two three", to: .spanish, credential: AIReadingFixtures.credential)
            XCTFail("Expected an error")
        } catch {
            let run = try XCTUnwrap(recorder.runs.first)
            XCTAssertFalse(run.ok)
            XCTAssertEqual(run.wordsIn, 3)
            XCTAssertEqual(run.wordsOut, 0)
        }
    }

    func test_undecodableReplyRecordsAFailureWithNoWordsOut() async throws {
        let recorder = AIRunRecorder()
        let client = makeClient(json: "not json", recorder: recorder)

        do {
            _ = try await client.tidy(text: "one two", credential: AIReadingFixtures.credential)
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(recorder.runs.first?.ok, false)
            XCTAssertEqual(recorder.runs.first?.wordsOut, 0)
        }
    }

    func test_cancelledRequestIsNotRecorded() async throws {
        let recorder = AIRunRecorder()
        let client = try AIReadingClient(
            connection: BackendConnection(baseURL: XCTUnwrap(URL(string: "http://127.0.0.1:9000")), token: "ipc-secret"),
            transport: { _ in throw CancellationError() },
            recordRun: { recorder.runs.append($0) }
        )

        do {
            _ = try await client.tidy(text: "one two", credential: AIReadingFixtures.credential)
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertTrue(recorder.runs.isEmpty)
    }
}
