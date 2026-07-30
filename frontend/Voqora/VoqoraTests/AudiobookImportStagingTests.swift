@testable import Voqora
import XCTest

final class AudiobookImportStagingTests: XCTestCase {
    func test_stageDocument_preservesFilenameAndUsesUniqueDirectories() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoqoraImportTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let source = root.appendingPathComponent("reading.pdf")
        try Data("%PDF-test".utf8).write(to: source)
        let stagingRoot = root.appendingPathComponent("staging", isDirectory: true)

        let first = try AudiobookImportStaging.stageDocument(from: source, in: stagingRoot)
        let second = try AudiobookImportStaging.stageDocument(from: source, in: stagingRoot)

        XCTAssertEqual(first.lastPathComponent, "reading.pdf")
        XCTAssertEqual(try Data(contentsOf: first), Data("%PDF-test".utf8))
        XCTAssertNotEqual(first.deletingLastPathComponent(), second.deletingLastPathComponent())

        AudiobookImportStaging.discard(first, in: stagingRoot)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func test_stageDocument_rejectsUnsupportedFilesAndDiscardProtectsUnrelatedData() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoqoraImportTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let textFile = root.appendingPathComponent("notes.txt")
        try Data("notes".utf8).write(to: textFile)
        XCTAssertNoThrow(try AudiobookImportStaging.stageDocument(from: textFile, in: root))

        let unsupported = root.appendingPathComponent("notes.rtf")
        try Data("notes".utf8).write(to: unsupported)
        XCTAssertThrowsError(try AudiobookImportStaging.stageDocument(from: unsupported, in: root))

        let unrelated = root.appendingPathComponent("other-temp", isDirectory: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        let unrelatedFile = unrelated.appendingPathComponent("keep.pdf")
        try Data("keep".utf8).write(to: unrelatedFile)
        AudiobookImportStaging.discard(unrelatedFile, in: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedFile.path))
    }

    func test_supportedFormatsAreOneExplicitProductContract() {
        for ext in ["pdf", "txt", "docx", "md"] {
            XCTAssertTrue(AudiobookImportStaging.supports(URL(fileURLWithPath: "/tmp/book.\(ext)")))
        }
        XCTAssertFalse(AudiobookImportStaging.supports(URL(fileURLWithPath: "/tmp/book.epub")))
        XCTAssertTrue(AudiobookImportStaging.supportedFormatsDescription.contains("Markdown"))
    }
}
