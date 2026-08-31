import SwiftUI

/// Pure width-breakpoint logic for the audiobook player.
///
/// T-22: the player used to be a rigid three-column layout (decorative cover
/// | controls | a sections rail that vanished below 1000pt with no
/// replacement — Sections simply became unreachable). That produced two
/// failure modes depending on width: below 1000pt, an entire feature
/// disappeared; above it, a closed transcript left most of the window as
/// dead space because nothing was ever allowed to grow into it. Redesigned
/// around one idea instead: transcript and sections are now the same
/// always-present, always-space-filling content panel (a tab switch, not a
/// column that can vanish), so there is exactly one real breakpoint left —
/// whether there's room for the decorative cover art — and the content panel
/// is the thing that actually responds to the window getting bigger.
enum AudiobookPlayerLayout {
    /// Below this width, the decorative cover column is hidden in favor of a
    /// compact inline header so the transport and content panel keep a
    /// comfortable width instead of being squeezed beside a 240pt image.
    static let coverColumnBreakpoint: CGFloat = 760

    /// Caps how wide the transport/content column gets on an ultra-wide
    /// window — an unbounded scrubber and reading column stretch edge to
    /// edge and become both ugly and imprecise to interact with.
    static let maxContentWidth: CGFloat = 900

    /// Defensive lower bound for transient SwiftUI layout proposals.
    static let minWidth: CGFloat = 480

    struct ColumnVisibility: Equatable {
        let showCover: Bool
    }

    static func columnVisibility(for width: CGFloat) -> ColumnVisibility {
        let safeWidth = max(0, width)
        return ColumnVisibility(showCover: safeWidth >= coverColumnBreakpoint)
    }
}
