import Foundation

/// Pure width-breakpoint metrics for `MainDashboardView`'s decorative
/// circles and fixed paddings (the v1.1 design notes Sprint 6, T6.4).
///
/// Applies the same adaptive-layout principle as `AudiobookPlayerLayout` to
/// the dashboard's fixed 450×450 / 260×260 / 200×200 circles and fixed
/// horizontal paddings (header `.padding(40)`, transport slider
/// `.padding(.horizontal, 100)`). Lower priority than T6.1/T6.2 — there is
/// no proven overflow here at the app's stated 800×600 minimum (the v1.1 design notes
/// §3.5 characterizes this as "systemic, not individually reported broken")
/// — but still in scope: the dashboard should degrade gracefully, without
/// crowding or overlap, at narrow widths.
enum MainDashboardLayout {
    /// Below this width, circles and horizontal paddings shrink to the
    /// compact tier.
    static let compactBreakpoint: CGFloat = 700

    struct Metrics: Equatable {
        let ambientCircleSize: CGFloat
        let outerRingSize: CGFloat
        let innerRingSize: CGFloat
        let headerPadding: CGFloat
        let sliderHorizontalPadding: CGFloat
    }

    private static let regular = Metrics(
        ambientCircleSize: 450,
        outerRingSize: 260,
        innerRingSize: 200,
        headerPadding: 40,
        sliderHorizontalPadding: 100
    )

    private static let compact = Metrics(
        ambientCircleSize: 300,
        outerRingSize: 180,
        innerRingSize: 140,
        headerPadding: 20,
        sliderHorizontalPadding: 30
    )

    /// `width` is clamped to >= 0 defensively (the v1.1 design notes §8 edge cases).
    static func metrics(for width: CGFloat) -> Metrics {
        max(0, width) < compactBreakpoint ? compact : regular
    }
}
