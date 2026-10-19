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
