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
}
