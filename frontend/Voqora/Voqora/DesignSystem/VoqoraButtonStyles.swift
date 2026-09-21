//
//  VoqoraButtonStyles.swift
//  Voqora
//
//  Real `ButtonStyle`s for the app's chrome to reach for, instead of each
//  button independently combining `.buttonStyle(.plain)` with a hand-picked
//  `.background`/`.foregroundStyle`. Mirrors GRiT's `GRiTButtonStyles.swift`.
//

import SwiftUI

struct VoqoraPrimaryButtonStyle: ButtonStyle {
    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(vm.font(.button))
            .padding(.horizontal, DesignTokens.Spacing.md)
            .padding(.vertical, DesignTokens.Spacing.xs + 2)
            .background(
                vm.accentColor(scheme: colorScheme, contrast: colorSchemeContrast).opacity(configuration.isPressed ? 0.8 : 1),
                in: RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
            )
            // NOT `.white` — the dark ramp puts `base` at a light OKLCH
            // lightness where a white label drops well under 4.5:1.
            // `onAccentColor` is chosen from the fill itself.
            .foregroundStyle(vm.onAccentColor(scheme: colorScheme, contrast: colorSchemeContrast))
    }
}

struct VoqoraSecondaryButtonStyle: ButtonStyle {
    @EnvironmentObject var vm: DashboardViewModel

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(vm.font(.button))
            .padding(.horizontal, DesignTokens.Spacing.md)
            .padding(.vertical, DesignTokens.Spacing.xs + 2)
            .background(
                Palette.controlFill.opacity(configuration.isPressed ? 0.7 : 1),
                in: RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
            )
            // The border is what makes this read as a control — the fill
            // alone can't carry 3:1 against the surface and keep the label
            // legible on top of it.
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                    .strokeBorder(Palette.controlBorder, lineWidth: 1)
            )
            .foregroundStyle(Palette.textPrimary)
    }
}

struct VoqoraDestructiveButtonStyle: ButtonStyle {
    @EnvironmentObject var vm: DashboardViewModel

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(vm.font(.button))
            .padding(.horizontal, DesignTokens.Spacing.md)
            .padding(.vertical, DesignTokens.Spacing.xs + 2)
            .background(
                Palette.danger.opacity(configuration.isPressed ? 0.8 : 1),
                in: RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
            )
            .foregroundStyle(Palette.onDanger)
    }
}

/// For icon-only affordances — dims on press, no background.
struct VoqoraIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.5 : 1)
            .foregroundStyle(.secondary)
    }
}

extension ButtonStyle where Self == VoqoraPrimaryButtonStyle {
    static var voqoraPrimary: VoqoraPrimaryButtonStyle {
        VoqoraPrimaryButtonStyle()
    }
}

extension ButtonStyle where Self == VoqoraSecondaryButtonStyle {
    static var voqoraSecondary: VoqoraSecondaryButtonStyle {
        VoqoraSecondaryButtonStyle()
    }
}

extension ButtonStyle where Self == VoqoraDestructiveButtonStyle {
    static var voqoraDestructive: VoqoraDestructiveButtonStyle {
        VoqoraDestructiveButtonStyle()
    }
}

extension ButtonStyle where Self == VoqoraIconButtonStyle {
    static var voqoraIcon: VoqoraIconButtonStyle {
        VoqoraIconButtonStyle()
    }
}
