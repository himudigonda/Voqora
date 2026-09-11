//
//  VoqoraPane.swift
//  Voqora
//
//  Shared building blocks for the sidebar's contents, matching GRiT's
//  `GRiTPane.swift`. GRiT's own nav rail is a plain `VStack` of these rows —
//  not a native `List` — because a `List`'s vibrancy/selection material is
//  exactly the "glass" look this design language moves away from. Voqora's
//  sidebar adopts the same shape so the two apps' primary navigation reads as
//  one component.
//

import AppKit
import SwiftUI

/// The quiet label above a group of sidebar rows: small, uppercase, tracked
/// out, so it stays legible without competing with the rows below it.
struct PaneSectionHeader: View {
    @EnvironmentObject var vm: DashboardViewModel
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(vm.font(.sectionHeader))
            .kerning(0.6)
            .foregroundStyle(Palette.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A labelled group inside the sidebar: header, then rows.
struct PaneSection<Content: View>: View {
    let title: String?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            if let title {
                PaneSectionHeader(title: title)
            }
            content
        }
    }
}

/// A selectable row — the shape shared by every "row in a list" surface in
/// the sidebar. Opaque accent-ramp shades for the selection/hover fill,
/// never `accent.opacity(…)`: the sidebar sits on the ivory chrome, and a
/// translucent tint would render differently if the same row style were ever
/// reused over the canvas.
struct PaneRow<Leading: View, Label: View>: View {
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder var leading: Leading
    @ViewBuilder var label: Label

    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @State private var isHovering = false

    private var ramp: AccentRamp {
        Palette.accentRamp(
            for: vm.accentColorID,
            appearance: colorScheme,
            increaseContrast: colorSchemeContrast == .increased
        )
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: DesignTokens.Layout.rowIconGap) {
                leading
                label
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DesignTokens.Layout.rowInsetHorizontal)
            .padding(.vertical, DesignTokens.Layout.rowInsetVertical)
            .frame(minHeight: DesignTokens.Layout.rowMinHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color(ramp.strong) : Palette.textPrimary)
        .background(background, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous))
        .animation(DesignTokens.Animation.quick, value: isSelected)
        .animation(DesignTokens.Animation.quick, value: isHovering)
        .onHover { hovering in
            isHovering = hovering
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }

    private var background: Color {
        if isSelected {
            return Color(ramp.muted)
        }
        if isHovering {
            return Color(ramp.subtle)
        }
        return .clear
    }
}
