import SwiftUI

/// Shared spacing/corner-radius/type-scale constants.
///
/// The audit found no systematic scale anywhere: 12 distinct corner radii
/// and 14 distinct raw font-size literals in use across Views/, with
/// several concretely-drifted cases where the same visual "kind" of
/// container or label used a different value in two different screens for
/// no evident reason (e.g. a stat-card corner radius of 12 in one modal and
/// 14 in the next screen of the same upload -> completion flow). This gives
/// new and migrated call sites a single source of truth instead of picking
/// their own number.
///
/// This is deliberately not a forced, app-wide migration — every existing
/// visual value stays exactly as it renders today unless a call site is
/// explicitly switched to use these tokens. A full mechanical sweep of the
/// entire view tree belongs to its own pass with real visual QA (this
/// session has no GUI access to verify rendering), not a blind find/replace.
enum DesignTokens {
    enum CornerRadius {
        /// Small controls: pills, badges, tight inline chips.
        static let small: CGFloat = 8
        /// Stat tiles, list rows, small cards.
        static let medium: CGFloat = 12
        /// Panels, sections, "frosted" containers (sections rail, now-playing bar).
        static let large: CGFloat = 14
        /// Preference sections, prominent cards.
        static let xLarge: CGFloat = 16
        /// Full-screen overlays (drop targets, empty-state frames).
        static let overlay: CGFloat = 24
    }

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
    }

    /// Sizes for `vm.appFont(size:weight:)`. Named by role, not by number,
    /// so "the small uppercase eyebrow/kicker label used under a title"
    /// resolves to one size everywhere instead of 9/10/11/12 depending on
    /// which screen it happened to be written in.
    enum FontSize {
        static let caption: CGFloat = 9
        static let footnote: CGFloat = 10
        static let subheadline: CGFloat = 11
        static let body: CGFloat = 13
        static let bodyEmphasis: CGFloat = 14
        static let headline: CGFloat = 16
        static let title: CGFloat = 20
    }
}
