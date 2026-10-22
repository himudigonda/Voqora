@testable import Voqora
import XCTest

final class LibraryFilterTests: XCTestCase {
    private func makeBook(id: String = "book-1", kind: String? = nil, createdAt: String = "2026-01-01T00:00:00Z", title: String = "Book.pdf", seconds: Double = 600) -> Audiobook {
        Audiobook(
            bookID: id,
            title: title,
            createdAt: createdAt,
            pageCount: 10,
            status: "done",
            phaseProgress: PhaseProgress(pageDone: 10, pageTotal: 10),
            sections: [],
            pageToTime: [:],
            totalAudioSeconds: seconds,
            failedPages: [],
            estimated: nil,
            actual: nil,
            engine: "kokoro",
            voice: "af_bella",
            speed: 1.0,
            usesLLMCleanup: nil,
            budget: nil,
            error: nil,
            kind: kind
        )
    }

    func test_all_includesEveryBook() {
        XCTAssertTrue(LibraryFilter.all.includes(makeBook(), status: .failed(reason: "x"), listenedFraction: 0))
    }

    func test_audiobooksAndPodcasts_splitByKind() {
        let book = makeBook()
        let podcast = makeBook(kind: Audiobook.podcastKind)
        XCTAssertTrue(LibraryFilter.audiobooks.includes(book, status: .ready, listenedFraction: 0))
        XCTAssertFalse(LibraryFilter.audiobooks.includes(podcast, status: .ready, listenedFraction: 0))
        XCTAssertTrue(LibraryFilter.podcasts.includes(podcast, status: .ready, listenedFraction: 0))
        XCTAssertFalse(LibraryFilter.podcasts.includes(book, status: .ready, listenedFraction: 0))
    }

    func test_inProgress_requiresStartedButUnfinishedReadyBook() {
        let book = makeBook()
        XCTAssertFalse(LibraryFilter.inProgress.includes(book, status: .ready, listenedFraction: 0))
        XCTAssertTrue(LibraryFilter.inProgress.includes(book, status: .ready, listenedFraction: 0.4))
        XCTAssertFalse(LibraryFilter.inProgress.includes(book, status: .ready, listenedFraction: 0.99))
        XCTAssertFalse(LibraryFilter.inProgress.includes(book, status: .queued, listenedFraction: 0.4))
    }

    func test_finished_requiresReadyBookNearTheEnd() {
        let book = makeBook()
        XCTAssertTrue(LibraryFilter.finished.includes(book, status: .ready, listenedFraction: 0.99))
        XCTAssertFalse(LibraryFilter.finished.includes(book, status: .ready, listenedFraction: 0.5))
    }

    func test_processing_matchesOnlyProcessingStatuses() {
        let book = makeBook()
        XCTAssertTrue(LibraryFilter.processing.includes(book, status: .generating(page: 1, total: 4), listenedFraction: 0))
        XCTAssertTrue(LibraryFilter.processing.includes(book, status: .queued, listenedFraction: 0))
        XCTAssertFalse(LibraryFilter.processing.includes(book, status: .ready, listenedFraction: 0))
        XCTAssertFalse(LibraryFilter.processing.includes(book, status: .failed(reason: "x"), listenedFraction: 0))
    }

    func test_sortModes_orderBooks() {
        let older = makeBook(id: "a", createdAt: "2026-01-01T00:00:00Z", title: "Zebra.pdf", seconds: 100)
        let newer = makeBook(id: "b", createdAt: "2026-02-01T00:00:00Z", title: "Apple.pdf", seconds: 900)
        XCTAssertEqual(LibrarySortMode.recent.sorted([older, newer]).map(\.bookID), ["b", "a"])
        XCTAssertEqual(LibrarySortMode.alpha.sorted([older, newer]).map(\.bookID), ["b", "a"])
        XCTAssertEqual(LibrarySortMode.duration.sorted([older, newer]).map(\.bookID), ["b", "a"])
    }

    func test_recentlyAdded_capsAtSixNewestFirst() {
        let books = (1 ... 9).map { makeBook(id: "b\($0)", createdAt: "2026-01-0\($0)T00:00:00Z") }
        let recent = HomeRecentlyAdded.recent(books)
        XCTAssertEqual(recent.count, 6)
        XCTAssertEqual(recent.first?.bookID, "b9")
        XCTAssertEqual(recent.last?.bookID, "b4")
    }
}
