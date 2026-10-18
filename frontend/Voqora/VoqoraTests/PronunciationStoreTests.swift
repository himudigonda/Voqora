import Foundation
@testable import Voqora
import XCTest

@MainActor
private final class FakePronunciationService: PronunciationServing {
    var entries: [PronunciationEntry] = []
    var maxEntries = 500
    var createError: Error?
    var createErrorsByMatch: [String: Error] = [:]
    var testResult = PronunciationTestResult(text: "", spoken: "", replacements: 0, version: 1)
    private(set) var created: [PronunciationRequest] = []
    private(set) var testedBookIDs: [String?] = []
    private var nextID = 0

    func list(scope _: PronunciationScope?) async throws -> PronunciationList {
        PronunciationList(version: 1, maxEntries: maxEntries, entries: entries)
    }

    func create(_ request: PronunciationRequest) async throws -> PronunciationEntry {
        if let error = createErrorsByMatch[request.match] ?? createError {
            throw error
        }
        created.append(request)
        nextID += 1
        let entry = PronunciationStoreTests.makeEntry(id: String(format: "%032lx", nextID), match: request.match, scope: request.scope)
        entries.append(entry)
        return entry
    }

    func update(id: String, with request: PronunciationRequest) async throws -> PronunciationEntry {
        PronunciationStoreTests.makeEntry(id: id, match: request.match, scope: request.scope)
    }

    func delete(id: String) async throws {
        entries.removeAll { $0.id == id }
    }

    func test(text _: String, bookID: String?) async throws -> PronunciationTestResult {
        testedBookIDs.append(bookID)
        return testResult
    }
}

@MainActor
final class PronunciationStoreTests: XCTestCase {
    nonisolated static let bookID = PronunciationModelTests.bookID

    static func makeEntry(id: String, match: String, scope: String = "global", replacement: String = "said") -> PronunciationEntry {
        PronunciationEntry(
            id: id,
            match: match,
            replacement: replacement,
            caseSensitive: false,
            wholeWord: true,
            scope: scope,
            createdAt: "2026-10-01T10:00:00Z",
            updatedAt: "2026-10-01T10:00:00Z"
        )
    }

    private func loadedStore(_ service: FakePronunciationService, bookID: String? = nil) async -> PronunciationStore {
        let store = PronunciationStore(service: service, bookID: bookID)
        await store.refresh()
        return store
    }

    func test_visibleEntriesFilterByScopeSearchAndSortByMatch() async {
        let service = FakePronunciationService()
        service.entries = [
            Self.makeEntry(id: String(repeating: "1", count: 32), match: "nginx", replacement: "engine x"),
            Self.makeEntry(id: String(repeating: "2", count: 32), match: "Ciara", scope: Self.bookID, replacement: "keer-uh"),
            Self.makeEntry(id: String(repeating: "3", count: 32), match: "API", replacement: "A P I"),
        ]
        let store = await loadedStore(service)

        XCTAssertEqual(store.visibleEntries.map(\.match), ["API", "Ciara", "nginx"])

        store.filter = .scope(.global)
        XCTAssertEqual(store.visibleEntries.map(\.match), ["API", "nginx"])

        store.filter = .all
        store.searchText = "keer"
        XCTAssertEqual(store.visibleEntries.map(\.match), ["Ciara"])
    }

    func test_bookStoreDefaultsToItsBookAndPassesItToTests() async {
        let service = FakePronunciationService()
        service.testResult = PronunciationTestResult(text: "Ciara", spoken: "keer-uh", replacements: 1, version: 2)
        let store = await loadedStore(service, bookID: Self.bookID)

        await store.runTest("  Ciara  ")

        XCTAssertEqual(store.filter, .scope(.book(Self.bookID)))
        XCTAssertEqual(store.defaultScope, .book(Self.bookID))
        XCTAssertEqual(service.testedBookIDs, [Self.bookID])
        XCTAssertEqual(store.testResult?.spoken, "keer-uh")
        XCTAssertFalse(store.isTesting)
    }

    func test_malformedBookIDIsIgnored() {
        let store = PronunciationStore(service: FakePronunciationService(), bookID: "../etc")

        XCTAssertNil(store.bookID)
        XCTAssertEqual(store.filter, .all)
        XCTAssertEqual(store.defaultScope, .global)
    }

    func test_runTestValidatesTextLocally() async {
        let service = FakePronunciationService()
        let store = await loadedStore(service)

        await store.runTest("   ")
        XCTAssertEqual(store.testError, "Type a sentence to test.")

        await store.runTest(String(repeating: "a", count: 5001))
        XCTAssertEqual(store.testError, "Test up to 5000 characters at a time.")
        XCTAssertTrue(service.testedBookIDs.isEmpty)
    }

    func test_saveAddsEntriesAndMapsMissingBooks() async throws {
        let service = FakePronunciationService()
        let store = await loadedStore(service)

        try await store.save(PronunciationDraft(match: "SQL", replacement: "sequel"), editing: nil)
        XCTAssertEqual(store.entries.map(\.match), ["SQL"])

        service.createError = BackendAPIError.rejected(statusCode: 404, message: "Book not found.")
        do {
            try await store.save(PronunciationDraft(match: "Ciara", scope: .book(Self.bookID)), editing: nil)
            XCTFail("Expected the missing book to be reported")
        } catch {
            XCTAssertEqual(error.localizedDescription, "That book or pronunciation no longer exists. Refresh and try again.")
        }
    }

    func test_saveRejectsInvalidDraftsAndFullDictionaries() async {
        let service = FakePronunciationService()
        service.maxEntries = 1
        service.entries = [Self.makeEntry(id: String(repeating: "a", count: 32), match: "SQL")]
        let store = await loadedStore(service)

        do {
            try await store.save(PronunciationDraft(match: " "), editing: nil)
            XCTFail("Expected local validation")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Enter the text to replace.")
        }
        do {
            try await store.save(PronunciationDraft(match: "API"), editing: nil)
            XCTFail("Expected the limit to be enforced")
        } catch {
            XCTAssertEqual(error.localizedDescription, "You can save up to 1 pronunciations.")
        }
        XCTAssertTrue(service.created.isEmpty)
    }

    func test_importAddsIntoTheCurrentScopeAndCountsDuplicates() async throws {
        let service = FakePronunciationService()
        service.createErrorsByMatch["dup"] = BackendAPIError.rejected(statusCode: 409, message: "A pronunciation for this text already exists in this scope.")
        let store = await loadedStore(service, bookID: Self.bookID)
        let file = #"""
        {"format":"voqora.pronunciations","version":1,"entries":[
          {"match":"Ciara","replacement":"keer-uh","case_sensitive":false,"whole_word":true},
          {"match":"dup","replacement":"x","case_sensitive":false,"whole_word":true},
          {"match":"  ","replacement":"x","case_sensitive":false,"whole_word":true}
        ]}
        """#

        let summary = try await store.importFile(Data(file.utf8))

        XCTAssertEqual(summary, PronunciationImportSummary(added: 1, skipped: 1, invalid: 1, limitReached: false))
        XCTAssertEqual(service.created.map(\.scope), [Self.bookID])
        XCTAssertEqual(store.entries.map(\.match), ["Ciara"])
    }

    func test_importStopsAtTheLimit() async throws {
        let service = FakePronunciationService()
        service.maxEntries = 1
        let store = await loadedStore(service)
        let file = #"""
        {"format":"voqora.pronunciations","version":1,"entries":[
          {"match":"one","replacement":"1","case_sensitive":false,"whole_word":true},
          {"match":"two","replacement":"2","case_sensitive":false,"whole_word":true}
        ]}
        """#

        let summary = try await store.importFile(Data(file.utf8))

        XCTAssertEqual(summary.added, 1)
        XCTAssertTrue(summary.limitReached)
    }

    func test_exportWritesOnlyTheFilteredEntries() async throws {
        let service = FakePronunciationService()
        service.entries = [
            Self.makeEntry(id: String(repeating: "1", count: 32), match: "nginx"),
            Self.makeEntry(id: String(repeating: "2", count: 32), match: "Ciara", scope: Self.bookID),
        ]
        let store = await loadedStore(service)
        store.filter = .scope(.book(Self.bookID))

        let file = try PronunciationTransferFile.decode(store.exportData())

        XCTAssertEqual(file.entries.map(\.match), ["Ciara"])
    }

    func test_exportWithNothingToExportExplains() async {
        let store = await loadedStore(FakePronunciationService())

        XCTAssertThrowsError(try store.exportData()) { error in
            XCTAssertEqual(error.localizedDescription, "There are no pronunciations to export yet.")
        }
    }

    func test_deleteRemovesTheEntry() async throws {
        let service = FakePronunciationService()
        let entry = Self.makeEntry(id: String(repeating: "1", count: 32), match: "nginx")
        service.entries = [entry]
        let store = await loadedStore(service)

        try await store.delete(entry)

        XCTAssertTrue(store.entries.isEmpty)
    }
}
