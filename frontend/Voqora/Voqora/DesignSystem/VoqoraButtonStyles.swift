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
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                    .strokeBorder(Palette.controlBorder, lineWidth: 1)
            )
            .foregroundStyle(Palette.textPrimary)
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
