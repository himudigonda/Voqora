import Foundation

/// Pure, testable transcript-display logic extracted from
/// AudiobookPlayerView's former `computeLines`/`splitIntoLines` (the v1.1 design notes
/// Sprint 2, T2.2).
///
/// Display units are built directly from `segments[page]` ARRAY POSITION
/// (the v1.1 design notes §5.1.5's "segment-driven lines" decision) — never by re-aligning
/// character offsets/counts between the backend's Python-computed text and
/// Swift's own string representation. Python's `len()` counts Unicode code
/// points while Swift's `String.count` counts extended grapheme clusters;
/// those differ for combining characters, which would silently misalign
/// highlighting for Hindi (Devanagari, combining vowel signs) content
/// specifically while looking correct in English testing. Segments already
/// carry their own real, backend-measured `startSec`/`endSec` — no counting
/// is needed to place them in time.
///
/// Paragraph boundaries are the one place this still needs the page's own
/// text: segments carry no paragraph marker (the backend's `_split_segments`
/// flattens all newlines to spaces before segmenting), so grouping consecutive
/// segments into their original paragraphs uses the page's stored paragraph
/// breaks (blank-line-separated — Gemini's cleaning prompt explicitly reflows
/// into natural paragraphs) via content search, not counting.
enum TranscriptParagraphBuilder {
    // MARK: - Display model

    /// One displayable, highlightable unit of text within a paragraph. For
    /// segment-driven pages this is a real TTS segment; for fallback pages
    /// (T2.4) it's a word-wrapped chunk carrying an estimated time range.
    struct DisplaySegment: Identifiable, Equatable {
        let id: String
        let text: String
        let startSec: Double
        let endSec: Double
    }

    /// A continuous run of consecutive segments that belong to the same
    /// source paragraph, rendered as one flowing text block.
    struct Paragraph: Identifiable, Equatable {
        let id: String
        let segments: [DisplaySegment]
    }

    // MARK: - Entry point

    /// Builds the full, page-ordered list of display paragraphs for a
    /// transcript. Pages with real `segments` data use the segment-driven
    /// path (real per-sentence timing); pages without it (pre-Sprint-1 books,
    /// or a page that hit the total-TTS-failure branch) fall back to the old
    /// char-fraction-of-page-duration estimate, scoped to that page only
    /// (the v1.1 design notes T2.4) — one missing page never fails the whole transcript.
    static func buildDisplayParagraphs(from transcript: AudiobookService.Transcript) -> [Paragraph] {
        let pages = orderedPages(transcript)
        var result: [Paragraph] = []
        for (idx, page) in pages.enumerated() {
            let (pageNum, pageText) = page
            let pageStart = transcript.pageToTime[String(pageNum)] ?? 0
            let pageEnd: Double = if idx + 1 < pages.count {
                transcript.pageToTime[String(pages[idx + 1].0)] ?? transcript.totalAudioSeconds
            } else {
                transcript.totalAudioSeconds
            }
            let realSegments = transcript.segments?[String(pageNum)] ?? []
            if !realSegments.isEmpty {
                result.append(contentsOf: buildSegmentDrivenParagraphs(
                    page: pageNum, pageText: pageText, segments: realSegments
                ))
            } else {
                result.append(contentsOf: buildFallbackParagraphs(
                    page: pageNum, pageText: pageText,
                    pageStart: pageStart, pageEnd: max(pageEnd, pageStart + 0.001)
                ))
            }
        }
        return result
    }

    /// The currently-active segment across the whole transcript, if any — the
    /// last segment whose `startSec <= time`, matching the pre-existing
    /// player's "most recent line at/before now" semantics.
    static func activeSegmentID(in paragraphs: [Paragraph], at time: Double) -> String? {
        activeSegmentID(in: paragraphs.flatMap(\.segments), at: time)
    }

    /// Same lookup, for callers that already hold a flattened segment list
    /// (e.g. a per-tick UI poll) and want to avoid re-flattening every
    /// paragraph on every call — `AudiobookPlayerView`'s 250ms ticker calls
    /// this directly with a list cached once per transcript refresh.
    static func activeSegmentID(in segments: [DisplaySegment], at time: Double) -> String? {
        segments.last { $0.startSec <= time }?.id
    }

    // MARK: - Segment-driven (real per-segment timing, the v1.1 design notes §5.1.5)

    /// Groups `segments` (already in original page-order — array position) into
    /// paragraphs using `pageText`'s real paragraph breaks. Every segment is
    /// assigned to exactly one paragraph: a segment whose text can't be found
    /// in the current paragraph's remaining text is tried against the next
    /// paragraph once, then falls back to whichever paragraph the search
    /// cursor last reached — a content mismatch (e.g. a segment that
    /// straddled a paragraph break during synthesis) degrades to a
    /// best-effort grouping instead of dropping the segment or crashing.
    static func buildSegmentDrivenParagraphs(
        page: Int, pageText: String, segments: [AudiobookService.TranscriptSegment]
    ) -> [Paragraph] {
        guard !segments.isEmpty else { return [] }

        let positioned = segments.enumerated().map { index, segment in
            DisplaySegment(id: "\(page)-\(index)", text: segment.text, startSec: segment.startSec, endSec: segment.endSec)
        }

        let rawParagraphs = splitIntoParagraphs(pageText)
        guard rawParagraphs.count > 1 else {
            return [Paragraph(id: "\(page)-p0", segments: positioned)]
        }

        var buckets: [[DisplaySegment]] = Array(repeating: [], count: rawParagraphs.count)
        var paragraphIndex = 0
        var searchWindow = normalizeWhitespace(rawParagraphs[0])

        for segment in positioned {
            let needle = normalizeWhitespace(segment.text)
            if !consume(needle, from: &searchWindow), paragraphIndex + 1 < rawParagraphs.count {
                paragraphIndex += 1
                searchWindow = normalizeWhitespace(rawParagraphs[paragraphIndex])
                _ = consume(needle, from: &searchWindow)
            }
            buckets[paragraphIndex].append(segment)
        }

        return buckets.enumerated().compactMap { index, segs in
            segs.isEmpty ? nil : Paragraph(id: "\(page)-p\(index)", segments: segs)
        }
    }

    // MARK: - Fallback (no real segment data — old char-fraction estimate, T2.4)

    /// Re-derives the pre-Sprint-2 char-fraction timing estimate, scoped to a
    /// single page. Word-wrap chunking (no punctuation awareness) is
    /// unchanged from the original `splitIntoLines`; paragraph grouping now
    /// uses the same blank-line convention as the segment-driven path so a
    /// fallback page still renders as flowing paragraphs (T2.3) instead of
    /// reverting to the old one-block-per-line look.
    static func buildFallbackParagraphs(
        page: Int, pageText: String, pageStart: Double, pageEnd: Double
    ) -> [Paragraph] {
        let rawParagraphs = splitIntoParagraphs(pageText)
        guard !rawParagraphs.isEmpty else { return [] }

        let pageDuration = max(pageEnd - pageStart, 0.001)
        let chunksByParagraph = rawParagraphs.map { wrapIntoChunks($0) }
        let totalChars = max(1, chunksByParagraph.reduce(0) { $0 + $1.reduce(0) { $0 + $1.count } })

        var charOffset = 0
        var result: [Paragraph] = []
        for (pIndex, chunks) in chunksByParagraph.enumerated() {
            var segs: [DisplaySegment] = []
            for (cIndex, chunk) in chunks.enumerated() {
                let startFrac = Double(charOffset) / Double(totalChars)
                let endFrac = Double(charOffset + chunk.count) / Double(totalChars)
                segs.append(DisplaySegment(
                    id: "\(page)-f\(pIndex)-\(cIndex)",
                    text: chunk,
                    startSec: pageStart + startFrac * pageDuration,
                    endSec: pageStart + endFrac * pageDuration
                ))
                charOffset += chunk.count
            }
            if !segs.isEmpty {
                result.append(Paragraph(id: "\(page)-fp\(pIndex)", segments: segs))
            }
        }
        return result
    }

    /// Word-wraps normalized text into ~`limit`-char chunks — the same
    /// granularity the pre-Sprint-2 `splitIntoLines` used, kept unchanged for
    /// the fallback path (the v1.1 design notes T2.4 reuses "the existing computeLines
    /// logic" for timing; only paragraph grouping is upgraded, not this).
    static func wrapIntoChunks(_ paragraph: String, limit: Int = 90) -> [String] {
        let text = normalizeWhitespace(paragraph)
        guard !text.isEmpty else { return [] }
        guard text.count > limit else { return [text] }

        var result: [String] = []
        var current = ""
        for word in text.split(separator: " ") {
            let w = String(word)
            if current.isEmpty {
                current = w
            } else if current.count + 1 + w.count <= limit {
                current += " " + w
            } else {
                result.append(current)
                current = w
            }
        }
        if !current.isEmpty {
            result.append(current)
        }
        return result.isEmpty ? [text] : result
    }

    // MARK: - Shared text helpers

    /// Splits page text on its real paragraph breaks — a blank line, matching
    /// Gemini's "reflow into natural paragraphs" cleaning convention
    /// (confirmed against real transcript.json output on disk). Unlike the
    /// pre-Sprint-2 `splitIntoLines`, this does NOT split on every single
    /// newline — a block with internal single newlines (e.g. a cleaned table)
    /// stays one paragraph instead of being torn into one fragment per line.
    static func splitIntoParagraphs(_ text: String) -> [String] {
        text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func orderedPages(_ transcript: AudiobookService.Transcript) -> [(Int, String)] {
        transcript.pages
            .compactMap { key, value -> (Int, String)? in Int(key).map { ($0, value) } }
            .sorted { $0.0 < $1.0 }
    }

    /// Advances `window` past the first occurrence of `needle` (content
    /// search via `String.range(of:)`, never character-index counting) and
    /// returns true; leaves `window` unchanged and returns false if `needle`
    /// isn't found. An empty needle is treated as trivially consumed (not
    /// "not found") so it can never itself burn a paragraph-advance.
    @discardableResult
    private static func consume(_ needle: String, from window: inout String) -> Bool {
        guard !needle.isEmpty else { return true }
        guard let range = window.range(of: needle) else { return false }
        window = String(window[range.upperBound...])
        return true
    }

    /// Collapses any run of whitespace/newlines to a single space, for
    /// robust content matching and clean display text — sidesteps minor
    /// formatting differences (e.g. a swallowed paragraph break inside one
    /// TTS segment) without ever comparing lengths between languages.
    private static func normalizeWhitespace(_ text: String) -> String {
        text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
