@testable import Voqora
import XCTest

final class AudiobookCreateStagingTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("CreateStaging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    func test_fileName_stripsSeparatorsAndControlCharacters() {
        XCTAssertEqual(AudiobookCreateStaging.fileName(forTitle: "a/b\\c:d\n e", fallback: "x"), "a b c d e")
        XCTAssertEqual(AudiobookCreateStaging.fileName(forTitle: "  ..hidden  ", fallback: "x"), "hidden")
    }

    func test_fileName_usesFallbackForBlankTitles() {
        XCTAssertEqual(AudiobookCreateStaging.fileName(forTitle: nil, fallback: "Pasted Text"), "Pasted Text")
        XCTAssertEqual(AudiobookCreateStaging.fileName(forTitle: " / ", fallback: "Pasted Text"), "Pasted Text")
    }

    func test_fileName_limitsLength() {
        let name = AudiobookCreateStaging.fileName(forTitle: String(repeating: "a", count: 200), fallback: "x")

        XCTAssertEqual(name.count, AudiobookCreateStaging.maximumFileNameLength)
    }

    func test_stageText_writesATitledTextFileInAnImportDirectory() throws {
        let url = try AudiobookCreateStaging.stageText("Hello world", title: "My Notes", in: root)

        XCTAssertEqual(url.lastPathComponent, "My Notes.txt")
        XCTAssertTrue(url.deletingLastPathComponent().lastPathComponent.hasPrefix(AudiobookImportStaging.directoryPrefix))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "Hello world")
        XCTAssertTrue(AudiobookImportStaging.supports(url))
    }

    func test_stageText_defaultsTheTitle() throws {
        let url = try AudiobookCreateStaging.stageText("Hello", title: nil, in: root)

        XCTAssertEqual(url.lastPathComponent, "Pasted Text.txt")
    }

    func test_stageCopy_keepsContentAndExtensionUnderTheNewTitle() throws {
        let original = try AudiobookCreateStaging.stageText("Body", title: "Old", in: root)

        let renamed = try AudiobookCreateStaging.stageCopy(of: original, titled: "New Title", in: root)

        XCTAssertEqual(renamed.lastPathComponent, "New Title.txt")
        XCTAssertNotEqual(renamed.deletingLastPathComponent(), original.deletingLastPathComponent())
        XCTAssertEqual(try String(contentsOf: renamed, encoding: .utf8), "Body")
    }

    func test_stagedDirectoriesAreDiscardable() throws {
        let url = try AudiobookCreateStaging.stageText("Body", title: "Gone", in: root)

        AudiobookImportStaging.discard(url, in: root)

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
