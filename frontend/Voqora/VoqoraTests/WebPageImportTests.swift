@testable import Voqora
import XCTest

@MainActor
final class WebPageImportTests: XCTestCase {
    func test_validate_acceptsHTTPAndHTTPSLinks() {
        XCTAssertEqual(try WebPageLink.validate("https://example.com/story?id=1").get().absoluteString, "https://example.com/story?id=1")
        XCTAssertEqual(try WebPageLink.validate("  http://example.com/a  ").get().absoluteString, "http://example.com/a")
        XCTAssertNoThrow(try WebPageLink.validate("HTTPS://Example.com").get())
    }

    func test_validate_addsHTTPSWhenTheSchemeIsMissing() {
        XCTAssertEqual(try WebPageLink.validate("example.com/article").get().absoluteString, "https://example.com/article")
    }

    func test_validate_rejectsEmptyAndNonWebLinks() {
        XCTAssertEqual(problem(for: ""), .empty)
        XCTAssertEqual(problem(for: "   \n"), .empty)
        XCTAssertEqual(problem(for: "ftp://example.com/file"), .notWebLink)
        XCTAssertEqual(problem(for: "file:///Users/me/notes.html"), .notWebLink)
        XCTAssertEqual(problem(for: "javascript://alert(1)"), .notWebLink)
        XCTAssertEqual(problem(for: "https://"), .notWebLink)
        XCTAssertEqual(problem(for: "https://exa mple.com"), .notWebLink)
    }

    func test_validate_rejectsCredentialsAndOverlongLinks() {
        XCTAssertEqual(problem(for: "https://user:pass@example.com/"), .containsCredentials)
        XCTAssertEqual(problem(for: "https://user@example.com/"), .containsCredentials)
        XCTAssertEqual(problem(for: "https://example.com/" + String(repeating: "a", count: 2100)), .tooLong)
    }

    func test_problemMessagesAreReadable() {
        for problem in [WebPageLink.Problem.empty, .notWebLink, .containsCredentials, .tooLong] {
            XCTAssertFalse(problem.message.isEmpty)
            XCTAssertFalse(problem.message.contains("—"))
        }
    }

    func test_siteNameDropsWWW() {
        XCTAssertEqual(WebPageLink.siteName(of: TestLinks.url("https://www.Example.com/a")), "example.com")
        XCTAssertEqual(WebPageLink.siteName(of: TestLinks.url("https://news.example.org")), "news.example.org")
    }

    func test_importSource_describesDocumentsAndPages() {
        let document = AudiobookImportSource.document(URL(fileURLWithPath: "/tmp/Moby_Dick.epub"))
        let page = AudiobookImportSource.webPage(TestLinks.url("https://www.example.com/story"))

        XCTAssertEqual(document.displayName, "Moby Dick")
        XCTAssertEqual(page.displayName, "example.com")
        XCTAssertNotNil(document.documentURL)
        XCTAssertNil(document.webPageURL)
        XCTAssertNotNil(page.webPageURL)
        XCTAssertNil(page.documentURL)
        XCTAssertNotEqual(document.identifier, page.identifier)
    }

    func test_backendCodesMapToClearMessages() {
        let codes = [
            "blocked_address", "too_large", "timeout", "no_readable_content", "unsupported_type",
            "paywalled", "invalid_url", "unreachable", "not_found", "http_error", "too_many_redirects", "busy",
        ]
        for code in codes {
            let message = WebPageImportMessage.message(for: AudiobookAPIFailure(statusCode: 400, detail: "raw detail", code: code))
            XCTAssertNotEqual(message, "raw detail", code)
            XCTAssertFalse(message.contains("—"), code)
        }
        XCTAssertTrue(
            WebPageImportMessage.message(for: AudiobookAPIFailure(statusCode: 422, code: "paywalled")).contains("subscription")
        )
        XCTAssertTrue(
            WebPageImportMessage.message(for: AudiobookAPIFailure(statusCode: 403, code: "blocked_address")).contains("private network")
        )
    }

    func test_detailOnlyErrorsKeepTheBackendMessage() {
        let failure = AudiobookAPIFailure(statusCode: 413, detail: "This document has more than 2000 pages.")
        XCTAssertEqual(WebPageImportMessage.message(for: failure), "This document has more than 2000 pages.")
    }

    func test_validationListsAndUnknownErrorsGetFriendlyFallbacks() {
        XCTAssertEqual(
            WebPageImportMessage.message(for: AudiobookAPIFailure(statusCode: 422)),
            "Check the link and the narration settings, then try again."
        )
        XCTAssertEqual(WebPageImportMessage.message(for: AudiobookAPIFailure(statusCode: 500)), WebPageImportMessage.generic)
        XCTAssertEqual(WebPageImportMessage.message(for: URLError(.timedOut)), WebPageImportMessage.timeoutMessage)
        XCTAssertEqual(WebPageImportMessage.message(for: URLError(.cannotConnectToHost)), WebPageImportMessage.generic)
    }

    func test_requestBodyUsesSnakeCaseAndSkipsMissingValues() throws {
        let cloud = LLMCredential(provider: .openai, apiKey: "sk-test", model: "", serverURL: "https://ignored.example")
        let body = WebPageImportBody(url: TestLinks.url("https://example.com"), voice: "af_bella", speed: 1.5, engine: nil, cleanup: cloud)

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any])

        XCTAssertEqual(json["url"] as? String, "https://example.com")
        XCTAssertEqual(json["llm_provider"] as? String, "openai")
        XCTAssertEqual(json["llm_model"] as? String, LLMProvider.openai.defaultModel)
        XCTAssertNil(json["llm_base_url"])
        XCTAssertNil(json["engine"])
        XCTAssertNil(json["api_key"])
    }

    private func problem(for input: String) -> WebPageLink.Problem? {
        guard case let .failure(problem) = WebPageLink.validate(input) else { return nil }
        return problem
    }
}
