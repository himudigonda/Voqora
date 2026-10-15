@testable import Voqora
import XCTest

final class AudiobookModelTests: XCTestCase {
    private func makeBook(
        status: String,
        pageDone: Int = 10,
        pageTotal: Int = 10,
        error: String? = nil
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
            usesLLMCleanup: nil,
            budget: nil,
            error: error
        )
    }

    func test_displayStatus_sectioning_isNotQueued() {
        let book = makeBook(status: "sectioning", pageDone: 4, pageTotal: 10)
        XCTAssertNotEqual(book.displayStatus, .queued)
        XCTAssertEqual(book.displayStatus, .sectioning(page: 4, total: 10))
    }

    func test_displayStatus_sectioning_hasDistinctCaption() {
        let status = makeBook(status: "sectioning").displayStatus
        XCTAssertEqual(status.caption, "Finding chapters…")
        XCTAssertNotEqual(status.caption, ProcessingStatus.queued.caption)
    }

    func test_sectioning_isProcessingAndNotReady() {
        let status = ProcessingStatus.sectioning(page: 1, total: 2)
        XCTAssertTrue(status.isProcessing)
        XCTAssertFalse(status.isReady)
    }

    func test_displayStatus_queued_stillQueued() {
        XCTAssertEqual(makeBook(status: "queued").displayStatus, .queued)
    }

    func test_displayStatus_concatenating_isFinishingRegardlessOfPageCounts() {
        XCTAssertEqual(makeBook(status: "concatenating", pageDone: 3, pageTotal: 10).displayStatus, .finishing)
        XCTAssertEqual(makeBook(status: "concatenating", pageDone: 0, pageTotal: 0).displayStatus, .finishing)
    }

    func test_displayStatus_unknownStatus_fallsBackToQueued() {
        XCTAssertEqual(makeBook(status: "some-future-status").displayStatus, .queued)
    }

    func test_displayStatus_mapsPhasesToTheirPageProgress() {
        XCTAssertEqual(makeBook(status: "extracting", pageDone: 2, pageTotal: 9).displayStatus, .extracting(page: 2, total: 9))
        XCTAssertEqual(makeBook(status: "cleaning", pageDone: 3, pageTotal: 9).displayStatus, .cleaning(page: 3, total: 9))
        XCTAssertEqual(makeBook(status: "tts", pageDone: 5, pageTotal: 9).displayStatus, .generating(page: 5, total: 9))
    }

    func test_displayStatus_terminalStates() {
        XCTAssertEqual(makeBook(status: "done").displayStatus, .ready)
        XCTAssertTrue(makeBook(status: "done").displayStatus.isReady)
        XCTAssertEqual(makeBook(status: "needs_key").displayStatus, .needsKey)
        XCTAssertEqual(makeBook(status: "cancelled").displayStatus, .cancelled)
        XCTAssertEqual(makeBook(status: "failed", error: "boom").displayStatus, .failed(reason: "boom"))
        XCTAssertEqual(makeBook(status: "failed").displayStatus, .failed(reason: "Unknown error"))
    }

    func test_displayStatus_waitingStatesDoNotCountAsProcessing() {
        for status in ["ready", "needs_key", "needs_cost_approval", "failed", "cancelled", "done"] {
            XCTAssertFalse(makeBook(status: status).displayStatus.isProcessing, status)
        }
    }

    func test_progressFraction_isPagesDoneOverTotalAndZeroWithoutTotal() {
        XCTAssertEqual(makeBook(status: "tts", pageDone: 3, pageTotal: 12).progressFraction, 0.25, accuracy: 0.0001)
        XCTAssertEqual(makeBook(status: "tts", pageDone: 3, pageTotal: 0).progressFraction, 0)
    }

    func test_pageCaption_clampsToTotalAndHandlesUnknownTotal() {
        XCTAssertEqual(ProcessingStatus.pageCaption("Narrating", done: 0, total: 10), "Narrating page 1 of 10")
        XCTAssertEqual(ProcessingStatus.pageCaption("Narrating", done: 10, total: 10), "Narrating page 10 of 10")
        XCTAssertEqual(ProcessingStatus.pageCaption("Reading", done: 0, total: 0), "Reading…")
    }

    func test_requiresLLMCleanup_defaultsToTrueWhenBackendOmitsIt() {
        XCTAssertTrue(makeBook(status: "done").requiresLLMCleanup)
    }
}
