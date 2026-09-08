import AppKit
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
    /// Kept for the call sites that already reference it
    /// (`PreferencesView`, `CompletionSummaryModal`, `NowPlayingBar`,
    /// `UploadEstimateModal`). New chrome built against GRiT's design
    /// language should reach for `Radius` below instead — the two scales
    /// intentionally differ, and this one is not being migrated in this pass.
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

    /// A geometric-ish spacing ramp, matching GRiT's own — each rung is
    /// visibly distinct from its neighbours, which is what keeps call sites
    /// from picking arbitrary numbers between them.
    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        static let xxxl: CGFloat = 44
    }

    /// Spacing by ROLE, matching GRiT's `Layout` — prefer these over a bare
    /// `Spacing` rung anywhere the value describes a recurring structural
    /// relationship (a pane's own inset, a row's own padding), so every
    /// surface of that kind stays padded the same way app-wide.
    enum Layout {
        /// The inset between a side pane's own edge and its content.
        static let paneInset: CGFloat = Spacing.lg
        /// Vertical gap between two grouped blocks inside a pane.
        static let sectionGap: CGFloat = Spacing.xl
        /// Padding inside a card or grouped block.
        static let cardInset: CGFloat = Spacing.lg
        /// A list row's own padding — one definition for every "row in a
        /// list" surface (the sidebar, search results, ⌘K-style palettes).
        static let rowInsetHorizontal: CGFloat = Spacing.md
        static let rowInsetVertical: CGFloat = Spacing.sm
        /// Gap between a row's icon and its label.
        static let rowIconGap: CGFloat = Spacing.md
        static let barInsetHorizontal: CGFloat = Spacing.lg
        static let barInsetVertical: CGFloat = Spacing.md
        /// Minimum height for a clickable row, so hit targets stay honest
        /// even when a row's text is short.
        static let rowMinHeight: CGFloat = 32
    }

    /// Corner radii for new chrome built against the GRiT design language.
    /// Deliberately a separate scale from `CornerRadius` above — see that
    /// type's doc comment.
    enum Radius {
        /// Tiny fixed-size marks that shouldn't visually read as "rounded
        /// rectangle" at all.
        static let xxs: CGFloat = 3
        /// Small chips/badges.
        static let xs: CGFloat = 6
        static let sm: CGFloat = 10
        static let md: CGFloat = 14
        static let lg: CGFloat = 20
    }

    /// `.none` under Reduce Motion — computed, not a stored constant, so a
    /// call site always reads the system's *current* setting.
    enum Animation {
        static var quick: SwiftUI.Animation? {
            reduceMotionEnabled ? nil : SwiftUI.Animation.easeInOut(duration: 0.15)
        }

        static var standard: SwiftUI.Animation? {
            reduceMotionEnabled ? nil : SwiftUI.Animation.easeInOut(duration: 0.25)
        }

        private static var reduceMotionEnabled: Bool {
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
    }

    /// A semantic font role: a (size, weight) pair resolved through
    /// `DashboardViewModel.font(_:)`, which applies it via the user's chosen
    /// font family (`appFont(size:weight:)`) — see
    /// `DashboardViewModel+DesignSystem.swift`. Named by role rather than by
    /// number, matching GRiT's `DesignTokens.Font`, so "the sidebar's own
    /// title" resolves to one size everywhere instead of picking a number
    /// per screen.
    struct FontRole {
        let size: CGFloat
        let weight: SwiftUI.Font.Weight
    }
}

extension DesignTokens.FontRole {
    static let pageTitle = Self(size: 28, weight: .bold)
    /// A pane's own title — e.g. the sidebar's branding header.
    static let paneTitle = Self(size: 16, weight: .semibold)
    /// The small, quiet, often upper-cased label above a group.
    static let sectionHeader = Self(size: 11, weight: .semibold)
    static let sectionTitle = Self(size: 15, weight: .semibold)
    /// Any button's label.
    static let button = Self(size: 13, weight: .medium)
    static let rowTitle = Self(size: 13, weight: .regular)
    static let rowSubtitle = Self(size: 11, weight: .regular)
    static let caption = Self(size: 10, weight: .regular)
    static let chip = Self(size: 9, weight: .medium)
}
