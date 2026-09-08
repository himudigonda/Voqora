//
//  Palette.swift
//  Voqora
//
//  Voqora's neutral surfaces and text ramp are the same "Anthropic/Claude"
//  warm-neutral family GRiT uses — ported hex-for-hex so the two apps read as
//  one design language rather than two apps that happen to both be "warm and
//  flat". An ivory (`#F0EEE6`) chrome over a barely-warm canvas in light mode;
//  a warm charcoal (`#262624`) canvas with a darker chrome in dark mode.
//
//  Two kinds of color live here, built differently on purpose:
//
//  **Neutrals** are hand-authored per appearance, exposed as a `Color` backed
//  by an `NSColor` dynamic provider that re-resolves at DRAW time against the
//  real `NSAppearance` (Increase Contrast included).
//
//  **Accents** are generated in OKLCH by `ColorRamp` from a hue/chroma seed.
//  Voqora ships the same six named options GRiT does — `clay`, `sage`,
//  `slate`, `plum`, `ochre`, `teal` — so an accent picked in either app is the
//  same color. Voqora's own identity was built around cyan/teal, so its
//  default is `teal` rather than GRiT's `clay`; nothing else about the ramp
//  differs.
//

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

    /// Where this accent sits on the OKLCH hue wheel, and how colorful it is.
    /// Identical to GRiT's seeds — `clay`'s hue/chroma are Anthropic's own
    /// `#D97757`, measured rather than guessed; the rest are spaced around
    /// the wheel at chroma values that keep `base` inside sRGB at the ramp's
    /// lightness targets.
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

/// The four values every hand-authored neutral needs — one per appearance
/// Voqora resolves against.
private struct AppearanceVariants<Value> {
    let light: Value
    let dark: Value
    let highContrastLight: Value
    let highContrastDark: Value
}

enum Palette {
    // MARK: Surfaces

    /// The main content canvas. The lightest large surface in light mode and
    /// the mid tone in dark mode.
    private static let surfaceBaseHexVariants = AppearanceVariants(
        light: "#FAF9F5", dark: "#262624", highContrastLight: "#FFFFFF", highContrastDark: "#1A1A18"
    )

    static let surfaceBase: Color = dynamicColor(surfaceBaseHexVariants)

    /// Anything that reads as sitting ABOVE the canvas: popovers, sheets,
    /// menus, a card.
    private static let surfaceRaisedHexVariants = AppearanceVariants(
        light: "#FFFFFF", dark: "#30302E", highContrastLight: "#FFFFFF", highContrastDark: "#262624"
    )

    static let surfaceRaised: Color = dynamicColor(surfaceRaisedHexVariants)

    /// Chrome that frames the canvas: the sidebar, the window's own
    /// background under the traffic lights. In light mode this is the ivory
    /// the whole design is built around — deliberately DARKER than the
    /// canvas, which is what makes the app read as warm paper rather than as
    /// a white window.
    private static let surfaceSunkenHexVariants = AppearanceVariants(
        light: "#F0EEE6", dark: "#1F1E1D", highContrastLight: "#F2F0E8", highContrastDark: "#0F0F0E"
    )

    static let surfaceSunken: Color = dynamicColor(surfaceSunkenHexVariants)

    // MARK: Lines

    private static let separatorHexVariants = AppearanceVariants(
        light: "#C6C4BF", dark: "#494844", highContrastLight: "#ADABA5", highContrastDark: "#555450"
    )

    static let separator: Color = dynamicColor(separatorHexVariants)

    // MARK: Controls

    /// A secondary button's fill. Hand-authored rather than
    /// `Color.secondary.opacity(0.15)` — that resolves inside AppKit (so
    /// nothing here could measure it) and put the control's boundary at
    /// roughly 1.15:1 against the surface, well under WCAG 1.4.11's 3:1.
    private static let controlFillHexVariants = AppearanceVariants(
        light: "#EDEBE3", dark: "#3A3937", highContrastLight: "#EFEDE5", highContrastDark: "#333230"
    )

    static let controlFill: Color = dynamicColor(controlFillHexVariants)

    /// A secondary button's border — the part that makes it read as a
    /// control. The fill alone can't carry 3:1 against every surface AND
    /// keep `textPrimary` at 4.5:1 on top of it, so the boundary does the
    /// 3:1 work and the fill stays quiet.
    private static let controlBorderHexVariants = AppearanceVariants(
        light: "#807E76", dark: "#8C8A84", highContrastLight: "#5E5C56", highContrastDark: "#B0AEA8"
    )

    static let controlBorder: Color = dynamicColor(controlBorderHexVariants)

    // MARK: Text

    private static let textPrimaryHexVariants = AppearanceVariants(
        light: "#181817", dark: "#F5F4EF", highContrastLight: "#000000", highContrastDark: "#FFFFFF"
    )

    static let textPrimary: Color = dynamicColor(textPrimaryHexVariants)

    /// The three text levels are spaced by CONTRAST, measured against the
    /// darkest surface each level may sit on (the ivory chrome in light
    /// mode, not the lighter canvas) rather than by picking greys that
    /// looked right.
    private static let textSecondaryHexVariants = AppearanceVariants(
        light: "#52514E", dark: "#C0BEBA", highContrastLight: "#3D3C39", highContrastDark: "#CFCDC9"
    )

    static let textSecondary: Color = dynamicColor(textSecondaryHexVariants)

    private static let textTertiaryHexVariants = AppearanceVariants(
        light: "#6C6A65", dark: "#9D9C96", highContrastLight: "#5B5954", highContrastDark: "#A6A49F"
    )

    static let textTertiary: Color = dynamicColor(textTertiaryHexVariants)

    // MARK: Semantic status

    /// "Something needs your attention": a failed conversion, a denied
    /// permission, an expired key. NOT `Color.orange` — that measures
    /// 1.99:1 against the ivory chrome, under both AA and the 3:1 floor for
    /// non-text graphics, as body text in what is often the only copy of an
    /// error message on screen.
    private static let warningHexVariants = AppearanceVariants(
        light: "#944B00", dark: "#FF9134", highContrastLight: "#783C00", highContrastDark: "#FFB988"
    )

    static let warning: Color = dynamicColor(warningHexVariants)

    /// "This worked": a saved key, a completed audiobook, a verified email.
    /// See `warning` for why this is not `Color.green`.
    private static let successHexVariants = AppearanceVariants(
        light: "#00772A", dark: "#3BD25F", highContrastLight: "#006020", highContrastDark: "#5CEC79"
    )

    static let success: Color = dynamicColor(successHexVariants)

    /// "This is destructive, or has failed outright": delete confirmations,
    /// stop/cancel actions, load failures. The same WCAG-corrected red the
    /// rest of this family is built around (GRiT's `nowIndicator`, repurposed
    /// here under the name Voqora actually uses it for).
    private static let dangerHexVariants = AppearanceVariants(
        light: "#C6483C", dark: "#F08379", highContrastLight: "#A32E24", highContrastDark: "#FF9E96"
    )

    static let danger: Color = dynamicColor(dangerHexVariants)

    // MARK: Inks

    private static let lightInkHex = "#FFFFFF"
    private static let darkInkHex = "#181817"

    /// Text and icons drawn on a `danger` fill — the confirm button on every
    /// irreversible action. Picking the ink from the fill (rather than a
    /// hardcoded `.white`) matters most in dark mode, where `danger` sits at
    /// a light OKLCH lightness and white-on-it drops to ~2.5:1.
    private static let onDangerHexVariants = readableInkVariants(over: dangerHexVariants)

    static let onDanger: Color = dynamicColor(onDangerHexVariants)

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

    // MARK: Accents

    /// The five-shade ramp for `option`. Every shade is opaque, so a
    /// `subtle` fill looks the same on the ivory chrome as on the white
    /// canvas.
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

    /// The accent proper plus its faint companion, in SwiftUI terms.
    @MainActor
    static func accentColors(
        for option: AccentColorOption,
        appearance: ColorScheme,
        increaseContrast: Bool
    ) -> (accent: Color, accentMuted: Color) {
        let ramp = accentRamp(for: option, appearance: appearance, increaseContrast: increaseContrast)
        return (Color(ramp.base), Color(ramp.muted))
    }

    /// The ink for text and icons drawn ON a `base` accent fill — a primary
    /// button's label, a selected row's icon.
    @MainActor
    static func onAccentColor(
        for option: AccentColorOption,
        appearance: ColorScheme,
        increaseContrast: Bool
    ) -> Color {
        Color(accentRamp(for: option, appearance: appearance, increaseContrast: increaseContrast).onAccent)
    }

    // MARK: Resolution

    private static func resolve<Value>(_ variants: AppearanceVariants<Value>, appearance: ColorScheme, increaseContrast: Bool) -> Value {
        switch appearance {
        case .dark: increaseContrast ? variants.highContrastDark : variants.dark
        default: increaseContrast ? variants.highContrastLight : variants.light
        }
    }

    /// An `NSAppearance` carries the light/dark axis but not Increase
    /// Contrast — that comes from `NSWorkspace` — which is why the
    /// accessibility appearance names can't be resolved through
    /// `bestMatch(from:)` here.
    private static func resolve<Value>(_ variants: AppearanceVariants<Value>, for appearance: NSAppearance) -> Value {
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return resolve(
            variants,
            appearance: isDark ? .dark : .light,
            increaseContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        )
    }

    /// A stored `static let`, not a computed `static var` — a computed token
    /// allocates a new `NSColor` (with a new provider closure that reparses
    /// its hex string) on every read, and SwiftUI decides whether it can skip
    /// re-rendering a view by comparing stored properties, so a token that
    /// never compares equal to itself defeats that short-circuit everywhere
    /// it's used. The `NSColor` is still a DYNAMIC provider underneath, so it
    /// re-resolves at DRAW time against the real `NSAppearance` regardless.
    private static func dynamicColor(_ hexVariants: AppearanceVariants<String>) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = resolve(hexVariants, for: appearance)
            let rgba = ColorRGBA(hex: hex) ?? ColorRGBA(r: 0, g: 0, b: 0, a: 1)
            return NSColor(srgbRed: CGFloat(rgba.r), green: CGFloat(rgba.g), blue: CGFloat(rgba.b), alpha: CGFloat(rgba.a))
        })
    }
}
