import Foundation

/// Pure width-breakpoint logic for `AudiobookPlayerView`'s adaptive
/// three-column layout (the v1.1 design notes Sprint 6, T6.2 — Finding Set C, Defect B).
///
/// The player's HStack (`coverColumn` 240pt + `centerColumn` flex +
/// `sectionsRail` 260pt) previously demanded 604pt of non-negotiable column
/// width — plus 56pt of padding and its own `.frame(minWidth: 760, ...)` —
/// regardless of the space actually available. That overflowed the
/// NavigationSplitView detail pane, which can legitimately shrink to ~520pt
/// (800pt window minimum − up to 280pt sidebar). These breakpoints hide
/// `sectionsRail` first, then `coverColumn`, so `centerColumn` (transport
/// controls, scrubber, transcript — the functionally-essential content)
/// always keeps enough room to render without compressing its own controls,
/// matching the app's one prior adaptive pattern: the library grid's
/// `GridItem(.adaptive(...))`.
enum AudiobookPlayerLayout {
    /// Below this width, `sectionsRail` (260pt) is hidden. Chosen so that
    /// even in the full three-column layout, `centerColumn` never drops
    /// below ~380pt — comfortably above `transportSection`'s own ~360pt
    /// hard minimum (5 controls + 4×28pt spacing).
    static let sectionsRailBreakpoint: CGFloat = 1000

    /// Below this (narrower) width, `coverColumn` (240pt) is also hidden,
    /// leaving `centerColumn` the full width. Same ~380pt reasoning applied
    /// to the two-column (cover + center) layout.
    static let coverColumnBreakpoint: CGFloat = 700

    /// Absolute safety floor passed to `.frame(minWidth:)`. Always below
    /// `coverColumnBreakpoint`, so the view never renders at a width where
    /// its own floor would straddle a breakpoint, and never proposes a
    /// zero/negative width to its children.
    static let minWidth: CGFloat = 480

    struct ColumnVisibility: Equatable {
        let showCover: Bool
        let showRail: Bool
    }

    /// Which of the two optional columns fit at a given available width.
    /// `width` is clamped to >= 0 defensively — SwiftUI can propose a
    /// transient zero or negative size mid-layout-pass (the v1.1 design notes §8 edge
    /// cases: "a max(0, ...) guard on any computed width is required").
    static func columnVisibility(for width: CGFloat) -> ColumnVisibility {
        let safeWidth = max(0, width)
        return ColumnVisibility(
            showCover: safeWidth >= coverColumnBreakpoint,
            showRail: safeWidth >= sectionsRailBreakpoint
        )
    }
}
