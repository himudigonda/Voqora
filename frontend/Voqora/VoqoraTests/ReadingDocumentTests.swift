@testable import Voqora
import XCTest

@MainActor
final class ReadingDocumentTests: XCTestCase {
    private let words = [
        ReadingWordTiming(text: "The", start: 1.0, end: 1.2),
        ReadingWordTiming(text: "quick", start: 1.2, end: 1.6),
        ReadingWordTiming(text: "fox", start: 1.6, end: 2.0),
        ReadingWordTiming(text: "jumps.", start: 2.4, end: 3.0),
    ]

    func test_wordIndexIsNilBeforeTheFirstWordAndForNoWords() {
        XCTAssertNil(ReadingHighlighter.wordIndex(in: words, at: 0.5))
        XCTAssertNil(ReadingHighlighter.wordIndex(in: [], at: 1))
    }

    func test_wordIndexFindsTheLatestStartedWord() {
        XCTAssertEqual(ReadingHighlighter.wordIndex(in: words, at: 1.0), 0)
        XCTAssertEqual(ReadingHighlighter.wordIndex(in: words, at: 1.19), 0)
        XCTAssertEqual(ReadingHighlighter.wordIndex(in: words, at: 1.2), 1)
        XCTAssertEqual(ReadingHighlighter.wordIndex(in: words, at: 2.2), 2)
        XCTAssertEqual(ReadingHighlighter.wordIndex(in: words, at: 2.4), 3)
        XCTAssertEqual(ReadingHighlighter.wordIndex(in: words, at: 99), 3)
    }

    func test_wordIndexMatchesALinearScanAcrossManyWords() {
        let many = (0 ..< 500).map { ReadingWordTiming(text: "w\($0)", start: Double($0) * 0.25, end: Double($0) * 0.25 + 0.2) }
        for step in 0 ..< 1000 {
            let time = Double(step) * 0.13
            let expected = many.lastIndex { $0.start <= time }
            XCTAssertEqual(ReadingHighlighter.wordIndex(in: many, at: time), expected)
        }
    }

    func test_highlightFallsBackToTheSentenceWithoutWordTimings() {
        let document = makeDocument(words: [0: words])

        XCTAssertEqual(ReadingHighlighter.highlight(in: document, sentenceIndex: 1, at: 1.5, emphasizesWords: true), .sentence(1))
        XCTAssertEqual(ReadingHighlighter.highlight(in: document, sentenceIndex: 0, at: 1.5, emphasizesWords: false), .sentence(0))
        XCTAssertEqual(ReadingHighlighter.highlight(in: document, sentenceIndex: 0, at: 0.2, emphasizesWords: true), .sentence(0))
    }

    func test_highlightEmphasizesTheSpokenWord() {
        let document = makeDocument(words: [0: words])
        let highlight = ReadingHighlighter.highlight(in: document, sentenceIndex: 0, at: 1.7, emphasizesWords: true)

        XCTAssertEqual(highlight, .word(sentence: 0, word: 2))
        XCTAssertEqual(highlight.wordIndex(inSentence: 0), 2)
        XCTAssertNil(highlight.wordIndex(inSentence: 1))
    }

    func test_highlightIsInactiveWithoutAValidSentence() {
        let document = makeDocument(words: [:])

        XCTAssertEqual(ReadingHighlighter.highlight(in: document, sentenceIndex: nil, at: 1, emphasizesWords: true), .inactive)
        XCTAssertEqual(ReadingHighlighter.highlight(in: document, sentenceIndex: 9, at: 1, emphasizesWords: true), .inactive)
    }

    func test_documentMirrorsTranscriptLinesAndAttachesWordTimings() {
        let document = makeDocument(words: [1: words])

        XCTAssertEqual(document.sentences.map(\.id), [0, 1, 2])
        XCTAssertEqual(document.sentences.map(\.text), ["Chapter One", "The quick fox jumps.", "It lands."])
        XCTAssertTrue(document.sentences[0].isHeading)
        XCTAssertNil(document.sentences[0].words)
        XCTAssertEqual(document.sentences[1].words, words)
        XCTAssertTrue(document.startsBlock(0))
        XCTAssertTrue(document.startsBlock(1))
        XCTAssertFalse(document.startsBlock(2))
        XCTAssertFalse(document.startsBlock(7))
    }

    func test_wordTimingsAreSanitized() {
        let messy = [
            ReadingWordTiming(text: "second", start: 2, end: 1.5),
            ReadingWordTiming(text: "  ", start: 0.5, end: 0.6),
            ReadingWordTiming(text: "first", start: 1, end: 1.4),
            ReadingWordTiming(text: "bad", start: .nan, end: 3),
        ]
        let sanitized = ReadingWordTiming.sanitized(messy)

        XCTAssertEqual(sanitized?.map(\.text), ["first", "second"])
        XCTAssertEqual(sanitized?.last?.end, 2)
        XCTAssertNil(ReadingWordTiming.sanitized([ReadingWordTiming(text: "", start: 0, end: 1)]))
    }

    func test_wordLocatorFindsWordsInOrderIncludingRepeats() {
        let text = "The cat saw the Cat."
        let timings = ["the", "cat", "saw", "the", "cat.", "dog"].map { ReadingWordTiming(text: $0, start: 0, end: 0) }
        let ranges = ReadingWordLocator.ranges(of: timings, in: text)

        XCTAssertEqual(ranges.count, 6)
        XCTAssertEqual(ranges.compactMap { range in range.map { String(text[$0]) } }, ["The", "cat", "saw", "the", "Cat."])
        XCTAssertNil(ranges[5])
    }

    func test_followerReportsTimeInTheTranscriptsOwnUnits() {
        let audio = AudioService(startingEngine: false)
        let follower = TranscriptFollower(audio: audio)
        audio.duration = 10
        audio.currentTime = 4

        follower.follow(spokenText: "First part here. Second part here.")
        XCTAssertEqual(follower.documentTime, 0.4, accuracy: 0.0001)

        follower.load(TranscriptDocument(spokenText: "One. Two.", duration: 30))
        XCTAssertEqual(follower.documentTime, 4, accuracy: 0.0001)

        follower.scrub(to: 6)
        XCTAssertEqual(follower.documentTime, 6, accuracy: 0.0001)
    }

    private func makeDocument(words: [Int: [ReadingWordTiming]]) -> ReadingDocument {
        let lines = [
            makeLine(id: 0, text: "Chapter One", start: 0, end: 1, block: 0, heading: true),
            makeLine(id: 1, text: "The quick fox jumps.", start: 1, end: 3, block: 1, heading: false),
            makeLine(id: 2, text: "It lands.", start: 3, end: 4, block: 1, heading: false),
        ]
        return ReadingDocument(transcript: TranscriptDocument(lines: lines), wordTimings: words)
    }

    private func makeLine(id: Int, text: String, start: TimeInterval, end: TimeInterval, block: Int, heading: Bool) -> TranscriptLine {
        TranscriptLine(id: id, text: text, start: start, end: end, page: 1, block: block, isHeading: heading, isNarrated: true, isExactlyTimed: true)
    }
}
