@testable import Voqora
import XCTest

/// Pure-logic tests for `AudiobookPlayerView`'s memoized transcript/section
/// lookup (jira-audiobook-quality.md T-12) and auto-scroll-pause behavior
/// (T-13). These exercise the `internal` static members added specifically
/// so this logic is testable without a live view/window — see the
/// `AudiobookPlayerLayoutTests`/`AudiobookViewModel.libraryPollInterval`
/// precedent this file follows.
final class AudiobookPlayerViewTests: XCTestCase {
    // MARK: - sortPages / sortPageTimes / sortSections

    func test_sortPages_sortsAscendingByPageNumberAndDropsNonIntegerKeys() {
        let pages = ["3": "third", "1": "first", "2": "second", "not-a-number": "junk"]
        let sorted = AudiobookPlayerView.sortPages(pages)
        XCTAssertEqual(
            sorted,
            [
                AudiobookPlayerView.PageEntry(page: 1, text: "first"),
                AudiobookPlayerView.PageEntry(page: 2, text: "second"),
                AudiobookPlayerView.PageEntry(page: 3, text: "third"),
            ]
        )
    }

    // MARK: - page_status threading (jira-audiobook-quality.md T-1 frontend consumption)

    func test_sortPages_threadsPageStatusOntoMatchingEntries() {
        let pages = ["1": "first", "2": "second", "3": "third"]
        let pageStatus = ["2": "tts_failed"]
        let sorted = AudiobookPlayerView.sortPages(pages, pageStatus: pageStatus)
        XCTAssertEqual(sorted.first { $0.page == 1 }?.status, nil)
        XCTAssertEqual(sorted.first { $0.page == 2 }?.status, "tts_failed")
        XCTAssertEqual(sorted.first { $0.page == 3 }?.status, nil)
    }

    func test_sortPages_withNoPageStatus_leavesEveryEntryUnmarked() {
        let pages = ["1": "first"]
        let sorted = AudiobookPlayerView.sortPages(pages)
        XCTAssertNil(sorted.first?.status)
    }

    func test_pageStatusCaption_coversEveryKnownStatus() {
        XCTAssertEqual(AudiobookPlayerView.pageStatusCaption(for: "tts_failed"), "Audio unavailable for this page")
        XCTAssertEqual(AudiobookPlayerView.pageStatusCaption(for: "cleaning_failed"), "This page could not be cleaned")
        XCTAssertEqual(AudiobookPlayerView.pageStatusCaption(for: "duplicate"), "Duplicate page (not narrated)")
    }

    func test_pageStatusCaption_unknownStatus_fallsBackToGenericMessage() {
        XCTAssertFalse(AudiobookPlayerView.pageStatusCaption(for: "some_future_status").isEmpty)
    }

    func test_sortPageTimes_sortsAscendingByTime() {
        let pageToTime = ["5": 40.0, "1": 0.0, "3": 20.0]
        let sorted = AudiobookPlayerView.sortPageTimes(pageToTime)
        XCTAssertEqual(
            sorted,
            [
                AudiobookPlayerView.PageTimeEntry(page: 1, time: 0.0),
                AudiobookPlayerView.PageTimeEntry(page: 3, time: 20.0),
                AudiobookPlayerView.PageTimeEntry(page: 5, time: 40.0),
            ]
        )
    }

    func test_sortSections_sortsAscendingByStartTime() {
        let sections = [
            makeSection(title: "C", startPage: 21, endPage: 30, startTime: 200),
            makeSection(title: "A", startPage: 1, endPage: 10, startTime: 0),
            makeSection(title: "B", startPage: 11, endPage: 20, startTime: 100),
        ]
        let sorted = AudiobookPlayerView.sortSections(sections)
        XCTAssertEqual(sorted.map(\.title), ["A", "B", "C"])
    }

    // MARK: - currentPageID / currentSection match the old unmemoized
    // (compactMap + sort + `last(where:)`) implementation across a range of
    // `currentTime` values, including exact boundaries.

    func test_currentPageID_matchesReferenceImplementationAcrossTimeRangeIncludingBoundaries() {
        let pageToTime = ["1": 0.0, "2": 10.0, "3": 25.0, "4": 25.0, "5": 60.0]
        let sortedTimes = AudiobookPlayerView.sortPageTimes(pageToTime)

        // -1 (before start), each exact boundary, values strictly between
        // boundaries, and past the last page's start time.
        let sampleTimes: [Double] = [-1, 0, 5, 10, 24.999, 25, 25.001, 59, 60, 1_000]
        for time in sampleTimes {
            let expected = referenceCurrentPageID(pageToTime: pageToTime, at: time)
            let actual = AudiobookPlayerView.currentPageID(in: sortedTimes, at: time)
            XCTAssertEqual(actual, expected, "mismatch at t=\(time)")
        }
    }

    func test_currentPageID_emptyTranscriptReturnsNil() {
        XCTAssertNil(AudiobookPlayerView.currentPageID(in: [], at: 100))
    }

    func test_currentSection_matchesReferenceImplementationAcrossTimeRangeIncludingBoundaries() {
        let sections = [
            makeSection(title: "Intro", startPage: 1, endPage: 5, startTime: 0),
            makeSection(title: "Middle", startPage: 6, endPage: 20, startTime: 120),
            makeSection(title: "End", startPage: 21, endPage: 30, startTime: 300),
        ]
        let sortedSections = AudiobookPlayerView.sortSections(sections)

        let sampleTimes: [Double] = [-1, 0, 60, 119.999, 120, 120.001, 299, 300, 300.001, 10_000]
        for time in sampleTimes {
            let expected = referenceCurrentSection(sections: sections, at: time)
            let actual = AudiobookPlayerView.currentSection(in: sortedSections, at: time)
            XCTAssertEqual(actual, expected, "mismatch at t=\(time)")
        }
    }

    func test_currentSection_noSectionsReturnsNil() {
        XCTAssertNil(AudiobookPlayerView.currentSection(in: [], at: 100))
    }

    // MARK: - T-13: shouldAutoScroll

    func test_shouldAutoScroll_trueWhenNeverManuallyScrolled() {
        XCTAssertTrue(AudiobookPlayerView.shouldAutoScroll(userScrolledAt: nil, now: Date()))
    }

    func test_shouldAutoScroll_falseImmediatelyAfterManualScroll() {
        let now = Date()
        XCTAssertFalse(AudiobookPlayerView.shouldAutoScroll(userScrolledAt: now, now: now))
    }

    func test_shouldAutoScroll_falseWithinPauseWindow() {
        let scrolledAt = Date()
        let stillPaused = scrolledAt.addingTimeInterval(AudiobookPlayerView.userScrollPauseDuration - 0.1)
        XCTAssertFalse(AudiobookPlayerView.shouldAutoScroll(userScrolledAt: scrolledAt, now: stillPaused))
    }

    func test_shouldAutoScroll_trueExactlyAtPauseWindowBoundary() {
        let scrolledAt = Date()
        let boundary = scrolledAt.addingTimeInterval(AudiobookPlayerView.userScrollPauseDuration)
        XCTAssertTrue(AudiobookPlayerView.shouldAutoScroll(userScrolledAt: scrolledAt, now: boundary))
    }

    func test_shouldAutoScroll_trueAfterPauseWindowElapses() {
        let scrolledAt = Date()
        let later = scrolledAt.addingTimeInterval(AudiobookPlayerView.userScrollPauseDuration + 1)
        XCTAssertTrue(AudiobookPlayerView.shouldAutoScroll(userScrolledAt: scrolledAt, now: later))
    }

    // MARK: - Helpers

    /// The pre-T-12 implementation, kept only here as a reference oracle.
    private func referenceCurrentPageID(pageToTime: [String: Double], at now: Double) -> Int? {
        pageToTime
            .compactMap { (key, time) -> (Int, Double)? in Int(key).map { ($0, time) } }
            .sorted { $0.1 < $1.1 }
            .last(where: { $0.1 <= now })?.0
    }

    /// The pre-T-12 implementation of `AudiobookViewModel.currentSection(in:)`,
    /// kept only here as a reference oracle.
    private func referenceCurrentSection(sections: [AudiobookSection], at now: Double) -> AudiobookSection? {
        sections
            .sorted { $0.startTime < $1.startTime }
            .last(where: { $0.startTime <= now })
    }

    private func makeSection(title: String, startPage: Int, endPage: Int, startTime: Double) -> AudiobookSection {
        AudiobookSection(title: title, startPage: startPage, endPage: endPage, startTime: startTime)
    }

    // MARK: - splitIntoParagraphs / reflowedText (T-21: preserve paragraph
    // structure in the transcript instead of collapsing it away)

    func test_splitIntoParagraphs_blankLineSeparatesParagraphs() {
        let paragraphs = AudiobookPlayerView.splitIntoParagraphs("First paragraph.\n\nSecond paragraph.")
        XCTAssertEqual(paragraphs, ["First paragraph.", "Second paragraph."])
    }

    func test_splitIntoParagraphs_singleNewlinesWithinAParagraphAreReflowedWithASpace() {
        let paragraphs = AudiobookPlayerView.splitIntoParagraphs("This line wraps\nonto the next\nwithout a blank line.")
        XCTAssertEqual(paragraphs, ["This line wraps onto the next without a blank line."])
    }

    func test_splitIntoParagraphs_emptyString_returnsNoParagraphs() {
        XCTAssertEqual(AudiobookPlayerView.splitIntoParagraphs(""), [])
    }

    func test_splitIntoParagraphs_noBlankLinesAtAll_fallsBackToOneParagraph() {
        let paragraphs = AudiobookPlayerView.splitIntoParagraphs("Just one flat run of prose with no breaks.")
        XCTAssertEqual(paragraphs, ["Just one flat run of prose with no breaks."])
    }

    func test_splitIntoParagraphs_collapsesMultipleConsecutiveBlankLines() {
        let paragraphs = AudiobookPlayerView.splitIntoParagraphs("One.\n\n\n\nTwo.")
        XCTAssertEqual(paragraphs, ["One.", "Two."])
    }

    func test_reflowedText_joinsParagraphsWithABlankLine() {
        let out = AudiobookPlayerView.reflowedText("Heading\n\nBody text in its own paragraph.")
        XCTAssertEqual(out, "Heading\n\nBody text in its own paragraph.")
    }

    func test_reflowedText_reflowsSoftWrappedLinesWithNoBlankLineIntoOneParagraph() {
        let out = AudiobookPlayerView.reflowedText("This line wraps\nonto the next.")
        XCTAssertEqual(out, "This line wraps onto the next.")
    }

    // MARK: - splitIntoSentences / currentSentenceIndex (sentence-level transcript highlight)

    func test_splitIntoSentences_splitsOnSentenceBoundaries() {
        let sentences = AudiobookPlayerView.splitIntoSentences("This is one. This is two! Is this three?")
        XCTAssertEqual(sentences, ["This is one.", "This is two!", "Is this three?"])
    }

    func test_splitIntoSentences_doesNotSplitOnAbbreviationsOrDecimals() {
        let sentences = AudiobookPlayerView.splitIntoSentences("Dr. Smith paid $3.50 for it. He left.")
        XCTAssertEqual(sentences, ["Dr. Smith paid $3.50 for it.", "He left."])
    }

    func test_splitIntoSentences_emptyString_returnsNoSentences() {
        XCTAssertEqual(AudiobookPlayerView.splitIntoSentences(""), [])
    }

    func test_splitIntoSentences_noTerminalPunctuation_fallsBackToWholeString() {
        XCTAssertEqual(AudiobookPlayerView.splitIntoSentences("just a fragment with no period"), ["just a fragment with no period"])
    }

    func test_currentSentenceIndex_singleSentence_isAlwaysZero() {
        let idx = AudiobookPlayerView.currentSentenceIndex(in: ["only one."], pageStart: 0, pageEnd: 10, at: 7)
        XCTAssertEqual(idx, 0)
    }

    func test_currentSentenceIndex_noPageEnd_fallsBackToFirstSentence() {
        let idx = AudiobookPlayerView.currentSentenceIndex(in: ["one.", "two."], pageStart: 0, pageEnd: nil, at: 5)
        XCTAssertEqual(idx, 0)
    }

    func test_currentSentenceIndex_interpolatesAcrossEquallySizedSentences() {
        // Three equal-length sentences over a 30s window: ~0-10s -> 0, ~10-20s -> 1, ~20-30s -> 2.
        let sentences = ["AAAAAAAAAA.", "BBBBBBBBBB.", "CCCCCCCCCC."]
        XCTAssertEqual(AudiobookPlayerView.currentSentenceIndex(in: sentences, pageStart: 0, pageEnd: 30, at: 0), 0)
        XCTAssertEqual(AudiobookPlayerView.currentSentenceIndex(in: sentences, pageStart: 0, pageEnd: 30, at: 5), 0)
        XCTAssertEqual(AudiobookPlayerView.currentSentenceIndex(in: sentences, pageStart: 0, pageEnd: 30, at: 15), 1)
        XCTAssertEqual(AudiobookPlayerView.currentSentenceIndex(in: sentences, pageStart: 0, pageEnd: 30, at: 25), 2)
        XCTAssertEqual(AudiobookPlayerView.currentSentenceIndex(in: sentences, pageStart: 0, pageEnd: 30, at: 30), 2)
    }

    func test_currentSentenceIndex_weightsByCharacterLength() {
        // A long first sentence should occupy proportionally more of the window than a short second one.
        let sentences = ["A very long sentence that takes up most of the page's reading time.", "Short."]
        let idxEarly = AudiobookPlayerView.currentSentenceIndex(in: sentences, pageStart: 0, pageEnd: 10, at: 1)
        let idxLate = AudiobookPlayerView.currentSentenceIndex(in: sentences, pageStart: 0, pageEnd: 10, at: 9.9)
        XCTAssertEqual(idxEarly, 0)
        XCTAssertEqual(idxLate, 1)
    }

    func test_currentSentenceIndex_beforePageStart_clampsToFirstSentence() {
        let sentences = ["one.", "two."]
        XCTAssertEqual(AudiobookPlayerView.currentSentenceIndex(in: sentences, pageStart: 10, pageEnd: 20, at: 0), 0)
    }

    func test_currentSentenceIndex_afterPageEnd_clampsToLastSentence() {
        let sentences = ["one.", "two."]
        XCTAssertEqual(AudiobookPlayerView.currentSentenceIndex(in: sentences, pageStart: 0, pageEnd: 10, at: 999), 1)
    }

    // MARK: - Sentence-anchored auto-scroll (paragraphIndex)

    /// Auto-scroll used to anchor to whole pages (~400 words, 2-3 minutes of
    /// audio) while the highlight advanced sentence by sentence, so on any
    /// page taller than the viewport the highlighted sentence scrolled out of
    /// view and nothing brought it back until the next page boundary. The
    /// scroll target is now the paragraph containing the current sentence,
    /// which this maps from the flattened sentence index.

    func testParagraphIndexMapsFirstSentenceToFirstParagraph() {
        let paragraphs = [["a.", "b."], ["c."], ["d.", "e.", "f."]]
        XCTAssertEqual(AudiobookPlayerView.paragraphIndex(forSentence: 0, in: paragraphs), 0)
    }

    func testParagraphIndexMapsAcrossParagraphBoundaries() {
        let paragraphs = [["a.", "b."], ["c."], ["d.", "e.", "f."]]
        XCTAssertEqual(AudiobookPlayerView.paragraphIndex(forSentence: 1, in: paragraphs), 0)
        XCTAssertEqual(AudiobookPlayerView.paragraphIndex(forSentence: 2, in: paragraphs), 1)
        XCTAssertEqual(AudiobookPlayerView.paragraphIndex(forSentence: 3, in: paragraphs), 2)
        XCTAssertEqual(AudiobookPlayerView.paragraphIndex(forSentence: 5, in: paragraphs), 2)
    }

    func testParagraphIndexClampsPastTheEnd() {
        // The sentence index is an interpolation, so it can overshoot at the
        // very end of a page; clamping keeps the scroll target valid.
        let paragraphs = [["a."], ["b."]]
        XCTAssertEqual(AudiobookPlayerView.paragraphIndex(forSentence: 99, in: paragraphs), 1)
    }

    func testParagraphIndexHandlesEmptyInput() {
        XCTAssertEqual(AudiobookPlayerView.paragraphIndex(forSentence: 0, in: []), 0)
    }

    func testParagraphIndexSkipsEmptyParagraphs() {
        let paragraphs = [[], ["a.", "b."], []] as [[String]]
        XCTAssertEqual(AudiobookPlayerView.paragraphIndex(forSentence: 0, in: paragraphs), 1)
        XCTAssertEqual(AudiobookPlayerView.paragraphIndex(forSentence: 1, in: paragraphs), 1)
    }

    // MARK: - Transcript structure (joinLines / isHeadingLike)

    func testJoinLinesRejoinsSoftWrappedProse() {
        // A source that hard-wraps prose must not show mid-sentence breaks.
        let out = AudiobookPlayerView.joinLines(
            ["The mechanism underneath both stories, and the one", "worth understanding, is this."]
        )
        XCTAssertEqual(out, "The mechanism underneath both stories, and the one worth understanding, is this.")
    }

    func testJoinLinesKeepsCompletedSentencesOnSeparateLines() {
        // Was: every line joined with a space unconditionally, so a five-item
        // list and every row of a table collapsed into one dense blob.
        let out = AudiobookPlayerView.joinLines(["First, alpha.", "Second, beta.", "Third, gamma."])
        XCTAssertEqual(out, "First, alpha.\nSecond, beta.\nThird, gamma.")
    }

    func testJoinLinesHandlesClosingPunctuation() {
        let out = AudiobookPlayerView.joinLines(["He said \"stop.\"", "Then he left."])
        XCTAssertEqual(out, "He said \"stop.\"\nThen he left.")
    }

    func testJoinLinesOnEmptyAndSingleInput() {
        XCTAssertEqual(AudiobookPlayerView.joinLines([]), "")
        XCTAssertEqual(AudiobookPlayerView.joinLines(["only line"]), "only line")
    }

    func testHeadingLikeMatchesShortUnpunctuatedTitles() {
        XCTAssertTrue(AudiobookPlayerView.isHeadingLike("The one line I have to know cold"))
        XCTAssertTrue(AudiobookPlayerView.isHeadingLike("Pricing"))
        XCTAssertTrue(AudiobookPlayerView.isHeadingLike("SECTION 2 — THE CASE FILE"))
    }

    func testHeadingLikeRejectsOrdinaryProse() {
        // False positives look broken (a real sentence blown up into a title),
        // so the rule is deliberately conservative.
        XCTAssertFalse(AudiobookPlayerView.isHeadingLike("This is a sentence."))
        XCTAssertFalse(AudiobookPlayerView.isHeadingLike("A clause that trails off,"))
        XCTAssertFalse(AudiobookPlayerView.isHeadingLike(""))
        XCTAssertFalse(AudiobookPlayerView.isHeadingLike("First, alpha.\nSecond, beta."))
        XCTAssertFalse(
            AudiobookPlayerView.isHeadingLike(
                "A line with no terminal punctuation that nonetheless runs on far too long to be a title"
            )
        )
    }

    func testSplitIntoParagraphsPreservesListStructure() {
        let paragraphs = AudiobookPlayerView.splitIntoParagraphs(
            "Intro paragraph.\n\nFirst, alpha.\nSecond, beta.\n\nAfter list."
        )
        XCTAssertEqual(paragraphs, ["Intro paragraph.", "First, alpha.\nSecond, beta.", "After list."])
    }
}
