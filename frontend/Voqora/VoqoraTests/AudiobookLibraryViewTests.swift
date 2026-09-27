@testable import Voqora
import XCTest

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
