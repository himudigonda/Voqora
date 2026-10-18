import Foundation
@testable import Voqora
import XCTest

@MainActor
final class InboxStoreTests: XCTestCase {
    private var folder: URL!

    override func setUp() {
        super.setUp()
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoqoraInboxStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    func test_addPersistsMetadataAndBodyAcrossInstances() throws {
        let writer = InboxStore(directory: folder)
        let article = InboxFixtures.article(url: "https://example.com/a", title: "  Deep   Work \n", words: 1200)
        let insertion = try writer.add(article, requestedURL: article.url, at: Date(timeIntervalSince1970: 100))
        guard case let .added(item) = insertion else {
            return XCTFail("Expected a new item")
        }

        let reader = InboxStore(directory: folder)

        XCTAssertEqual(item.title, "Deep Work")
        XCTAssertEqual(reader.items, [item])
        XCTAssertEqual(reader.body(for: item.id), InboxArticleBody(text: article.text, markdown: article.markdown))
        XCTAssertEqual(reader.items.first?.wordCount, 1200)
        XCTAssertNil(reader.persistenceError)
    }

    func test_addingTheSameArticleReturnsTheExistingItem() throws {
        let store = InboxStore(directory: folder)
        let article = InboxFixtures.article(url: "https://example.com/a")
        _ = try store.add(article, requestedURL: article.url, at: Date())

        let requested = try XCTUnwrap(URL(string: "http://EXAMPLE.com/a/#top"))
        let second = try store.add(article, requestedURL: requested, at: Date())

        guard case let .existing(existing) = second else {
            return XCTFail("Expected the existing item")
        }
        XCTAssertEqual(store.items.map(\.id), [existing.id])
    }

    func test_newestItemsComeFirst() throws {
        let store = InboxStore(directory: folder)
        _ = try store.add(InboxFixtures.article(url: "https://example.com/old"), requestedURL: InboxFixtures.url("https://example.com/old"), at: Date(timeIntervalSince1970: 1))
        _ = try store.add(InboxFixtures.article(url: "https://example.com/new"), requestedURL: InboxFixtures.url("https://example.com/new"), at: Date(timeIntervalSince1970: 2))

        XCTAssertEqual(store.items.map(\.url.absoluteString), ["https://example.com/new", "https://example.com/old"])
    }

    func test_progressIsClampedAndArchivedFlagPersists() throws {
        let store = InboxStore(directory: folder)
        let item = try InboxFixtures.addedItem(to: store, url: "https://example.com/a")

        store.setProgress(1.7, for: item.id)
        store.setArchived(true, for: item.id)
        let reader = InboxStore(directory: folder)

        XCTAssertEqual(reader.items.first?.progress, 1)
        XCTAssertEqual(reader.items.first?.isArchived, true)
        store.setProgress(.nan, for: item.id)
        XCTAssertEqual(store.items.first?.progress, 1)
    }

    func test_deleteRemovesTheItemAndItsBody() throws {
        let store = InboxStore(directory: folder)
        let item = try InboxFixtures.addedItem(to: store, url: "https://example.com/a")

        store.delete(item.id)

        XCTAssertTrue(store.items.isEmpty)
        XCTAssertNil(store.body(for: item.id))
        XCTAssertTrue(InboxStore(directory: folder).items.isEmpty)
    }

    func test_evictionsDropOldestArchivedItemsFirst() {
        let items = [
            InboxFixtures.item(addedAt: 4, archived: false),
            InboxFixtures.item(addedAt: 3, archived: true),
            InboxFixtures.item(addedAt: 2, archived: false),
            InboxFixtures.item(addedAt: 1, archived: false),
        ]

        let evicted = InboxStore.evictions(from: items, capacity: 2)

        XCTAssertEqual(evicted, [items[1].id, items[3].id])
        XCTAssertTrue(InboxStore.evictions(from: items, capacity: 4).isEmpty)
    }

    func test_eraseAllRemovesEverythingAndIsIdempotent() throws {
        let store = InboxStore(directory: folder)
        _ = try InboxFixtures.addedItem(to: store, url: "https://example.com/a")

        try store.eraseAll()

        XCTAssertTrue(store.items.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertNoThrow(try store.eraseAll())
    }

    func test_unreadableIndexIsSetAsideWithAMessage() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: folder.appendingPathComponent("items.json"))

        let store = InboxStore(directory: folder)

        XCTAssertTrue(store.items.isEmpty)
        XCTAssertEqual(store.persistenceError, InboxStore.Message.loadFailed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("items.json").path))
    }

    func test_cleanedCollapsesWhitespaceAndLimitsLength() {
        XCTAssertEqual(InboxStore.cleaned("  a \n b  ", limit: 10), "a b")
        XCTAssertEqual(InboxStore.cleaned("abcdef", limit: 3), "abc")
        XCTAssertNil(InboxStore.cleaned(" \n ", limit: 3))
    }

    func test_filtersSplitUnreadArchivedAndAll() {
        let unread = InboxFixtures.item(addedAt: 3, archived: false, title: "Swift Concurrency")
        let finished = InboxFixtures.item(addedAt: 2, archived: false, progress: 0.99, title: "Finished piece")
        let archived = InboxFixtures.item(addedAt: 1, archived: true, title: "Old news")
        let items = [unread, finished, archived]

        XCTAssertEqual(InboxFilter.visible(items, filter: .unread, query: ""), [unread])
        XCTAssertEqual(InboxFilter.visible(items, filter: .archived, query: ""), [archived])
        XCTAssertEqual(InboxFilter.visible(items, filter: .all, query: ""), items)
        XCTAssertEqual(InboxFilter.visible(items, filter: .all, query: " swift "), [unread])
        XCTAssertEqual(InboxFilter.visible(items, filter: .all, query: "example.com"), items)
    }

    func test_listeningTimeUsesWordCountAndSpeed() {
        XCTAssertEqual(InboxListeningTime.minutes(wordCount: 1650, speed: 1), 10)
        XCTAssertEqual(InboxListeningTime.minutes(wordCount: 1650, speed: 2), 5)
        XCTAssertEqual(InboxListeningTime.minutes(wordCount: 10, speed: 1), 1)
        XCTAssertEqual(InboxListeningTime.minutes(wordCount: 1650, speed: 9), 5)
        XCTAssertEqual(InboxListeningTime.label(wordCount: 1650, speed: 1), "10 min listen")
        XCTAssertEqual(InboxListeningTime.label(wordCount: 165 * 90, speed: 1), "1 hr 30 min listen")
        XCTAssertEqual(InboxListeningTime.label(wordCount: 165 * 60, speed: 1), "1 hr listen")
    }
}

@MainActor
enum InboxFixtures {
    static func url(_ string: String) -> URL {
        URL(string: string) ?? URL(fileURLWithPath: "/")
    }

    static func article(
        url: String,
        title: String = "An Article",
        words: Int = 400,
        text: String = "First paragraph.\n\nSecond paragraph."
    ) -> ExtractedArticle {
        ExtractedArticle(
            url: self.url(url),
            title: title,
            byline: "Ada Lovelace",
            siteName: "Example",
            language: "en",
            text: text,
            markdown: "# \(title)\n\n\(text)",
            wordCount: words
        )
    }

    static func addedItem(to store: InboxStore, url: String, text: String = "Body text.") throws -> InboxItem {
        let extracted = Self.article(url: url, text: text)
        guard case let .added(item) = try store.add(extracted, requestedURL: extracted.url, at: Date()) else {
            throw InboxFixtureError.notAdded
        }
        return item
    }

    static func item(
        addedAt seconds: TimeInterval,
        archived: Bool,
        progress: Double = 0,
        title: String = "Item"
    ) -> InboxItem {
        InboxItem(
            id: UUID(),
            title: title,
            siteName: nil,
            byline: nil,
            url: url("https://example.com/\(Int(seconds))"),
            language: nil,
            wordCount: 100,
            addedAt: Date(timeIntervalSince1970: seconds),
            progress: progress,
            isArchived: archived
        )
    }
}

enum InboxFixtureError: Error {
    case notAdded
}
