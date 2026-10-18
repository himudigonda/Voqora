import CoreMedia
@testable import Voqora
import XCTest

final class M4BExportModelTests: XCTestCase {
    private typealias Entry = M4BChapterTimeline.Entry

    func test_timeline_sortsDropsOutOfRangeAndCollapsesNearDuplicates() {
        let timeline = M4BChapterTimeline(
            chapters: [
                M4BChapter(title: "B", startSeconds: 10),
                M4BChapter(title: "A", startSeconds: 0),
                M4BChapter(title: "A again", startSeconds: 0.5),
                M4BChapter(title: "C", startSeconds: 20),
                M4BChapter(title: "Late", startSeconds: 40),
                M4BChapter(title: "Broken", startSeconds: .nan),
            ],
            duration: 30,
            fallbackTitle: "Book"
        )

        XCTAssertEqual(timeline.entries, [
            Entry(title: "A", start: 0, end: 10),
            Entry(title: "B", start: 10, end: 20),
            Entry(title: "C", start: 20, end: 30),
        ])
    }

    func test_timeline_insertsOpeningWhenFirstChapterStartsLate() {
        let timeline = M4BChapterTimeline(
            chapters: [M4BChapter(title: "One", startSeconds: 5), M4BChapter(title: "Two", startSeconds: 15)],
            duration: 20,
            fallbackTitle: "Book"
        )

        XCTAssertEqual(timeline.entries, [
            Entry(title: "Book", start: 0, end: 5),
            Entry(title: "One", start: 5, end: 15),
            Entry(title: "Two", start: 15, end: 20),
        ])
    }

    func test_timeline_snapsNearZeroAndNegativeStartsToZero() {
        let nearZero = M4BChapterTimeline(chapters: [M4BChapter(title: "One", startSeconds: 0.4)], duration: 8, fallbackTitle: "Book")
        let negative = M4BChapterTimeline(chapters: [M4BChapter(title: "One", startSeconds: -3)], duration: 8, fallbackTitle: "Book")

        XCTAssertEqual(nearZero.entries, [Entry(title: "One", start: 0, end: 8)])
        XCTAssertEqual(negative.entries, [Entry(title: "One", start: 0, end: 8)])
    }

    func test_timeline_fallsBackToBookTitleAndCleansChapterTitles() {
        let empty = M4BChapterTimeline(chapters: [], duration: 12, fallbackTitle: "Book")
        let messy = M4BChapterTimeline(
            chapters: [M4BChapter(title: "  Part \n Two ", startSeconds: 0), M4BChapter(title: "   ", startSeconds: 6)],
            duration: 12,
            fallbackTitle: "Book"
        )

        XCTAssertEqual(empty.entries, [Entry(title: "Book", start: 0, end: 12)])
        XCTAssertEqual(messy.entries, [Entry(title: "Part Two", start: 0, end: 6), Entry(title: "Book", start: 6, end: 12)])
    }

    func test_timeline_isEmptyWithoutPlayableDuration() {
        XCTAssertTrue(M4BChapterTimeline(chapters: [M4BChapter(title: "A", startSeconds: 0)], duration: 0, fallbackTitle: "Book").entries.isEmpty)
        XCTAssertTrue(M4BChapterTimeline(chapters: [], duration: .infinity, fallbackTitle: "Book").entries.isEmpty)
    }

    func test_timeline_limitsVeryLongTitles() {
        let long = String(repeating: "a", count: 400)

        let timeline = M4BChapterTimeline(chapters: [M4BChapter(title: long, startSeconds: 0)], duration: 5, fallbackTitle: "Book")

        XCTAssertEqual(timeline.entries.first?.title.count, M4BChapterTimeline.maximumTitleLength)
    }

    func test_chapterTextPayload_isLengthPrefixedUTF8WithEncodingBox() {
        let payload = M4BChapterText.samplePayload(for: "Hé")

        XCTAssertEqual([UInt8](payload), [0, 3, 0x48, 0xC3, 0xA9, 0, 0, 0, 12, 0x65, 0x6E, 0x63, 0x64, 0, 0, 1, 0])
    }

    func test_artworkFormat_detectsJPEGAndPNGOnly() {
        XCTAssertEqual(M4BArtworkFormat(data: Data([0xFF, 0xD8, 0xFF, 0xE0])), .jpeg)
        XCTAssertEqual(M4BArtworkFormat(data: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00])), .png)
        XCTAssertNil(M4BArtworkFormat(data: Data("GIF89a".utf8)))
        XCTAssertNil(M4BArtworkFormat(data: Data()))
        XCTAssertEqual(M4BArtworkFormat.jpeg.metadataDataType, kCMMetadataBaseDataType_JPEG as String)
        XCTAssertEqual(M4BArtworkFormat.png.metadataDataType, kCMMetadataBaseDataType_PNG as String)
    }

    func test_request_trimsTextAndDefaultsAlbumToTitle() {
        let output = URL(fileURLWithPath: "/tmp/book.m4b")

        let request = M4BExportRequest(sources: [], chapters: [], title: "  My Book ", author: " Bella ", album: "  ", outputURL: output)

        XCTAssertEqual(request.title, "My Book")
        XCTAssertEqual(request.author, "Bella")
        XCTAssertEqual(request.album, "My Book")
        XCTAssertEqual(request.bitrate, M4BExportRequest.defaultBitrate)
    }

    func test_request_acceptsOnlySupportedBitrates() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("VoqoraBitrate-\(UUID().uuidString).wav")
        try Data([0]).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("out.m4b")

        for bitrate in [48000, 64000, 128_000] {
            let request = M4BExportRequest(sources: [source], chapters: [], title: "Book", author: "", bitrate: bitrate, outputURL: output)
            XCTAssertNoThrow(try request.validate())
        }
        for bitrate in [47999, 128_001] {
            let request = M4BExportRequest(sources: [source], chapters: [], title: "Book", author: "", bitrate: bitrate, outputURL: output)
            XCTAssertThrowsError(try request.validate()) { error in
                XCTAssertEqual(error as? M4BExportError, .unsupportedBitrate)
            }
        }
    }

    func test_exportErrors_haveUserFacingMessagesAndDistinctCodes() {
        let errors: [M4BExportError] = [
            .noSourceAudio, .missingSourceFile, .missingTitle, .unsupportedBitrate,
            .unreadableAudio, .chaptersUnsupported, .encodingFailed, .couldNotSave,
        ]

        XCTAssertTrue(errors.allSatisfy { ($0.errorDescription ?? "").hasSuffix(".") })
        XCTAssertEqual(Set(errors.map(\.failureCode)).count, errors.count)
    }
}
