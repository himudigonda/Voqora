import SwiftUI

extension DashboardViewModel {
    func font(_ role: DesignTokens.FontRole) -> Font {
        appFont(size: role.size, weight: role.weight)
    }

    func accentColor(scheme: ColorScheme, contrast: ColorSchemeContrast) -> Color {
        Palette.accentColors(for: accentColorID, appearance: scheme, increaseContrast: contrast == .increased).accent
    }

    func onAccentColor(scheme: ColorScheme, contrast: ColorSchemeContrast) -> Color {
        Palette.onAccentColor(for: accentColorID, appearance: scheme, increaseContrast: contrast == .increased)
    }
}
