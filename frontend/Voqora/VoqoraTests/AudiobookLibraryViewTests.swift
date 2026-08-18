@testable import Voqora
import XCTest

/// Pure-logic tests for `AudiobookLibraryView`'s "no results" empty-state
/// trigger (jira-audiobook-quality.md T-14). Exercises the `internal` static
/// member added specifically so this logic is testable without a live
/// view/window — see the `AudiobookPlayerLayoutTests`/
/// `AudiobookPlayerViewTests.shouldAutoScroll` precedent this file follows.
final class AudiobookLibraryViewTests: XCTestCase {
    func test_showsNoResultsState_falseWhenSearchIsEmpty() {
        XCTAssertFalse(AudiobookLibraryView.showsNoResultsState(searchText: "", matchCount: 0))
        XCTAssertFalse(AudiobookLibraryView.showsNoResultsState(searchText: "", matchCount: 5))
    }

    func test_showsNoResultsState_falseWhenSearchHasMatches() {
        XCTAssertFalse(AudiobookLibraryView.showsNoResultsState(searchText: "dune", matchCount: 1))
    }

    func test_showsNoResultsState_trueWhenSearchMatchesNothing() {
        XCTAssertTrue(AudiobookLibraryView.showsNoResultsState(searchText: "dune", matchCount: 0))
    }
}
