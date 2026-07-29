@testable import Voqora
import XCTest

/// Tests for TranscriptParagraphBuilder (the v1.1 design notes Sprint 2, T2.2 + T2.4).
///
/// Covers the three fixture shapes the v1.1 design notes Sprint 2 Verify step calls for:
/// a short single-paragraph page, a long multi-paragraph page, and a page
/// with a dropped (ok:false) segment creating a gap in the segments array —
/// plus T2.4's mixed-availability (some pages with real segments, one
/// without) fallback requirement.
final class TranscriptParagraphBuilderTests: XCTestCase {
    private typealias Segment = AudiobookService.TranscriptSegment

    // MARK: - T2.2: short single-paragraph page

    func test_shortSinglePage_groupsAllSegmentsIntoOneParagraph() {
        let pageText = "The quick brown fox. Jumps over the lazy dog."
        let segments = [
            Segment(text: "The quick brown fox.", startSec: 10.0, endSec: 11.5),
            Segment(text: "Jumps over the lazy dog.", startSec: 11.5, endSec: 13.0),
        ]

        let paragraphs = TranscriptParagraphBuilder.buildSegmentDrivenParagraphs(
            page: 1, pageText: pageText, segments: segments
        )

        XCTAssertEqual(paragraphs.count, 1, "a page with no blank-line break must render as one paragraph")
        XCTAssertEqual(paragraphs[0].segments.map(\.text), segments.map(\.text), "segment order must be preserved")
        XCTAssertEqual(paragraphs[0].segments.map(\.startSec), [10.0, 11.5])
    }

    // MARK: - T2.2: long multi-paragraph page

    func test_longMultiParagraphPage_groupsSegmentsByRealParagraphBreaks() {
        let paragraph1 = "This is the first paragraph. It has two sentences."
        let paragraph2 = "This is the second paragraph. It also has two sentences."
        let paragraph3 = "A short third paragraph."
        let pageText = [paragraph1, paragraph2, paragraph3].joined(separator: "\n\n")

        let segments = [
            Segment(text: "This is the first paragraph.", startSec: 0.0, endSec: 1.5),
            Segment(text: "It has two sentences.", startSec: 1.5, endSec: 2.8),
            Segment(text: "This is the second paragraph.", startSec: 2.8, endSec: 4.2),
            Segment(text: "It also has two sentences.", startSec: 4.2, endSec: 5.9),
            Segment(text: "A short third paragraph.", startSec: 5.9, endSec: 7.0),
        ]

        let paragraphs = TranscriptParagraphBuilder.buildSegmentDrivenParagraphs(
            page: 4, pageText: pageText, segments: segments
        )

        XCTAssertEqual(paragraphs.count, 3, "three blank-line-separated paragraphs must produce three groups")
        XCTAssertEqual(paragraphs[0].segments.map(\.text), Array(segments[0 ... 1].map(\.text)))
        XCTAssertEqual(paragraphs[1].segments.map(\.text), Array(segments[2 ... 3].map(\.text)))
        XCTAssertEqual(paragraphs[2].segments.map(\.text), [segments[4].text])

        // No segment is duplicated or dropped across the whole page.
        let allGrouped = paragraphs.flatMap(\.segments).map(\.text)
        XCTAssertEqual(allGrouped, segments.map(\.text))
    }

    func test_multiParagraphPage_doesNotSplitOnInternalSingleNewline() {
        // A table-like block (real backend output shape) has internal single
        // newlines between rows but is one logical paragraph — must NOT be
        // torn into one fragment per line the way the pre-Sprint-2
        // splitIntoLines did.
        let tableBlock = "The following is a table.\nRow one.\nRow two.\nEnd of table."
        let prose = "Some closing prose."
        let pageText = tableBlock + "\n\n" + prose

        let segments = [
            Segment(text: "The following is a table.", startSec: 0.0, endSec: 1.0),
            Segment(text: "Row one.", startSec: 1.0, endSec: 1.5),
            Segment(text: "Row two.", startSec: 1.5, endSec: 2.0),
            Segment(text: "End of table.", startSec: 2.0, endSec: 2.5),
            Segment(text: "Some closing prose.", startSec: 2.5, endSec: 3.2),
        ]

        let paragraphs = TranscriptParagraphBuilder.buildSegmentDrivenParagraphs(
            page: 5, pageText: pageText, segments: segments
        )

        XCTAssertEqual(paragraphs.count, 2, "the table block's internal single newlines must not create extra paragraph groups")
        XCTAssertEqual(paragraphs[0].segments.count, 4)
        XCTAssertEqual(paragraphs[1].segments.count, 1)
    }

    // MARK: - T2.2: page with a dropped (ok:false) segment — a gap in the array

    func test_pageWithDroppedSegmentGap_groupsRemainingSegmentsWithoutCrashing() {
        // "Sentence two." failed to synthesize — it exists only in
        // dropped_segments, never in `segments`, so the array the builder
        // sees has a real content gap between "one" and "three".
        let pageText = "Sentence one. Sentence two. Sentence three."
        let segmentsWithGap = [
            Segment(text: "Sentence one.", startSec: 0.0, endSec: 1.0),
            Segment(text: "Sentence three.", startSec: 1.0, endSec: 2.0),
        ]

        let paragraphs = TranscriptParagraphBuilder.buildSegmentDrivenParagraphs(
            page: 2, pageText: pageText, segments: segmentsWithGap
        )

        XCTAssertEqual(paragraphs.count, 1)
        XCTAssertEqual(paragraphs[0].segments.count, 2, "both surviving segments must appear despite the gap")
        XCTAssertEqual(paragraphs[0].segments.map(\.text), ["Sentence one.", "Sentence three."])
    }

    func test_pageWithDroppedSegmentGapAcrossParagraphs_stillAssignsCorrectParagraph() {
        let paragraph1 = "First paragraph sentence one. First paragraph sentence two."
        let paragraph2 = "Second paragraph sentence one. Second paragraph sentence two."
        let pageText = paragraph1 + "\n\n" + paragraph2

        // "First paragraph sentence two." dropped.
        let segmentsWithGap = [
            Segment(text: "First paragraph sentence one.", startSec: 0.0, endSec: 1.0),
            Segment(text: "Second paragraph sentence one.", startSec: 1.0, endSec: 2.0),
            Segment(text: "Second paragraph sentence two.", startSec: 2.0, endSec: 3.0),
        ]

        let paragraphs = TranscriptParagraphBuilder.buildSegmentDrivenParagraphs(
            page: 3, pageText: pageText, segments: segmentsWithGap
        )

        XCTAssertEqual(paragraphs.count, 2)
        XCTAssertEqual(paragraphs[0].segments.map(\.text), ["First paragraph sentence one."])
        XCTAssertEqual(paragraphs[1].segments.map(\.text), [
            "Second paragraph sentence one.", "Second paragraph sentence two.",
        ])
    }

    // MARK: - Highlight-timing lookup

    func test_activeSegmentID_returnsLastSegmentAtOrBeforeTime() {
        let paragraphs = TranscriptParagraphBuilder.buildSegmentDrivenParagraphs(
            page: 1,
            pageText: "One. Two. Three.",
            segments: [
                Segment(text: "One.", startSec: 10.0, endSec: 11.0),
                Segment(text: "Two.", startSec: 11.0, endSec: 12.0),
                Segment(text: "Three.", startSec: 12.0, endSec: 13.0),
            ]
        )

        XCTAssertNil(TranscriptParagraphBuilder.activeSegmentID(in: paragraphs, at: 5.0), "before the first segment starts")
        XCTAssertEqual(TranscriptParagraphBuilder.activeSegmentID(in: paragraphs, at: 10.0), "1-0")
        XCTAssertEqual(TranscriptParagraphBuilder.activeSegmentID(in: paragraphs, at: 11.4), "1-1")
        XCTAssertEqual(TranscriptParagraphBuilder.activeSegmentID(in: paragraphs, at: 999.0), "1-2", "after the last segment stays on the last one")
    }

    func test_activeSegmentID_spansMultiplePages() {
        let page1 = TranscriptParagraphBuilder.buildSegmentDrivenParagraphs(
            page: 1, pageText: "Alpha.", segments: [Segment(text: "Alpha.", startSec: 0.0, endSec: 1.0)]
        )
        let page2 = TranscriptParagraphBuilder.buildSegmentDrivenParagraphs(
            page: 2, pageText: "Beta.", segments: [Segment(text: "Beta.", startSec: 1.0, endSec: 2.0)]
        )
        XCTAssertEqual(TranscriptParagraphBuilder.activeSegmentID(in: page1 + page2, at: 1.5), "2-0")
    }

    func test_activeSegmentID_flatOverload_matchesParagraphOverload() {
        // The View caches a flattened segment list per-tick (avoids
        // re-flattening paragraphs 4x/sec); both overloads must agree.
        let paragraphs = TranscriptParagraphBuilder.buildSegmentDrivenParagraphs(
            page: 1,
            pageText: "One. Two.",
            segments: [
                Segment(text: "One.", startSec: 0.0, endSec: 1.0),
                Segment(text: "Two.", startSec: 1.0, endSec: 2.0),
            ]
        )
        let flat = paragraphs.flatMap(\.segments)
        for t in [-1.0, 0.0, 0.5, 1.0, 5.0] {
            XCTAssertEqual(
                TranscriptParagraphBuilder.activeSegmentID(in: paragraphs, at: t),
                TranscriptParagraphBuilder.activeSegmentID(in: flat, at: t)
            )
        }
    }

    // MARK: - Segment matching neither the current nor the next paragraph

    func test_segmentMatchingNoParagraph_doesNotCrashAndLaterSegmentsRecover() {
        // A pathological content mismatch: the middle segment's text appears
        // in NEITHER its "current" nor the next paragraph's remaining text
        // (this is the give-up branch buildSegmentDrivenParagraphs falls
        // back on when a mismatch is worse than one paragraph off). It must
        // still be assigned somewhere (never dropped, never a crash), and
        // the search cursor must keep working correctly for segments after it.
        let paragraph0 = "Alpha content here."
        let paragraph1 = "Beta content here."
        let paragraph2 = "Gamma content here."
        let pageText = [paragraph0, paragraph1, paragraph2].joined(separator: "\n\n")

        let segments = [
            Segment(text: "Alpha content here.", startSec: 0.0, endSec: 1.0),
            Segment(text: "totally unrelated text matching nothing", startSec: 1.0, endSec: 2.0),
            Segment(text: "Gamma content here.", startSec: 2.0, endSec: 3.0),
        ]

        let paragraphs = TranscriptParagraphBuilder.buildSegmentDrivenParagraphs(
            page: 9, pageText: pageText, segments: segments
        )

        // No segment is dropped.
        let allAssigned = paragraphs.flatMap(\.segments).map(\.text)
        XCTAssertEqual(allAssigned, segments.map(\.text))

        // The later, well-matching segment still finds its correct home
        // (paragraph 2 / "Gamma...") despite the mismatch in between.
        let gammaParagraph = paragraphs.first { $0.segments.contains { $0.text == "Gamma content here." } }
        XCTAssertNotNil(gammaParagraph)
        XCTAssertTrue(gammaParagraph?.segments.contains { $0.text.contains("Alpha") } == false)
    }

    // MARK: - T2.4: fallback (no segments data) — char-fraction estimate

    func test_fallbackParagraphs_coversWholePageDurationRange() {
        let pageText = "Fallback paragraph one here.\n\nFallback paragraph two here."
        let paragraphs = TranscriptParagraphBuilder.buildFallbackParagraphs(
            page: 7, pageText: pageText, pageStart: 100.0, pageEnd: 110.0
        )

        XCTAssertEqual(paragraphs.count, 2)
        let allSegs = paragraphs.flatMap(\.segments)
        XCTAssertFalse(allSegs.isEmpty)
        for seg in allSegs {
            XCTAssertGreaterThanOrEqual(seg.startSec, 100.0)
            XCTAssertLessThanOrEqual(seg.endSec, 110.0 + 0.0001)
        }
        // Monotonically increasing — no time goes backwards.
        for i in 1 ..< allSegs.count {
            XCTAssertGreaterThanOrEqual(allSegs[i].startSec, allSegs[i - 1].startSec)
        }
    }

    func test_fallbackParagraphs_emptyPageTextReturnsNoParagraphs() {
        let paragraphs = TranscriptParagraphBuilder.buildFallbackParagraphs(
            page: 1, pageText: "   \n\n  ", pageStart: 0, pageEnd: 5
        )
        XCTAssertTrue(paragraphs.isEmpty)
    }

    // MARK: - T2.4: mixed availability — the exact acceptance scenario

    func test_buildDisplayParagraphs_mixedAvailability_everyPageRendersCorrectly() {
        // 3 pages: "1" and "3" have real segments, "2" has none (no sidecar —
        // absent from the segments dict entirely, not an empty array).
        let transcript = AudiobookService.Transcript(
            bookID: "mixed-book",
            sections: [],
            pageToTime: ["1": 0.0, "2": 10.0, "3": 20.0],
            totalAudioSeconds: 30.0,
            pages: [
                "1": "Page one real segment text.",
                "2": "Page two has no segments sidecar.",
                "3": "Page three real segment text.",
            ],
            segments: [
                "1": [Segment(text: "Page one real segment text.", startSec: 1.0, endSec: 2.0)],
                "3": [Segment(text: "Page three real segment text.", startSec: 21.0, endSec: 22.0)],
                // "2" intentionally absent.
            ],
            droppedSegments: nil
        )

        let paragraphs = TranscriptParagraphBuilder.buildDisplayParagraphs(from: transcript)

        // Every page must be represented — page 2's text must still appear,
        // just via the fallback (estimated-time) path.
        let allText = paragraphs.flatMap(\.segments).map(\.text).joined(separator: " ")
        XCTAssertTrue(allText.contains("Page one"))
        XCTAssertTrue(allText.contains("Page two has no segments sidecar"))
        XCTAssertTrue(allText.contains("Page three"))

        // Page 1 and 3 used real segment timings (exact match, not estimated).
        let page1Segment = paragraphs.flatMap(\.segments).first { $0.id == "1-0" }
        XCTAssertEqual(page1Segment?.startSec, 1.0)
        let page3Segment = paragraphs.flatMap(\.segments).first { $0.id == "3-0" }
        XCTAssertEqual(page3Segment?.startSec, 21.0)

        // Page 2 used the fallback path — its ids carry the "f" marker and
        // its estimated times fall within [10.0, 20.0) (its page range).
        let page2Segments = paragraphs.flatMap(\.segments).filter { $0.id.hasPrefix("2-f") }
        XCTAssertFalse(page2Segments.isEmpty, "page 2 must still produce displayable segments via the fallback path")
        for seg in page2Segments {
            XCTAssertGreaterThanOrEqual(seg.startSec, 10.0)
            XCTAssertLessThanOrEqual(seg.endSec, 20.0 + 0.0001)
        }
    }

    func test_buildDisplayParagraphs_allPagesMissingSegments_allUseFallback() {
        let transcript = AudiobookService.Transcript(
            bookID: "old-book",
            sections: [],
            pageToTime: ["1": 0.0],
            totalAudioSeconds: 5.0,
            pages: ["1": "Only page, pre-Sprint-1 book, no sidecar at all."],
            segments: nil,
            droppedSegments: nil
        )
        let paragraphs = TranscriptParagraphBuilder.buildDisplayParagraphs(from: transcript)
        XCTAssertFalse(paragraphs.isEmpty)
        XCTAssertTrue(paragraphs.flatMap(\.segments).allSatisfy { $0.id.hasPrefix("1-f") })
    }

    // MARK: - splitIntoParagraphs / wrapIntoChunks (shared helpers)

    func test_splitIntoParagraphs_splitsOnlyOnBlankLine() {
        let text = "Line one.\nLine two still same paragraph.\n\nSecond paragraph."
        let paragraphs = TranscriptParagraphBuilder.splitIntoParagraphs(text)
        XCTAssertEqual(paragraphs.count, 2)
        XCTAssertTrue(paragraphs[0].contains("Line one."))
        XCTAssertTrue(paragraphs[0].contains("Line two"))
        XCTAssertEqual(paragraphs[1], "Second paragraph.")
    }

    func test_wrapIntoChunks_shortTextIsOneChunk() {
        let chunks = TranscriptParagraphBuilder.wrapIntoChunks("A short sentence.")
        XCTAssertEqual(chunks, ["A short sentence."])
    }

    func test_wrapIntoChunks_longTextWrapsAtLimit() {
        let longText = Array(repeating: "word", count: 40).joined(separator: " ")
        let chunks = TranscriptParagraphBuilder.wrapIntoChunks(longText, limit: 20)
        XCTAssertGreaterThan(chunks.count, 1)
        for chunk in chunks {
            XCTAssertLessThanOrEqual(chunk.count, 20 + 5, "word-wrap should not wildly exceed the limit")
        }
    }

    func test_wrapIntoChunks_normalizesInternalNewlines() {
        let chunks = TranscriptParagraphBuilder.wrapIntoChunks("Row one.\nRow two.\nRow three.")
        XCTAssertEqual(chunks.count, 1)
        XCTAssertFalse(chunks[0].contains("\n"), "internal newlines must be normalized to spaces for display")
    }
}
