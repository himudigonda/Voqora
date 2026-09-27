@testable import Voqora
import XCTest

final class TranscriptDocumentTests: XCTestCase {
    func test_exactLinesAreUsedVerbatimWithAbsoluteTimes() {
        let transcript = makeTranscript(
            pages: ["1": "ignored", "2": "Second page text."],
            pageToTime: ["1": 0, "2": 10],
            total: 14,
            lines: ["1": [
                .init(paragraph: 0, text: "Heading", start: 0, end: 1),
                .init(paragraph: 1, text: "First sentence.", start: 1, end: 6),
                .init(paragraph: 1, text: "Second sentence.", start: 6, end: 10),
            ]]
        )
        let document = TranscriptDocument(transcript: transcript)

        XCTAssertEqual(document.lines.map(\.text), ["Heading", "First sentence.", "Second sentence.", "Second page text."])
        XCTAssertEqual(document.lines.map(\.start), [0, 1, 6, 10])
        XCTAssertTrue(document.lines[0].isHeading)
        XCTAssertEqual(document.lines[1].block, document.lines[2].block)
        XCTAssertNotEqual(document.lines[0].block, document.lines[1].block)
        XCTAssertTrue(document.lines[1].isExactlyTimed)
        XCTAssertFalse(document.lines[3].isExactlyTimed)
        XCTAssertEqual(document.lines[3].end, 14, accuracy: 0.001)
    }

    func test_estimatedLinesSpanThePageWindowInOrder() {
        let transcript = makeTranscript(
            pages: ["1": "One two three. Four five six.\n\nSeven eight nine.", "2": "Next."],
            pageToTime: ["1": 0, "2": 30],
            total: 40
        )
        let document = TranscriptDocument(transcript: transcript)
        let pageOne = document.lines.filter { $0.page == 1 }

        XCTAssertEqual(pageOne.map(\.text), ["One two three.", "Four five six.", "Seven eight nine."])
        XCTAssertEqual(pageOne.first?.start, 0)
        XCTAssertEqual(pageOne.last?.end ?? 0, 30, accuracy: 0.001)
        for (earlier, later) in zip(pageOne, pageOne.dropFirst()) {
            XCTAssertEqual(earlier.end, later.start, accuracy: 0.0001)
        }
        XCTAssertEqual(pageOne[0].block, pageOne[1].block)
        XCTAssertNotEqual(pageOne[1].block, pageOne[2].block)
    }

    func test_silentPagesAreMarkedNotNarratedAndIgnoreTimedLines() {
        let transcript = makeTranscript(
            pages: ["1": "Failed page."],
            pageToTime: ["1": 0],
            total: 5,
            pageStatus: ["1": "tts_failed"],
            lines: ["1": [.init(paragraph: 0, text: "Failed page.", start: 0, end: 5)]]
        )
        let document = TranscriptDocument(transcript: transcript)

        XCTAssertEqual(document.lines.count, 1)
        XCTAssertFalse(document.lines[0].isNarrated)
        XCTAssertFalse(document.lines[0].isExactlyTimed)
    }

    func test_locallyCleanedPagesAreStillNarratedWithExactTimes() {
        let transcript = makeTranscript(
            pages: ["1": "Capped page.", "2": "Cleanup failed page."],
            pageToTime: ["1": 0, "2": 5],
            total: 10,
            pageStatus: ["1": "cost_capped", "2": "cleaning_failed"],
            lines: ["1": [.init(paragraph: 0, text: "Capped page.", start: 0, end: 5)]]
        )
        let document = TranscriptDocument(transcript: transcript)

        XCTAssertEqual(document.lines.map(\.isNarrated), [true, true])
        XCTAssertTrue(document.lines[0].isExactlyTimed)
    }

    @MainActor
    func test_chaptersComeFromTranscriptHeadingsWhenTheBookHasNoRealSections() {
        let transcript = makeTranscript(
            pages: ["1": "Intro text here.", "2": "3.3 Feed-Forward Networks\n\nBody sentence here.", "3": "7 Conclusion\n\nWe are done now."],
            pageToTime: ["1": 0, "2": 10, "3": 20],
            total: 30
        )
        let book = Audiobook.fixture(sections: [AudiobookSection(title: "Paper.pdf", startPage: 1, endPage: 3, startTime: 0)])

        let chapters = AudiobookViewModel.chapters(for: book, document: TranscriptDocument(transcript: transcript))

        XCTAssertEqual(chapters.map(\.title), ["Paper", "3.3 Feed-Forward Networks", "7 Conclusion"])
        XCTAssertEqual(chapters.map(\.startTime), [0, 10, 20])
        XCTAssertEqual(Set(chapters.map(\.id)).count, 3)
        XCTAssertEqual(chapters.section(at: 25)?.title, "7 Conclusion")
    }

    @MainActor
    func test_realBackendSectionsWinOverHeadings() {
        let sections = [
            AudiobookSection(title: "One", startPage: 1, endPage: 1, startTime: 0),
            AudiobookSection(title: "Two", startPage: 2, endPage: 2, startTime: 10),
        ]
        let chapters = AudiobookViewModel.chapters(for: .fixture(sections: sections), document: .empty)
        XCTAssertEqual(chapters.map(\.title), ["One", "Two"])
    }

    func test_chapterTitlesRejectTableRows() {
        XCTAssertTrue(TranscriptText.isChapterTitle("6.3 English Constituency Parsing"))
        XCTAssertFalse(TranscriptText.isChapterTitle("16 32 32 4.91 25.8"))
        XCTAssertFalse(TranscriptText.isChapterTitle("(B)"))
    }

    func test_blankPageMarkersProduceNoLines() {
        let transcript = makeTranscript(
            pages: ["1": "-", "2": "[blank page]", "3": "Real text."],
            pageToTime: ["1": 0, "2": 0.3, "3": 0.6],
            total: 3
        )
        XCTAssertEqual(TranscriptDocument(transcript: transcript).lines.map(\.text), ["Real text."])
    }

    func test_lineIndexFindsTheLastLineStartedAtOrBeforeTheTime() {
        let document = TranscriptDocument(spokenText: "Alpha beta. Gamma delta. Epsilon zeta.", duration: 30)

        XCTAssertEqual(document.lineIndex(at: -1), 0)
        XCTAssertEqual(document.lineIndex(at: 0), 0)
        XCTAssertEqual(document.lineIndex(at: document.lines[1].start), 1)
        XCTAssertEqual(document.lineIndex(at: 29.9), 2)
        XCTAssertEqual(document.lineIndex(at: 999), 2)
        XCTAssertNil(TranscriptDocument.empty.lineIndex(at: 3))
    }

    func test_progressWithinALineIsClamped() {
        let document = TranscriptDocument(spokenText: "Only one sentence here.", duration: 10)

        XCTAssertEqual(document.progress(of: 0, at: 0), 0)
        XCTAssertEqual(document.progress(of: 0, at: 5), 0.5, accuracy: 0.001)
        XCTAssertEqual(document.progress(of: 0, at: 50), 1)
        XCTAssertEqual(document.progress(of: 7, at: 5), 0)
    }

    func test_headingParagraphBecomesOneHeadingLine() {
        let document = TranscriptDocument(spokenText: "Results\n\nThe model wins. It is fast.", duration: 10)

        XCTAssertEqual(document.lines.map(\.text), ["Results", "The model wins.", "It is fast."])
        XCTAssertEqual(document.lines.map(\.isHeading), [true, false, false])
    }

    func test_listItemsStayOnSeparateLines() {
        let document = TranscriptDocument(spokenText: "First, alpha.\nSecond, beta.\nThird, gamma.", duration: 9)

        XCTAssertEqual(document.lines.map(\.text), ["First, alpha.", "Second, beta.", "Third, gamma."])
    }

    func test_splitIntoParagraphsReflowsSoftWrapsAndKeepsBlankLineBreaks() {
        XCTAssertEqual(
            TranscriptText.splitIntoParagraphs("This line wraps\nonto the next.\n\n\nSecond paragraph."),
            ["This line wraps onto the next.", "Second paragraph."]
        )
        XCTAssertEqual(TranscriptText.splitIntoParagraphs(""), [])
    }

    func test_joinLinesKeepsCompletedSentencesOnSeparateLines() {
        XCTAssertEqual(TranscriptText.joinLines(["He said \"stop.\"", "Then he left."]), "He said \"stop.\"\nThen he left.")
        XCTAssertEqual(TranscriptText.joinLines(["one", "two"]), "one two")
    }

    func test_splitIntoSentencesHandlesAbbreviations() {
        XCTAssertEqual(
            TranscriptText.splitIntoSentences("Dr. Smith paid $3.50 for it. He left."),
            ["Dr. Smith paid $3.50 for it.", "He left."]
        )
        XCTAssertEqual(TranscriptText.splitIntoSentences("no terminal punctuation"), ["no terminal punctuation"])
    }

    func test_isHeadingLikeIsConservative() {
        XCTAssertTrue(TranscriptText.isHeadingLike("3.2 Scaled Dot-Product Attention"))
        XCTAssertFalse(TranscriptText.isHeadingLike("This is a sentence."))
        XCTAssertFalse(TranscriptText.isHeadingLike(String(repeating: "word ", count: 20)))
    }

    private func makeTranscript(
        pages: [String: String],
        pageToTime: [String: Double],
        total: Double,
        pageStatus: [String: String]? = nil,
        lines: [String: [TranscriptDocument.TimedLine]]? = nil
    ) -> AudiobookService.Transcript {
        AudiobookService.Transcript(
            bookID: "book",
            sections: [],
            pageToTime: pageToTime,
            totalAudioSeconds: total,
            pages: pages,
            pageStatus: pageStatus,
            lines: lines
        )
    }
}

@MainActor
final class TranscriptFollowerTests: XCTestCase {
    func test_followerTracksTheAudioClockAndScrubPreview() {
        let audio = AudioService(startingEngine: false)
        let follower = TranscriptFollower(audio: audio)
        follower.load(TranscriptDocument(spokenText: "One. Two. Three.", duration: 30))
        let starts = follower.document.lines.map(\.start)

        audio.currentTime = starts[1] + 0.01
        XCTAssertEqual(follower.activeIndex, 1)

        follower.scrub(to: starts[2] + 0.01)
        XCTAssertTrue(follower.isScrubbing)
        XCTAssertEqual(follower.activeIndex, 2)

        audio.currentTime = 0
        XCTAssertEqual(follower.activeIndex, 2, "the audio clock must not fight an in-progress scrub")

        follower.scrub(to: nil)
        XCTAssertFalse(follower.isScrubbing)
        XCTAssertEqual(follower.activeIndex, 0)
    }

    func test_spokenTextIsFollowedRelativeToTheLiveDuration() {
        let audio = AudioService(startingEngine: false)
        let follower = TranscriptFollower(audio: audio)
        audio.duration = 10
        follower.follow(spokenText: "First part here. Second part here.")
        let revision = follower.revision

        audio.currentTime = 9
        XCTAssertEqual(follower.activeIndex, 1)

        audio.duration = 40
        XCTAssertEqual(follower.activeIndex, 0, "a longer real duration moves the same clock earlier in the text")
        XCTAssertEqual(follower.revision, revision, "duration changes must not rebuild the document")
    }

    func test_spokenSentencesStartWhereTheirPauseInTheAudioEnds() {
        let text = "A much longer opening sentence that runs on for a while. This one, however, is short. Final words."
        let pauses = [
            AudioPause(end: 5.35, length: 0.35),
            AudioPause(end: 6.12, length: 0.12),
            AudioPause(end: 7.35, length: 0.35),
        ]

        let document = TranscriptDocument(spokenText: text, duration: 9, pauses: pauses, speed: 1)

        XCTAssertEqual(document.lines.map(\.start), [0, 5.35, 7.35])
        XCTAssertEqual(document.lines.last?.end, 9)
        XCTAssertTrue(document.lines.allSatisfy(\.isExactlyTimed))
    }

    func test_spokenSentencesKeepEstimatesWhenTheAudioHasNoPauses() {
        let text = "First sentence here. Second sentence here."
        let estimated = TranscriptDocument(spokenText: text, duration: 4)
        let aligned = TranscriptDocument(spokenText: text, duration: 4, pauses: [], speed: 1)

        XCTAssertEqual(aligned.lines.map(\.start), estimated.lines.map(\.start))
    }

    func test_pausesAreRunsOfDigitalSilenceLongEnoughToBeInserted() {
        let voiced = { (samples: Int) in Data(repeating: 1, count: samples * 2) }
        let silent = { (samples: Int) in Data(count: samples * 2) }
        let pcm = voiced(2400) + silent(8400) + voiced(240) + silent(100) + voiced(240)

        let pauses = AudioPause.detect(inPCM16: pcm, sampleRate: 24000)

        XCTAssertEqual(pauses.count, 1)
        XCTAssertEqual(pauses[0].end, 0.45, accuracy: 0.0001)
        XCTAssertEqual(pauses[0].length, 0.35, accuracy: 0.0001)
    }
}

extension Audiobook {
    static func fixture(id: String = "book", title: String = "Paper.pdf", sections: [AudiobookSection] = []) -> Audiobook {
        Audiobook(
            bookID: id,
            title: title,
            createdAt: "2026-09-27T00:00:00Z",
            pageCount: 1,
            status: "done",
            phaseProgress: PhaseProgress(pageDone: 1, pageTotal: 1),
            sections: sections,
            pageToTime: [:],
            totalAudioSeconds: 120,
            failedPages: [],
            estimated: nil,
            actual: nil,
            engine: "kokoro",
            voice: "af_bella",
            speed: 1,
            usesGeminiCleanup: false,
            budget: nil,
            error: nil
        )
    }
}
