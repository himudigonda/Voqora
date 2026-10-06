@testable import Voqora
import XCTest

@MainActor
final class HistoryManagerTests: XCTestCase {
    func test_historyPersistsEntriesAndFavoritesAcrossManagerInstances() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoqoraHistoryTests-\(UUID().uuidString)", isDirectory: true)
        let storageURL = folder.appendingPathComponent("history.json")
        defer { try? FileManager.default.removeItem(at: folder) }

        let writer = HistoryManager(storageURL: storageURL)
        writer.log(text: "A saved Voqora clip", voice: "af_bella")
        let savedEntry = try XCTUnwrap(writer.history.first)
        writer.toggleFavorite(entry: savedEntry)

        let reader = HistoryManager(storageURL: storageURL)
        let restoredEntry = try XCTUnwrap(reader.history.first)
        XCTAssertEqual(restoredEntry.text, "A saved Voqora clip")
        XCTAssertEqual(restoredEntry.voice, "af_bella")
        XCTAssertTrue(restoredEntry.isFavorite)
        XCTAssertNil(reader.persistenceError)
    }

    func test_historyReportsWriteFailureInsteadOfPretendingItSaved() {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoqoraHistoryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let history = HistoryManager(storageURL: directoryURL)
        history.log(text: "This cannot be written over a directory", voice: "af_bella")

        XCTAssertNotNil(history.persistenceError)
    }

    func test_eraseAllRemovesPersistedHistoryAndIsIdempotent() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoqoraHistoryTests-\(UUID().uuidString)", isDirectory: true)
        let storageURL = folder.appendingPathComponent("history.json")
        defer { try? FileManager.default.removeItem(at: folder) }

        let history = HistoryManager(storageURL: storageURL)
        history.log(text: "A private clip", voice: "af_bella")
        XCTAssertTrue(FileManager.default.fileExists(atPath: storageURL.path))

        try history.eraseAll()
        XCTAssertTrue(history.history.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storageURL.path))

        XCTAssertNoThrow(try history.eraseAll())
    }

    func test_speakingTheSameTextAgainMovesItToTheTopAndKeepsItsStar() {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoqoraHistoryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let history = HistoryManager(storageURL: folder.appendingPathComponent("history.json"))

        history.log(text: "Repeat me", voice: "af_bella")
        history.toggleFavorite(entry: history.history[0])
        history.log(text: "Something else", voice: "af_bella")
        history.log(text: "Repeat me", voice: "af_bella")

        XCTAssertEqual(history.history.map(\.text), ["Repeat me", "Something else"])
        XCTAssertTrue(history.history[0].isFavorite)
    }

    func test_trimKeepsFavoritesAndTheMostRecentEntries() {
        var old = HistoryEntry(text: "starred", voice: "af_bella")
        old.isFavorite = true
        let entries = [HistoryEntry(text: "a", voice: "v"), HistoryEntry(text: "b", voice: "v"), old, HistoryEntry(text: "c", voice: "v")]
        XCTAssertEqual(HistoryManager.trimmed(entries, keepingRecent: 2).map(\.text), ["a", "b", "starred"])
    }

    func test_unknownFieldsAndOneBadEntryDoNotLoseTheRestOfHistory() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoqoraHistoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("history.json")
        try Data(#"[{"text":"kept","voice":"af_bella","future":1},{"voice":"no text"}]"#.utf8).write(to: url)

        let history = HistoryManager(storageURL: url)

        XCTAssertEqual(history.history.map(\.text), ["kept"])
        XCTAssertNil(history.persistenceError)
    }

    func test_unreadableHistoryIsSetAsideNotOverwritten() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoqoraHistoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("history.json")
        try Data("not json".utf8).write(to: url)

        let history = HistoryManager(storageURL: url)
        history.log(text: "new", voice: "af_bella")

        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertTrue(names.contains { $0.hasPrefix("history.unreadable-") })
    }
}
