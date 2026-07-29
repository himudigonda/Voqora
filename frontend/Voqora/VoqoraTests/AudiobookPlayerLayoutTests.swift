@testable import Voqora
import XCTest

/// Pure breakpoint-tier tests for AudiobookPlayerLayout (the v1.1 design notes Sprint 6,
/// T6.2 — Finding Set C, Defect B).
///
/// SwiftUI layout correctness at arbitrary widths isn't meaningfully
/// unit-testable end-to-end — that's covered by manual/visual verification
/// (resizing the running app and screenshotting at minimum/medium/large
/// widths, per the v1.1 design notes Verify step for T6.2). What IS testable is the
/// pure tier-selection logic itself, which is why it was extracted into its
/// own type rather than left inline as GeometryReader-local computation in
/// AudiobookPlayerView's body.
final class AudiobookPlayerLayoutTests: XCTestCase {
    // MARK: - Full (all three columns)

    func test_wideWidth_showsAllColumns() {
        let v = AudiobookPlayerLayout.columnVisibility(for: 1200)
        XCTAssertTrue(v.showCover)
        XCTAssertTrue(v.showRail)
    }

    func test_atSectionsRailBreakpoint_showsAllColumns() {
        let v = AudiobookPlayerLayout.columnVisibility(for: AudiobookPlayerLayout.sectionsRailBreakpoint)
        XCTAssertTrue(v.showCover)
        XCTAssertTrue(v.showRail, "rail should still show exactly at its own breakpoint (>=)")
    }

    // MARK: - Medium (cover + center, rail hidden)

    func test_justBelowSectionsRailBreakpoint_hidesRailOnly() {
        let v = AudiobookPlayerLayout.columnVisibility(for: AudiobookPlayerLayout.sectionsRailBreakpoint - 1)
        XCTAssertTrue(v.showCover)
        XCTAssertFalse(v.showRail)
    }

    func test_atCoverColumnBreakpoint_showsCoverHidesRail() {
        let v = AudiobookPlayerLayout.columnVisibility(for: AudiobookPlayerLayout.coverColumnBreakpoint)
        XCTAssertTrue(v.showCover, "cover should still show exactly at its own breakpoint (>=)")
        XCTAssertFalse(v.showRail)
    }

    // MARK: - Narrow (center only)

    func test_justBelowCoverColumnBreakpoint_hidesBothOptionalColumns() {
        let v = AudiobookPlayerLayout.columnVisibility(for: AudiobookPlayerLayout.coverColumnBreakpoint - 1)
        XCTAssertFalse(v.showCover)
        XCTAssertFalse(v.showRail)
    }

    func test_atAppMinimumWindowWidth_showsCenterColumnOnly() {
        // Worst-case detail-pane width: 800pt window minimum minus the
        // sidebar's own 280pt maximum (the v1.1 design notes §3.5 / VoqoraWindow.swift's
        // .frame(minWidth: 800, ...) and .navigationSplitViewColumnWidth(...,
        // max: 280)). centerColumn must be usable here per T6.2's acceptance.
        let worstCaseDetailPaneWidth: CGFloat = 800 - 280
        let v = AudiobookPlayerLayout.columnVisibility(for: worstCaseDetailPaneWidth)
        XCTAssertFalse(v.showCover)
        XCTAssertFalse(v.showRail)
    }

    // MARK: - Defensive clamping

    /// the v1.1 design notes §8: "a max(0, ...) guard on any computed width is required".
    func test_zeroWidth_hidesBothOptionalColumns() {
        let v = AudiobookPlayerLayout.columnVisibility(for: 0)
        XCTAssertFalse(v.showCover)
        XCTAssertFalse(v.showRail)
    }

    func test_negativeWidth_isClampedAndHidesBothOptionalColumns() {
        let v = AudiobookPlayerLayout.columnVisibility(for: -100)
        XCTAssertFalse(v.showCover)
        XCTAssertFalse(v.showRail)
    }

    // MARK: - Internal consistency

    func test_minWidthFloor_isBelowBothBreakpoints() {
        // The .frame(minWidth:) floor must never let the view render wide
        // enough to straddle a breakpoint ambiguously — it should always
        // land unambiguously in the center-only tier.
        XCTAssertLessThan(AudiobookPlayerLayout.minWidth, AudiobookPlayerLayout.coverColumnBreakpoint)
        XCTAssertLessThan(AudiobookPlayerLayout.minWidth, AudiobookPlayerLayout.sectionsRailBreakpoint)
    }

    func test_coverColumnBreakpoint_isBelowSectionsRailBreakpoint() {
        // sectionsRail must disappear before coverColumn as width shrinks
        // (the v1.1 design notes §5.3: "hide sectionsRail below one threshold and
        // shrink/hide coverColumn below a second, narrower threshold").
        XCTAssertLessThan(AudiobookPlayerLayout.coverColumnBreakpoint, AudiobookPlayerLayout.sectionsRailBreakpoint)
    }
}
