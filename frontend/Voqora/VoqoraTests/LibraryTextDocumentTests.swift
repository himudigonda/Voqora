import Foundation
@testable import Voqora
import XCTest

final class LibraryTextDocumentTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("LibraryTextDocumentTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
        try super.tearDownWithError()
    }

    func test_titleUsesFirstNonEmptyLineLimitedToEightWords() {
        let text = "\n   \nOne two three four five six seven eight nine ten\nSecond line"
        XCTAssertEqual(LibraryTextDocument.title(for: text), "One two three four five six seven eight")
    }

    func test_titleRemovesPathCharactersAndTrailingPeriods() {
        XCTAssertEqual(LibraryTextDocument.title(for: "Notes: draft/final?..."), "Notes draft final")
        XCTAssertEqual(LibraryTextDocument.title(for: "...hidden"), "hidden")
    }

    func test_titleIsLimitedInLength() {
        let longWord = String(repeating: "a", count: 120)
        XCTAssertEqual(LibraryTextDocument.title(for: longWord).count, LibraryTextDocument.maxTitleLength)
    }

    func test_titleFallsBackWhenNothingUsable() {
        XCTAssertEqual(LibraryTextDocument.title(for: "  \n /// \n"), LibraryTextDocument.fallbackTitle)
    }

    func test_writeCreatesSupportedTextFileInPrefixedDirectory() throws {
        let url = try LibraryTextDocument.write("Chapter One\nIt was a bright day.", in: root)

        XCTAssertEqual(url.pathExtension, "txt")
        XCTAssertEqual(url.deletingPathExtension().lastPathComponent, "Chapter One")
        XCTAssertTrue(url.deletingLastPathComponent().lastPathComponent.hasPrefix(LibraryTextDocument.directoryPrefix))
        XCTAssertTrue(AudiobookImportStaging.supports(url))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "Chapter One\nIt was a bright day.")
    }

    func test_writeFailureLeavesNoDirectoryBehind() throws {
        let blocker = root.appendingPathComponent("blocker")
        try Data("x".utf8).write(to: blocker)

        XCTAssertThrowsError(try LibraryTextDocument.write("Text", in: blocker))
        let contents = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(contents, ["blocker"])
    }
}
