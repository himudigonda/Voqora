import Foundation
@testable import Voqora
import XCTest

@MainActor
final class DictationTranscriptStoreTests: XCTestCase {
    private var folder: URL!

    override func setUp() {
        super.setUp()
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoqoraDictationTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    private var storageURL: URL {
        folder.appendingPathComponent("dictation-transcripts.json")
    }

    func test_addTrimsTextAndPersistsAcrossInstances() throws {
        let writer = DictationTranscriptStore(storageURL: storageURL)
        let saved = try XCTUnwrap(writer.add("  Buy oat milk.\n", localeIdentifier: "en_US"))

        let reader = DictationTranscriptStore(storageURL: storageURL)

        XCTAssertEqual(saved.text, "Buy oat milk.")
        XCTAssertEqual(reader.transcripts.map(\.id), [saved.id])
        XCTAssertEqual(reader.transcripts.first?.text, "Buy oat milk.")
        XCTAssertEqual(reader.transcripts.first?.localeIdentifier, "en_US")
        XCTAssertNil(reader.persistenceError)
    }

    func test_blankTranscriptsAreIgnored() {
        let store = DictationTranscriptStore(storageURL: storageURL)

        XCTAssertNil(store.add(" \n\t ", localeIdentifier: nil))
        XCTAssertTrue(store.transcripts.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storageURL.path))
    }

    func test_newestTranscriptComesFirstAndCapacityIsEnforced() {
        let store = DictationTranscriptStore(storageURL: storageURL)
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        for index in 0 ..< DictationTranscriptStore.capacity + 5 {
            store.add("Note \(index)", localeIdentifier: nil, at: start.addingTimeInterval(Double(index)))
        }

        XCTAssertEqual(store.transcripts.count, DictationTranscriptStore.capacity)
        XCTAssertEqual(store.transcripts.first?.text, "Note \(DictationTranscriptStore.capacity + 4)")
        XCTAssertEqual(store.transcripts.last?.text, "Note 5")
    }

    func test_deleteAndClearPersist() throws {
        let store = DictationTranscriptStore(storageURL: storageURL)
        let first = try XCTUnwrap(store.add("First", localeIdentifier: nil))
        store.add("Second", localeIdentifier: nil)

        store.delete(first)
        XCTAssertEqual(DictationTranscriptStore(storageURL: storageURL).transcripts.map(\.text), ["Second"])

        store.clear()
        XCTAssertTrue(DictationTranscriptStore(storageURL: storageURL).transcripts.isEmpty)
    }

    func test_eraseAllRemovesTheFileAndIsIdempotent() throws {
        let store = DictationTranscriptStore(storageURL: storageURL)
        store.add("Private thought", localeIdentifier: nil)
        XCTAssertTrue(FileManager.default.fileExists(atPath: storageURL.path))

        try store.eraseAll()

        XCTAssertTrue(store.transcripts.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storageURL.path))
        XCTAssertNoThrow(try store.eraseAll())
    }

    func test_unreadableFileIsSetAsideAndReported() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: storageURL)

        let store = DictationTranscriptStore(storageURL: storageURL)

        XCTAssertTrue(store.transcripts.isEmpty)
        XCTAssertNotNil(store.persistenceError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storageURL.path))
    }

    func test_writeFailureIsReported() throws {
        try FileManager.default.createDirectory(at: storageURL, withIntermediateDirectories: true)
        let store = DictationTranscriptStore(storageURL: storageURL)

        store.add("Cannot be written over a directory", localeIdentifier: nil)

        XCTAssertNotNil(store.persistenceError)
    }

    func test_matchingIsCaseInsensitiveAndIgnoresBlankQueries() {
        let transcripts = [
            DictationTranscript(id: UUID(), text: "Call the Dentist", createdAt: Date(), localeIdentifier: nil),
            DictationTranscript(id: UUID(), text: "Water the plants", createdAt: Date(), localeIdentifier: nil),
        ]

        XCTAssertEqual(DictationTranscriptStore.matching(transcripts, query: "dentist").map(\.text), ["Call the Dentist"])
        XCTAssertEqual(DictationTranscriptStore.matching(transcripts, query: "  ").count, 2)
        XCTAssertTrue(DictationTranscriptStore.matching(transcripts, query: "taxes").isEmpty)
    }

    func test_rawTextIsKeptOnlyWhenItDiffersFromTheText() throws {
        let store = DictationTranscriptStore(storageURL: storageURL)
        let tidied = try XCTUnwrap(store.add("Hello, world.", rawText: "hello world", localeIdentifier: nil))
        let same = try XCTUnwrap(store.add("hello world", rawText: "hello world", localeIdentifier: nil))
        let none = try XCTUnwrap(store.add("plain", localeIdentifier: nil))

        XCTAssertEqual(tidied.rawText, "hello world")
        XCTAssertNil(same.rawText)
        XCTAssertNil(none.rawText)
        XCTAssertEqual(DictationTranscriptStore(storageURL: storageURL).transcripts.first { $0.id == tidied.id }?.rawText, "hello world")
    }

    func test_filesWrittenBeforeRawTextExistedStillDecode() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let legacy = #"[{"id":"\#(UUID().uuidString)","text":"Old note","createdAt":700000000,"localeIdentifier":"en_US"}]"#
        try Data(legacy.utf8).write(to: storageURL)

        let store = DictationTranscriptStore(storageURL: storageURL)

        XCTAssertEqual(store.transcripts.map(\.text), ["Old note"])
        XCTAssertNil(store.transcripts.first?.rawText)
    }
}
