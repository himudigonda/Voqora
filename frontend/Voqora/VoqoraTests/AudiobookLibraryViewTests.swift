@testable import Voqora
import XCTest

@MainActor
final class AudiobookLibraryViewTests: XCTestCase {
    private static var book: Audiobook {
        makeTestAudiobook()
    }

    private static var fix: AudiobookViewModel.ProviderFix {
        AudiobookViewModel.ProviderFix(book: book, provider: nil)
    }

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
        let id = LibrarySheet.fixProvider(Self.fix).id
        XCTAssertTrue(LibrarySheet.honorsDismissal(presentedID: id, currentID: id))
    }

    func test_dismissalIsIgnoredWhenTheCurrentSheetChangedDuringTheHandoff() {
        let fix = LibrarySheet.fixProvider(Self.fix)
        let completion = LibrarySheet.completion(Self.book)

        XCTAssertFalse(LibrarySheet.honorsDismissal(presentedID: fix.id, currentID: completion.id))
    }

    func test_dismissalIsIgnoredWhenNothingWasPresentedOrNothingIsCurrent() {
        let id = LibrarySheet.fixProvider(Self.fix).id
        XCTAssertFalse(LibrarySheet.honorsDismissal(presentedID: nil, currentID: id))
        XCTAssertFalse(LibrarySheet.honorsDismissal(presentedID: id, currentID: nil))
    }

    func test_presentationForgetsASheetOnlyWhileItIsStillTheTrackedOne() {
        let presentation = LibrarySheetPresentation()

        presentation.didAppear("fix-a")
        presentation.didAppear("completion-x")
        presentation.didDisappear("fix-a")
        XCTAssertEqual(presentation.presentedID, "completion-x")

        presentation.didDisappear("completion-x")
        XCTAssertNil(presentation.presentedID)
    }
}
