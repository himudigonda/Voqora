@testable import Voqora
import XCTest

final class AudiobookPlayerLayoutTests: XCTestCase {
    func test_wideDetailPaneShowsAllColumns() {
        let visibility = AudiobookPlayerLayout.columnVisibility(for: 1200)
        XCTAssertTrue(visibility.showCover)
        XCTAssertTrue(visibility.showRail)
    }

    func test_mediumDetailPaneHidesOnlySectionsRail() {
        let visibility = AudiobookPlayerLayout.columnVisibility(
            for: AudiobookPlayerLayout.sectionsRailBreakpoint - 1
        )
        XCTAssertTrue(visibility.showCover)
        XCTAssertFalse(visibility.showRail)
    }

    func test_minimumWindowDetailPaneKeepsOnlyReadingControls() {
        // 800pt app minimum minus its 280pt maximum sidebar width.
        let visibility = AudiobookPlayerLayout.columnVisibility(for: 800 - 280)
        XCTAssertFalse(visibility.showCover)
        XCTAssertFalse(visibility.showRail)
    }

    func test_negativeLayoutProposalDoesNotExposeOptionalColumns() {
        let visibility = AudiobookPlayerLayout.columnVisibility(for: -1)
        XCTAssertFalse(visibility.showCover)
        XCTAssertFalse(visibility.showRail)
    }
}
