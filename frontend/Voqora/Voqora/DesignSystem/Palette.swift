import AppKit
import SwiftUI

enum AccentColorOption: String, CaseIterable {
    case clay, sage, slate, plum, ochre, teal

    var displayName: String {
        switch self {
        case .clay: "Clay"
        case .sage: "Sage"
        case .slate: "Slate"
        case .plum: "Plum"
        case .ochre: "Ochre"
        case .teal: "Teal"
        }
    }

    fileprivate var seed: AccentSeed {
        switch self {
        case .clay: AccentSeed(hue: 38.8, chroma: 0.131)
        case .sage: AccentSeed(hue: 137.7, chroma: 0.085)
        case .slate: AccentSeed(hue: 249.6, chroma: 0.105)
        case .plum: AccentSeed(hue: 337.9, chroma: 0.105)
        case .ochre: AccentSeed(hue: 82.9, chroma: 0.115)
        case .teal: AccentSeed(hue: 182.7, chroma: 0.095)
        }
    }
}

private struct AppearanceVariants<Value> {
    let light: Value
    let dark: Value
    let highContrastLight: Value
    let highContrastDark: Value
}

enum Palette {
    private static let surfaceBaseHexVariants = AppearanceVariants(
        light: "#FAF9F5", dark: "#262624", highContrastLight: "#FFFFFF", highContrastDark: "#1A1A18"
    )

    static let surfaceBase: Color = dynamicColor(surfaceBaseHexVariants)

    private static let surfaceRaisedHexVariants = AppearanceVariants(
        light: "#FFFFFF", dark: "#30302E", highContrastLight: "#FFFFFF", highContrastDark: "#262624"
    )

    static let surfaceRaised: Color = dynamicColor(surfaceRaisedHexVariants)

    private static let surfaceSunkenHexVariants = AppearanceVariants(
        light: "#F0EEE6", dark: "#1F1E1D", highContrastLight: "#F2F0E8", highContrastDark: "#0F0F0E"
    )

    static let surfaceSunken: Color = dynamicColor(surfaceSunkenHexVariants)

    private static let separatorHexVariants = AppearanceVariants(
        light: "#C6C4BF", dark: "#494844", highContrastLight: "#ADABA5", highContrastDark: "#555450"
    )

    static let separator: Color = dynamicColor(separatorHexVariants)

    private static let controlFillHexVariants = AppearanceVariants(
        light: "#EDEBE3", dark: "#3A3937", highContrastLight: "#EFEDE5", highContrastDark: "#333230"
    )

    static let controlFill: Color = dynamicColor(controlFillHexVariants)

    private static let controlBorderHexVariants = AppearanceVariants(
        light: "#807E76", dark: "#8C8A84", highContrastLight: "#5E5C56", highContrastDark: "#B0AEA8"
    )

    static let controlBorder: Color = dynamicColor(controlBorderHexVariants)

    private static let textPrimaryHexVariants = AppearanceVariants(
        light: "#181817", dark: "#F5F4EF", highContrastLight: "#000000", highContrastDark: "#FFFFFF"
    )

    static let textPrimary: Color = dynamicColor(textPrimaryHexVariants)

    private static let textSecondaryHexVariants = AppearanceVariants(
        light: "#52514E", dark: "#C0BEBA", highContrastLight: "#3D3C39", highContrastDark: "#CFCDC9"
    )

    static let textSecondary: Color = dynamicColor(textSecondaryHexVariants)

    private static let textTertiaryHexVariants = AppearanceVariants(
        light: "#6C6A65", dark: "#9D9C96", highContrastLight: "#5B5954", highContrastDark: "#A6A49F"
    )

    static let textTertiary: Color = dynamicColor(textTertiaryHexVariants)

    private static let warningHexVariants = AppearanceVariants(
        light: "#944B00", dark: "#FF9134", highContrastLight: "#783C00", highContrastDark: "#FFB988"
    )

    static let warning: Color = dynamicColor(warningHexVariants)

    private static let successHexVariants = AppearanceVariants(
        light: "#00772A", dark: "#3BD25F", highContrastLight: "#006020", highContrastDark: "#5CEC79"
    )

    static let success: Color = dynamicColor(successHexVariants)

    private static let dangerHexVariants = AppearanceVariants(
        light: "#C6483C", dark: "#F08379", highContrastLight: "#A32E24", highContrastDark: "#FF9E96"
    )

    static let danger: Color = dynamicColor(dangerHexVariants)

    private static let lightInkHex = "#FFFFFF"
    private static let darkInkHex = "#181817"

    private static func readableInkVariants(over fills: AppearanceVariants<String>) -> AppearanceVariants<String> {
        func ink(over fillHex: String) -> String {
            let fallback = ColorRGBA(r: 0, g: 0, b: 0, a: 1)
            let fill = ColorRGBA(hex: fillHex) ?? fallback
            let lightInk = ColorRGBA(hex: lightInkHex) ?? fallback
            let darkInk = ColorRGBA(hex: darkInkHex) ?? fallback
            return fill.wcagContrast(against: lightInk) >= fill.wcagContrast(against: darkInk) ? lightInkHex : darkInkHex
        }
        return AppearanceVariants(
            light: ink(over: fills.light),
            dark: ink(over: fills.dark),
            highContrastLight: ink(over: fills.highContrastLight),
            highContrastDark: ink(over: fills.highContrastDark)
        )
    }

    @MainActor
    static func accentRamp(
        for option: AccentColorOption,
        appearance: ColorScheme,
        increaseContrast: Bool
    ) -> AccentRamp {
        ColorRamp.ramp(
            for: option.seed,
            appearance: ColorAppearance(isDark: appearance == .dark, increaseContrast: increaseContrast)
        )
    }

    @MainActor
    static func accentColors(
        for option: AccentColorOption,
        appearance: ColorScheme,
        increaseContrast: Bool
    ) -> (accent: Color, accentMuted: Color) {
        let ramp = accentRamp(for: option, appearance: appearance, increaseContrast: increaseContrast)
        return (Color(ramp.base), Color(ramp.muted))
    }

    @MainActor
    static func onAccentColor(
        for option: AccentColorOption,
        appearance: ColorScheme,
        increaseContrast: Bool
    ) -> Color {
        Color(accentRamp(for: option, appearance: appearance, increaseContrast: increaseContrast).onAccent)
    }

    private static func resolve<Value>(_ variants: AppearanceVariants<Value>, appearance: ColorScheme, increaseContrast: Bool) -> Value {
        switch appearance {
        case .dark: increaseContrast ? variants.highContrastDark : variants.dark
        default: increaseContrast ? variants.highContrastLight : variants.light
        }
    }

    private static func resolve<Value>(_ variants: AppearanceVariants<Value>, for appearance: NSAppearance) -> Value {
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return resolve(
            variants,
            appearance: isDark ? .dark : .light,
            increaseContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        )
    }

    private static func dynamicColor(_ hexVariants: AppearanceVariants<String>) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = resolve(hexVariants, for: appearance)
            let rgba = ColorRGBA(hex: hex) ?? ColorRGBA(r: 0, g: 0, b: 0, a: 1)
            return NSColor(srgbRed: CGFloat(rgba.r), green: CGFloat(rgba.g), blue: CGFloat(rgba.b), alpha: CGFloat(rgba.a))
        })
    }
}
