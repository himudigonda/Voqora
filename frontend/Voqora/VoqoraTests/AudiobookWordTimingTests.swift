@testable import Voqora
import XCTest

@MainActor
final class AudiobookWordTimingTests: XCTestCase {
    func test_transcriptWordsReachReadingModeSentences() throws {
        let transcript = try decodeTranscript(lines: """
        [{"paragraph":0,"text":"Chapter One","start":0.0,"end":1.0},
         {"paragraph":1,"text":"The fox jumps.","start":1.0,"end":2.5,
          "words":[{"text":"The","start":1.0,"end":1.3},{"text":"fox","start":1.3,"end":1.8},{"text":"jumps.","start":1.8,"end":2.5}]}]
        """)

        let document = TranscriptDocument(transcript: transcript)
        let reading = ReadingDocument(transcript: document)

        XCTAssertEqual(document.lines.map(\.text), ["Chapter One", "The fox jumps."])
        XCTAssertNil(document.wordTimings[0])
        XCTAssertEqual(document.wordTimings[1]?.map(\.text), ["The", "fox", "jumps."])
        XCTAssertNil(reading.sentences[0].words)
        XCTAssertEqual(reading.sentences[1].words?.map(\.start), [1.0, 1.3, 1.8])
        XCTAssertEqual(
            ReadingHighlighter.highlight(in: reading, sentenceIndex: 1, at: 1.5, emphasizesWords: true),
            .word(sentence: 1, word: 1)
        )
    }

    func test_transcriptWithoutWordsStillReadsBySentence() throws {
        let transcript = try decodeTranscript(lines: """
        [{"paragraph":0,"text":"Only sentences here.","start":0.0,"end":2.0}]
        """)

        let reading = ReadingDocument(transcript: TranscriptDocument(transcript: transcript))

        XCTAssertTrue(TranscriptDocument(transcript: transcript).wordTimings.isEmpty)
        XCTAssertNil(reading.sentences[0].words)
        XCTAssertEqual(
            ReadingHighlighter.highlight(in: reading, sentenceIndex: 0, at: 1, emphasizesWords: true),
            .sentence(0)
        )
    }

    func test_emptyWordListsAndBlankLinesKeepIdsAligned() throws {
        let transcript = try decodeTranscript(lines: """
        [{"paragraph":0,"text":"   ","start":0.0,"end":0.5,"words":[{"text":"x","start":0,"end":0.5}]},
         {"paragraph":0,"text":"First.","start":0.5,"end":1.0,"words":[]},
         {"paragraph":0,"text":"Second.","start":1.0,"end":2.0,"words":[{"text":"Second.","start":1.0,"end":2.0}]}]
        """)

        let document = TranscriptDocument(transcript: transcript)

        XCTAssertEqual(document.lines.map(\.id), [0, 1])
        XCTAssertNil(document.wordTimings[0])
        XCTAssertEqual(document.wordTimings[1]?.first?.text, "Second.")
    }

    func test_explicitWordTimingsStillOverrideTheTranscript() {
        let line = TranscriptLine(id: 0, text: "Hi there.", start: 0, end: 1, page: 1, block: 0, isHeading: false, isNarrated: true, isExactlyTimed: true)
        let document = TranscriptDocument(lines: [line], wordTimings: [0: [ReadingWordTiming(text: "Hi", start: 0, end: 0.4)]])
        let override = [0: [ReadingWordTiming(text: "there.", start: 0.4, end: 1)]]

        XCTAssertEqual(ReadingDocument(transcript: document).sentences[0].words?.first?.text, "Hi")
        XCTAssertEqual(ReadingDocument(transcript: document, wordTimings: override).sentences[0].words?.first?.text, "there.")
    }

    func test_bookAuthorDecodesWhenPresentAndIsOptional() throws {
        let withAuthor = try JSONDecoder().decode(Audiobook.self, from: Data(bookJSON(author: #","author":"  Jane   Austen "#).utf8))
        let withoutAuthor = try JSONDecoder().decode(Audiobook.self, from: Data(bookJSON(author: "").utf8))
        let blankAuthor = try JSONDecoder().decode(Audiobook.self, from: Data(bookJSON(author: #","author":"   ""#).utf8))

        XCTAssertEqual(withAuthor.displayAuthor, "Jane Austen")
        XCTAssertNil(withoutAuthor.author)
        XCTAssertNil(withoutAuthor.displayAuthor)
        XCTAssertNil(blankAuthor.displayAuthor)
    }

    func test_estimateAuthorIsOptional() throws {
        let estimate = try JSONDecoder().decode(AudiobookEstimateResponse.self, from: Data(LibraryFixtures.estimate.utf8))
        XCTAssertEqual(estimate.displayAuthor, "Jane Doe")
        XCTAssertNil(AudiobookAuthor.display(nil))
        XCTAssertEqual(AudiobookAuthor.display(String(repeating: "a", count: 500))?.count, AudiobookAuthor.maximumLength)
    }

    func test_librarySearchMatchesTitleOrAuthor() throws {
        let book = try JSONDecoder().decode(Audiobook.self, from: Data(bookJSON(author: #","author":"Jane Austen"#).utf8))

        XCTAssertTrue(AudiobookLibraryView.matches(book, searchText: "austen"))
        XCTAssertTrue(AudiobookLibraryView.matches(book, searchText: "pride"))
        XCTAssertFalse(AudiobookLibraryView.matches(book, searchText: "melville"))
    }

    private func decodeTranscript(lines: String) throws -> AudiobookService.Transcript {
        let json = """
        {"book_id":"b","sections":[],"page_to_time":{"1":0.0},"total_audio_seconds":3.0,
        "pages":{"1":"text"},"page_status":{"1":"done"},"lines":{"1":\(lines)}}
        """
        return try JSONDecoder().decode(AudiobookService.Transcript.self, from: Data(json.utf8))
    }

    private func bookJSON(author: String) -> String {
        """
        {"book_id":"b","title":"Pride and Prejudice.epub","created_at":"2026-01-01T00:00:00Z","page_count":3,
        "status":"done","phase_progress":{"page_done":3,"page_total":3},"sections":[],"page_to_time":{},
        "total_audio_seconds":60,"failed_pages":[],"estimated":null,"actual":null,"engine":"kokoro",
        "voice":"af_bella","speed":1.0,"uses_gemini_cleanup":false,"budget":null,"error":null\(author)}
        """
    }
}
