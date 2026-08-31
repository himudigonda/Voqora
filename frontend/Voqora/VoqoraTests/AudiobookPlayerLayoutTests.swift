@testable import Voqora
import XCTest

final class AudiobookPlayerLayoutTests: XCTestCase {
    func test_wideDetailPaneShowsCover() {
        let visibility = AudiobookPlayerLayout.columnVisibility(for: 1200)
        XCTAssertTrue(visibility.showCover)
    }

    func test_narrowDetailPaneHidesCover() {
        let visibility = AudiobookPlayerLayout.columnVisibility(
            for: AudiobookPlayerLayout.coverColumnBreakpoint - 1
        )
        XCTAssertFalse(visibility.showCover)
    }

    func test_minimumWindowDetailPaneHidesCover() {
        XCTAssertFalse(AudiobookPlayerLayout.columnVisibility(for: AudiobookPlayerLayout.minWidth).showCover)
    }

    func test_negativeLayoutProposalDoesNotExposeCover() {
        XCTAssertFalse(AudiobookPlayerLayout.columnVisibility(for: -1).showCover)
    }
}
