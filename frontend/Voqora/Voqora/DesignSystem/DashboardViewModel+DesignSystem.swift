//
//  DashboardViewModel+DesignSystem.swift
//  Voqora
//
//  Bridges the design-token system to `DashboardViewModel`, the app's
//  existing settings hub (`appTheme`, `selectedFontName`, etc. all live
//  there already).
//
//  `appFont(size:weight:)` is an INSTANCE method — it switches on
//  `selectedFontName`, an `@AppStorage` instance property — so unlike GRiT's
//  fully static `DesignTokens.Font`, Voqora's semantic font roles have to be
//  resolved through a `DashboardViewModel` instance too. `font(_:)` below is
//  that resolution: it keeps Voqora's font-family picker feature (System
//  Rounded/Standard/Mono/Serif/Poppins, or any Font Panel pick) working
//  exactly as before, while giving call sites the same semantic role names
//  GRiT uses instead of a raw point size chosen by eye.
//
//  Accent color resolution needs `ColorScheme`/`colorSchemeContrast`, which
//  only a View has — so, like GRiT's `AppSettings.accentColor(scheme:
//  contrast:)`, these take them as parameters from a caller that already has
//  `@Environment(\.colorScheme)` in scope.
//

import SwiftUI

extension DashboardViewModel {
    /// A semantic font role, resolved through the user's chosen font family.
    /// Add roles here as more of the app migrates onto them — this list
    /// currently covers the sidebar/chrome pass.
    func font(_ role: DesignTokens.FontRole) -> Font {
        appFont(size: role.size, weight: role.weight)
    }

    func accentColor(scheme: ColorScheme, contrast: ColorSchemeContrast) -> Color {
        Palette.accentColors(for: accentColorID, appearance: scheme, increaseContrast: contrast == .increased).accent
    }

    func accentColors(scheme: ColorScheme, contrast: ColorSchemeContrast) -> (accent: Color, accentMuted: Color) {
        Palette.accentColors(for: accentColorID, appearance: scheme, increaseContrast: contrast == .increased)
    }

    func onAccentColor(scheme: ColorScheme, contrast: ColorSchemeContrast) -> Color {
        Palette.onAccentColor(for: accentColorID, appearance: scheme, increaseContrast: contrast == .increased)
    }
}
