import Foundation
@testable import Voqora
import XCTest

final class InboxStubURLProtocol: URLProtocol {
    struct Reply {
        let status: Int
        let body: Data
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var reply = Reply(status: 200, body: Data())
    private nonisolated(unsafe) static var captured: [(request: URLRequest, body: Data)] = []

    private static func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    static func respond(status: Int, json: String) {
        locked {
            reply = Reply(status: status, body: Data(json.utf8))
            captured = []
        }
    }

    static var requests: [(request: URLRequest, body: Data)] {
        locked { captured }
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InboxStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let body = Self.bodyData(of: request)
        let current = Self.locked {
            Self.captured.append((request, body))
            return Self.reply
        }
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: current.status,
                  httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "application/json"]
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: current.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func bodyData(of request: URLRequest) -> Data {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

@MainActor
final class ArticleServiceTests: XCTestCase {
    private func makeService() throws -> ArticleService {
        let baseURL = try XCTUnwrap(URL(string: "http://127.0.0.1:9"))
        return ArticleService(
            connection: BackendConnection(baseURL: baseURL, token: "test-token"),
            session: InboxStubURLProtocol.makeSession()
        )
    }

    private func json(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func test_extractPostsTheLinkAndDecodesTheArticle() async throws {
        InboxStubURLProtocol.respond(status: 200, json: """
        {"url": "https://example.com/final", "title": "A Title", "byline": null, "site_name": "Example",
         "language": "en-gb", "text": "Body", "markdown": "# A Title\\n\\nBody", "word_count": 512}
        """)
        let service = try makeService()
        let link = try XCTUnwrap(URL(string: "https://example.com/start"))

        let article = try await service.extract(link)

        XCTAssertEqual(article.url.absoluteString, "https://example.com/final")
        XCTAssertEqual(article.title, "A Title")
        XCTAssertNil(article.byline)
        XCTAssertEqual(article.siteName, "Example")
        XCTAssertEqual(article.language, "en-gb")
        XCTAssertEqual(article.markdown, "# A Title\n\nBody")
        XCTAssertEqual(article.wordCount, 512)
        let sent = try XCTUnwrap(InboxStubURLProtocol.requests.first)
        XCTAssertEqual(sent.request.url?.path, "/article/extract")
        XCTAssertEqual(sent.request.httpMethod, "POST")
        XCTAssertEqual(sent.request.value(forHTTPHeaderField: "X-Voqora-IPC-Token"), "test-token")
        XCTAssertEqual(sent.request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(try json(sent.body) as? [String: String], ["url": "https://example.com/start"])
    }

    func test_extractMapsBackendErrorCodes() async throws {
        let service = try makeService()
        let link = try XCTUnwrap(URL(string: "https://example.com/start"))
        let cases: [(Int, String, ArticleServiceError.Reason)] = [
            (422, "paywalled", .paywalled),
            (415, "pdf_document", .pdfDocument),
            (403, "blocked_address", .blockedAddress),
            (429, "busy", .busy),
            (502, "not_found", .notFound),
            (504, "timeout", .timeout),
        ]
        for (status, code, reason) in cases {
            InboxStubURLProtocol.respond(status: status, json: #"{"detail": "Backend says no.", "code": "\#(code)"}"#)
            do {
                _ = try await service.extract(link)
                XCTFail("Expected \(code) to fail")
            } catch let error as ArticleServiceError {
                XCTAssertEqual(error.reason, reason)
                XCTAssertNotEqual(error.errorDescription, "Backend says no.")
            }
        }
    }

    func test_validationErrorsWithoutACodeMeanTheLinkIsInvalid() {
        let body = Data(#"{"detail": [{"loc": ["body", "url"], "msg": "too long"}]}"#.utf8)

        XCTAssertEqual(ArticleService.failure(status: 422, data: body).reason, .invalidURL)
    }

    func test_detailOnlyErrorsShowTheBackendMessage() {
        let body = Data(#"{"detail": "File exceeds 100 MB limit."}"#.utf8)

        let error = ArticleService.failure(status: 413, data: body)

        XCTAssertEqual(error.reason, .rejected)
        XCTAssertEqual(error.errorDescription, "File exceeds 100 MB limit.")
    }

    func test_unknownFailuresFallBackToAGenericMessage() {
        let error = ArticleService.failure(status: 500, data: Data("oops".utf8))

        XCTAssertEqual(error.reason, .rejected)
        XCTAssertEqual(error.errorDescription, "Voqora couldn't add that page. Try again.")
    }

    func test_createAudiobookPostsNarrationAndDecodesTheEstimate() async throws {
        InboxStubURLProtocol.respond(status: 200, json: InboxFixtureJSON.estimate(bookID: "book-1", duplicateOf: nil))
        let service = try makeService()
        let link = try XCTUnwrap(URL(string: "https://example.com/story"))

        let estimate = try await service.createAudiobook(from: link, narration: AudiobookNarration(voice: "af_bella", speed: 3))

        XCTAssertEqual(estimate.bookID, "book-1")
        XCTAssertNil(estimate.duplicateOfBookID)
        let sent = try XCTUnwrap(InboxStubURLProtocol.requests.first)
        XCTAssertEqual(sent.request.url?.path, "/audiobook/url")
        let payload = try json(sent.body)
        XCTAssertEqual(payload["url"] as? String, "https://example.com/story")
        XCTAssertEqual(payload["voice"] as? String, "af_bella")
        XCTAssertEqual(payload["speed"] as? Double, 2.0)
        XCTAssertEqual(payload["engine"] as? String, "kokoro")
    }

    func test_unpreparedConnectionReportsTheEngineIsStarting() async throws {
        let baseURL = try XCTUnwrap(URL(string: "http://127.0.0.1:9"))
        let connection = BackendConnection(baseURL: baseURL, token: "test-token")
        connection.invalidate()
        let service = ArticleService(connection: connection, session: InboxStubURLProtocol.makeSession())
        let link = try XCTUnwrap(URL(string: "https://example.com/story"))

        do {
            _ = try await service.extract(link)
            XCTFail("Expected the request to fail")
        } catch let error as ArticleServiceError {
            XCTAssertEqual(error.reason, .engineUnavailable)
        }
    }
}

enum InboxFixtureJSON {
    static func estimate(bookID: String, duplicateOf: String?) -> String {
        let duplicate = duplicateOf.map { "\"\($0)\"" } ?? "null"
        return """
        {"book_id": "\(bookID)", "title": "Story", "page_count": 1, "word_count_estimate": 900,
         "estimated_processing_seconds": 12.0, "estimated_audio_seconds": 300.0, "estimated_cost_usd": 0.0,
         "maximum_cost_usd": 0.0, "estimated_token_count": 0, "is_image_only": false, "cost_warning": false,
         "llm_provider": null, "llm_model": null, "pricing_known": true, "reads_images": true,
         "duplicate_of_book_id": \(duplicate), "duplicate_of_title": null, "author": null}
        """
    }
}
