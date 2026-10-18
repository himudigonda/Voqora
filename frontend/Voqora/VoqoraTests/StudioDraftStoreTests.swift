import Foundation
@testable import Voqora
import XCTest

@MainActor
final class StudioDraftStoreTests: XCTestCase {
    private var url: URL!

    override func setUp() {
        super.setUp()
        url = StudioFixtures.temporaryURL()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        super.tearDown()
    }

    func test_savedDraftsReloadNewestFirst() {
        let store = StudioDraftStore(storageURL: url)
        let older = PodcastDraft(script: StudioFixtures.script(), updatedAt: Date(timeIntervalSince1970: 1000))
        var newerScript = StudioFixtures.script(turns: 3)
        newerScript.title = "Second"
        let newer = PodcastDraft(script: newerScript, updatedAt: Date(timeIntervalSince1970: 2000), basedOnBookID: "book-1")

        XCTAssertTrue(store.save(older))
        XCTAssertTrue(store.save(newer))
        let reloaded = StudioDraftStore(storageURL: url)

        XCTAssertEqual(reloaded.drafts.map(\.id), [newer.id, older.id])
        XCTAssertEqual(reloaded.drafts.first?.script.title, "Second")
        XCTAssertEqual(reloaded.drafts.first?.script.turns.count, 3)
        XCTAssertEqual(reloaded.drafts.first?.basedOnBookID, "book-1")
        XCTAssertNil(reloaded.persistenceError)
    }

    func test_savingAgainReplacesTheDraft() {
        let store = StudioDraftStore(storageURL: url)
        var draft = PodcastDraft(script: StudioFixtures.script())
        store.save(draft)
        draft.script.title = "Renamed"
        draft.updatedAt = Date()

        store.save(draft)

        XCTAssertEqual(store.drafts.count, 1)
        XCTAssertEqual(StudioDraftStore(storageURL: url).draft(withID: draft.id)?.script.title, "Renamed")
    }

    func test_deleteRemovesTheDraftFromDisk() {
        let store = StudioDraftStore(storageURL: url)
        let draft = PodcastDraft(script: StudioFixtures.script())
        store.save(draft)

        store.delete(draft.id)

        XCTAssertTrue(store.drafts.isEmpty)
        XCTAssertTrue(StudioDraftStore(storageURL: url).drafts.isEmpty)
    }

    func test_unreadableFileIsSetAsideWithAMessage() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)

        let store = StudioDraftStore(storageURL: url)

        XCTAssertTrue(store.drafts.isEmpty)
        XCTAssertNotNil(store.persistenceError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let siblings = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        XCTAssertTrue(siblings.contains { $0.contains("unreadable") })
    }

    func test_corruptEntriesAreSkipped() throws {
        let store = StudioDraftStore(storageURL: url)
        let draft = PodcastDraft(script: StudioFixtures.script())
        store.save(draft)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var drafts = try XCTUnwrap(object["drafts"] as? [Any])
        drafts.append(["id": "nope"])
        object["drafts"] = drafts
        try JSONSerialization.data(withJSONObject: object).write(to: url)

        let reloaded = StudioDraftStore(storageURL: url)

        XCTAssertEqual(reloaded.drafts.map(\.id), [draft.id])
        XCTAssertNil(reloaded.persistenceError)
    }

    func test_unwritableLocationReportsError() throws {
        let blocker = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: blocker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("file".utf8).write(to: blocker)
        let store = StudioDraftStore(storageURL: url)

        XCTAssertFalse(store.save(PodcastDraft(script: StudioFixtures.script())))
        XCTAssertNotNil(store.persistenceError)
        try? FileManager.default.removeItem(at: blocker)
    }
}
