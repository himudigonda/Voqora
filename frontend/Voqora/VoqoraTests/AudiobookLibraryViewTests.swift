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

    func test_dismissalIsHonoredWhenThePresentedSheetIsStillCurrent() {
        XCTAssertTrue(LibrarySheet.honorsDismissal(presentedID: LibrarySheet.addFromURL.id, currentID: LibrarySheet.addFromURL.id))
    }

    func test_dismissalIsIgnoredWhenTheCurrentSheetChangedDuringTheHandoff() throws {
        let link = try XCTUnwrap(URL(string: "https://example.com/story"))
        let upload = LibrarySheet.upload(.webPage(link))

        XCTAssertFalse(LibrarySheet.honorsDismissal(presentedID: LibrarySheet.addFromURL.id, currentID: upload.id))
    }

    func test_dismissalIsIgnoredWhenNothingWasPresentedOrNothingIsCurrent() {
        XCTAssertFalse(LibrarySheet.honorsDismissal(presentedID: nil, currentID: LibrarySheet.addFromURL.id))
        XCTAssertFalse(LibrarySheet.honorsDismissal(presentedID: LibrarySheet.addFromURL.id, currentID: nil))
    }

    @MainActor
    func test_presentationForgetsASheetOnlyWhileItIsStillTheTrackedOne() {
        let presentation = LibrarySheetPresentation()

        presentation.didAppear("add-from-url")
        presentation.didAppear("upload-x")
        presentation.didDisappear("add-from-url")
        XCTAssertEqual(presentation.presentedID, "upload-x")

        presentation.didDisappear("upload-x")
        XCTAssertNil(presentation.presentedID)
    }
}
