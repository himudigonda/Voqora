@testable import Voqora
import XCTest

/// `Audiobook.displayStatus` / `ProcessingStatus.sectioning` tests
/// (the v1.1 design notes Sprint 4, T4.1 — fixes D5).
///
/// Backend sets `status="sectioning"` while running real chapter/heading
/// detection (`audiobook_service.py`'s `_phase_section`, held from
/// `phase_started` at `:531` to `phase_finished` at `:634` — a real,
/// non-instant duration for large documents). `displayStatus`'s switch
/// previously had no case for `"sectioning"`, so it fell through to
/// `default: .queued` — the UI regressed to "QUEUED" for the entire
/// detection window despite the book actively processing.
final class AudiobookModelTests: XCTestCase {
    private func makeBook(
        status: String,
        pageDone: Int = 10,
        pageTotal: Int = 10
    ) -> Audiobook {
        Audiobook(
            bookID: "book-1",
            title: "Test Book.pdf",
            createdAt: "2026-01-01T00:00:00Z",
            pageCount: 10,
            status: status,
            phaseProgress: PhaseProgress(pageDone: pageDone, pageTotal: pageTotal),
            sections: [],
            pageToTime: [:],
            totalAudioSeconds: 600,
            failedPages: [],
            estimated: nil,
            actual: nil,
            engine: "kokoro",
            voice: "af_bella",
            speed: 1.0,
            error: nil
        )
    }

    // MARK: - T4.1: "sectioning" renders as a distinct state, not QUEUED

    func test_displayStatus_sectioning_isNotQueued() {
        let book = makeBook(status: "sectioning")
        XCTAssertNotEqual(
            book.displayStatus, .queued,
            "D5 regression: status=\"sectioning\" must not fall through to QUEUED"
        )
        XCTAssertEqual(book.displayStatus, .sectioning)
    }

    func test_displayStatus_sectioning_hasDistinctCaption() {
        let book = makeBook(status: "sectioning")
        XCTAssertEqual(book.displayStatus.caption, "DETECTING CHAPTERS")
        XCTAssertNotEqual(book.displayStatus.caption, ProcessingStatus.queued.caption)
    }

    func test_sectioning_isProcessing() {
        XCTAssertTrue(ProcessingStatus.sectioning.isProcessing)
    }

    func test_sectioning_isNotReady() {
        XCTAssertFalse(ProcessingStatus.sectioning.isReady)
    }

    func test_sectioning_ignoresStalePhaseProgress() {
        // The backend never resets phase_progress when entering "sectioning"
        // (the pipeline order is extract -> clean -> section, so it carries
        // over "cleaning"'s final page_done/page_total untouched) —
        // displayStatus must not misuse those stale numbers as if they
        // meant something for this phase.
        let book = makeBook(status: "sectioning", pageDone: 42, pageTotal: 42)
        XCTAssertEqual(book.displayStatus, .sectioning)
    }

    // MARK: - Existing cases still resolve correctly (regression guard)

    func test_displayStatus_queued_stillQueued() {
        XCTAssertEqual(makeBook(status: "queued").displayStatus, .queued)
    }

    func test_displayStatus_concatenating_stillShowsFullProgress() {
        // Pre-existing, correct behavior (poll path) — unchanged by this fix.
        let book = makeBook(status: "concatenating", pageDone: 3, pageTotal: 10)
        XCTAssertEqual(book.displayStatus, .generating(page: 10, total: 10))
    }

    func test_displayStatus_unknownStatus_fallsBackToQueued() {
        // The `default:` fallback is intentional for genuinely unrecognized
        // status strings — only "sectioning" was wrongly landing there.
        XCTAssertEqual(makeBook(status: "some-future-status").displayStatus, .queued)
    }
}
