@testable import Voqora
import XCTest

/// the v1.1 design notes Sprint 7, T7.12/E13: the deep-link `.onChange` handler previously
/// cleared `pendingDeepLink` unconditionally, even when the target book
/// wasn't in `books` yet — losing the deep link permanently instead of
/// retrying once the book appeared. These tests drive the extracted, pure
/// `AudiobookDeepLinkResolver.resolve` directly.
final class AudiobookDeepLinkResolverTests: XCTestCase {
    private func makeBook(id: String) -> Audiobook {
        Audiobook(
            bookID: id,
            title: "Test Book.pdf",
            createdAt: "2026-01-01T00:00:00Z",
            pageCount: 10,
            status: "done",
            phaseProgress: PhaseProgress(pageDone: 10, pageTotal: 10),
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

    func test_noPendingDeepLink_doesNothing() {
        let result = AudiobookDeepLinkResolver.resolve(pendingDeepLink: nil, books: [], currentPath: [])
        XCTAssertNil(result.route)
        XCTAssertFalse(result.clear)
    }

    /// The core E13 regression: the target book isn't loaded yet (e.g. the
    /// deep link arrives before the library's first `refresh()` completes).
    /// Must NOT clear pendingDeepLink — the caller re-arms nothing because
    /// nothing was disarmed; the same pendingDeepLink stays live for retry.
    func test_bookNotYetInLibrary_leavesDeepLinkArmed() {
        let result = AudiobookDeepLinkResolver.resolve(
            pendingDeepLink: "book-not-loaded-yet",
            books: [],
            currentPath: []
        )
        XCTAssertNil(result.route, "must not navigate to a book that isn't loaded yet")
        XCTAssertFalse(result.clear, "E13: must not clear pendingDeepLink on a failed lookup — retry on the next books update")
    }

    func test_bookFoundInLibrary_pushesRouteAndClears() {
        let book = makeBook(id: "book-ready")
        let result = AudiobookDeepLinkResolver.resolve(
            pendingDeepLink: "book-ready",
            books: [book],
            currentPath: []
        )
        XCTAssertEqual(result.route, .player("book-ready"))
        XCTAssertTrue(result.clear)
    }

    func test_bookFoundButAlreadyOnPath_clearsWithoutDuplicatePush() {
        let book = makeBook(id: "book-already-open")
        let result = AudiobookDeepLinkResolver.resolve(
            pendingDeepLink: "book-already-open",
            books: [book],
            currentPath: [.player("book-already-open")]
        )
        XCTAssertNil(result.route, "must not push a duplicate route for a book already on the nav stack")
        XCTAssertTrue(result.clear, "the deep link itself is still resolved even though no new push was needed")
    }

    /// Full T7.12 verify-step sequence: set pendingDeepLink before `books` is
    /// populated (fails to resolve, stays armed), then populate `books` (the
    /// same pendingDeepLink now resolves) — mirrors the two
    /// `.onChange(of: bookVM.pendingDeepLink)` / `.onChange(of: bookVM.books)`
    /// call sites both invoking the same `resolve` function in
    /// `AudiobookLibraryView`.
    func test_deepLinkArrivesBeforeBooksLoad_thenResolvesOnceBooksPopulate() {
        let bookID = "book-arriving-late"

        // 1) Deep link fires while the library is still empty.
        let firstAttempt = AudiobookDeepLinkResolver.resolve(pendingDeepLink: bookID, books: [], currentPath: [])
        XCTAssertNil(firstAttempt.route)
        XCTAssertFalse(firstAttempt.clear, "pendingDeepLink must stay armed")

        // 2) `books` now populates (e.g. refresh() completes) — pendingDeepLink
        // is still the same value (never cleared), so this retry succeeds.
        let book = makeBook(id: bookID)
        let secondAttempt = AudiobookDeepLinkResolver.resolve(pendingDeepLink: bookID, books: [book], currentPath: [])
        XCTAssertEqual(secondAttempt.route, .player(bookID), "E13: the deep link must still resolve once its target book appears")
        XCTAssertTrue(secondAttempt.clear)
    }

    func test_bookInLibraryButDoesNotMatchPendingID_leavesArmed() {
        let otherBook = makeBook(id: "some-other-book")
        let result = AudiobookDeepLinkResolver.resolve(
            pendingDeepLink: "the-target-book",
            books: [otherBook],
            currentPath: []
        )
        XCTAssertNil(result.route)
        XCTAssertFalse(result.clear)
    }
}
