import Foundation
@testable import Voqora
import XCTest

final class InboxLinkParserTests: XCTestCase {
    func test_acceptsPlainWebLinks() {
        XCTAssertEqual(
            InboxLinkParser.webURL(from: "  https://example.com/story?id=4\n")?.absoluteString,
            "https://example.com/story?id=4"
        )
        XCTAssertEqual(InboxLinkParser.webURL(from: "http://example.com")?.absoluteString, "http://example.com")
    }

    func test_findsTheFirstLinkInsideText() {
        let url = InboxLinkParser.webURL(from: "Worth a read: https://news.example.org/a/b and more")

        XCTAssertEqual(url?.absoluteString, "https://news.example.org/a/b")
    }

    func test_bareDomainsBecomeWebLinks() {
        let url = InboxLinkParser.webURL(from: "example.com/article")
        XCTAssertEqual(url?.host, "example.com")
        XCTAssertTrue(["http", "https"].contains(url?.scheme ?? ""))
    }

    func test_rejectsNonWebAndCredentialLinks() {
        XCTAssertNil(InboxLinkParser.webURL(from: ""))
        XCTAssertNil(InboxLinkParser.webURL(from: "just some words"))
        XCTAssertNil(InboxLinkParser.webURL(from: "ftp://example.com/file"))
        XCTAssertNil(InboxLinkParser.webURL(from: "file:///Users/me/notes.txt"))
        XCTAssertNil(InboxLinkParser.webURL(from: "https://user:secret@example.com/"))
    }

    func test_rejectsLinksLongerThanTheBackendLimit() {
        let long = "https://example.com/" + String(repeating: "a", count: InboxLinkParser.maximumURLLength)

        XCTAssertNil(InboxLinkParser.webURL(from: long))
    }

    func test_readsLinksFromWeblocFiles() throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["URL": "https://example.com/saved"],
            format: .xml,
            options: 0
        )

        XCTAssertEqual(InboxLinkParser.webURL(fromWebloc: data)?.absoluteString, "https://example.com/saved")
        XCTAssertNil(InboxLinkParser.webURL(fromWebloc: Data("not a plist".utf8)))
    }

    func test_weblocDetectionUsesTheFileExtension() throws {
        let webloc = try XCTUnwrap(URL(string: "file:///tmp/Link.WEBLOC"))
        let other = try XCTUnwrap(URL(string: "file:///tmp/Link.txt"))

        XCTAssertTrue(InboxLinkParser.isWebloc(webloc))
        XCTAssertFalse(InboxLinkParser.isWebloc(other))
    }

    func test_matchKeyIgnoresSchemeCaseFragmentsAndTrailingSlash() throws {
        let first = try XCTUnwrap(URL(string: "http://Example.com/Story/#comments"))
        let second = try XCTUnwrap(URL(string: "https://example.com/Story"))
        let different = try XCTUnwrap(URL(string: "https://example.com/story"))

        XCTAssertEqual(InboxLinkParser.matchKey(for: first), InboxLinkParser.matchKey(for: second))
        XCTAssertNotEqual(InboxLinkParser.matchKey(for: second), InboxLinkParser.matchKey(for: different))
    }

    func test_displayHostDropsWWW() throws {
        let url = try XCTUnwrap(URL(string: "https://www.Example.com/a"))

        XCTAssertEqual(InboxLinkParser.displayHost(of: url), "example.com")
    }
}
