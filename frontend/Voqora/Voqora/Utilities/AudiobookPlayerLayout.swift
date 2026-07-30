import SwiftUI

/// Pure width-breakpoint logic for the audiobook player. The reading controls
/// remain usable when the app is at its documented minimum window width: the
/// optional section rail disappears first, then the decorative cover column.
enum AudiobookPlayerLayout {
    /// Keep the transport controls at a comfortable width in the three-column
    /// layout by hiding the sections rail below this threshold.
    static let sectionsRailBreakpoint: CGFloat = 1000

    /// At narrow detail-pane widths, reserve all available space for the
    /// transport, scrubber, and transcript rather than squeezing them beside a
    /// cover image.
    static let coverColumnBreakpoint: CGFloat = 700

    /// Defensive lower bound for transient SwiftUI layout proposals.
    static let minWidth: CGFloat = 480

    struct ColumnVisibility: Equatable {
        let showCover: Bool
        let showRail: Bool
    }

    static func columnVisibility(for width: CGFloat) -> ColumnVisibility {
        let safeWidth = max(0, width)
        return ColumnVisibility(
            showCover: safeWidth >= coverColumnBreakpoint,
            showRail: safeWidth >= sectionsRailBreakpoint
        )
    }
}
