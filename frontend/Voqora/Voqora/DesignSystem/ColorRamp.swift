//
//  ColorRamp.swift
//  Voqora
//
//  Voqora's accent colors are GENERATED, not hand-picked, so every accent
//  option is the same visual "weight" and every shade of it (a hover fill, a
//  selected row's wash, a pressed state) is a real opaque color rather than
//  `accent.opacity(someNumber)` guessed at a call site — the latter blends
//  toward whatever sits behind it, so the "same" faint accent wash used to
//  render as a different color on the sidebar than on the canvas.
//
//  Ported from GRiT's GRiTKit/ColorRamp.swift (same math, same ramp shape),
//  trimmed to what Voqora actually needs: the accent ramp only, no
//  calendar-specific event-chip derivation. The `DerivationCache`'s
//  `Synchronization.Mutex` is replaced with a plain `@MainActor` dictionary —
//  every call site here is already a SwiftUI view body on the main actor, and
//  Voqora has nothing like GRiT's per-frame, many-chip recompute pressure that
//  motivated a lock-free concurrent cache there.
//
//  Math: Björn Ottosson's OKLab, https://bottosson.github.io/posts/oklab/
//

import Foundation
import SwiftUI

// MARK: - sRGB color

/// A color as sRGB components in `0...1`, the shared currency between OKLCH
/// math and `SwiftUI.Color`/`NSColor`.
struct ColorRGBA: Hashable {
    let r: Double
    let g: Double
    let b: Double
    let a: Double

    init(r: Double, g: Double, b: Double, a: Double) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    /// Parses a `"#RRGGBB"` string (leading `#` optional, case-insensitive,
    /// exactly 6 hex digits). `nil` for anything else.
    init?(hex: String) {
        var digits = hex
        if digits.hasPrefix("#") {
            digits.removeFirst()
        }
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(
            r: Double((value >> 16) & 0xFF) / 255.0,
            g: Double((value >> 8) & 0xFF) / 255.0,
            b: Double(value & 0xFF) / 255.0,
            a: 1.0
        )
    }

    /// WCAG 2.x relative luminance.
    /// https://www.w3.org/TR/WCAG21/#dfn-relative-luminance
    var wcagLuminance: Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    /// WCAG 2.x contrast ratio between two opaque colors, `1...21`.
    func wcagContrast(against other: ColorRGBA) -> Double {
        let lighter = max(wcagLuminance, other.wcagLuminance)
        let darker = min(wcagLuminance, other.wcagLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }
}

extension Color {
    /// Bridges a ramp-derived `ColorRGBA` into SwiftUI.
    init(_ rgba: ColorRGBA) {
        self.init(red: rgba.r, green: rgba.g, blue: rgba.b, opacity: rgba.a)
    }
}

// MARK: - OKLCH

/// A color in OKLCH: perceptual `lightness` (0...1), `chroma` (colorfulness,
/// ~0...0.4 for displayable sRGB), and `hue` in degrees (0..<360).
///
/// Equal lightness steps in OKLCH look equal to the eye across every hue,
/// which HSL/HSB do not (an HSL yellow at 50% lightness reads far brighter
/// than an HSL blue at 50%) — that uniformity is what lets every accent option
/// share one lightness ramp and still read as the same weight.
private struct OKLCH {
    private struct LinearChannels {
        let red: Double
        let green: Double
        let blue: Double
    }

    var lightness: Double
    var chroma: Double
    var hue: Double

    /// The sRGB color for this OKLCH value, reduced into gamut when needed.
    ///
    /// Clamping raw R/G/B channels shifts the HUE (a clipped orange drifts
    /// yellow, since the channels clip by different amounts). Reducing chroma
    /// instead holds lightness and hue exact and gives up only saturation.
    var rgba: ColorRGBA {
        if let exact = OKLCH.inGamutRGBA(lightness: lightness, chroma: chroma, hue: hue) {
            return exact
        }
        // Binary search the largest displayable chroma at this lightness and
        // hue. Sixteen iterations resolves to ~1/65000 of the starting
        // chroma, far below one 8-bit step.
        var low = 0.0
        var high = chroma
        var best = OKLCH.clampedRGBA(lightness: lightness, chroma: 0, hue: hue)
        for _ in 0 ..< 16 {
            let mid = (low + high) / 2
            if let candidate = OKLCH.inGamutRGBA(lightness: lightness, chroma: mid, hue: hue) {
                best = candidate
                low = mid
            } else {
                high = mid
            }
        }
        return best
    }

    private static func linearize(_ channel: Double) -> Double {
        channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }

    private static func delinearize(_ channel: Double) -> Double {
        channel <= 0.0031308 ? channel * 12.92 : 1.055 * pow(channel, 1 / 2.4) - 0.055
    }

    /// The raw, unclamped linear-sRGB channels for an OKLCH triple. Channels
    /// outside `0...1` mean the color is outside the sRGB gamut.
    private static func channels(lightness: Double, chroma: Double, hue: Double) -> LinearChannels {
        let radians = hue * .pi / 180
        let a = chroma * cos(radians)
        let b = chroma * sin(radians)

        let l = pow(lightness + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m = pow(lightness - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s = pow(lightness - 0.0894841775 * a - 1.2914855480 * b, 3)

        return LinearChannels(
            red: 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
            green: -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
            blue: -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
        )
    }

    /// Non-nil only when the color is genuinely displayable. A hair of
    /// tolerance absorbs floating-point error at the exact gamut boundary.
    private static func inGamutRGBA(lightness: Double, chroma: Double, hue: Double) -> ColorRGBA? {
        let linear = channels(lightness: lightness, chroma: chroma, hue: hue)
        let tolerance = 1e-6
        let range = -tolerance ... (1 + tolerance)
        guard range.contains(linear.red), range.contains(linear.green), range.contains(linear.blue) else { return nil }
        return ColorRGBA(
            r: min(1, max(0, delinearize(linear.red))),
            g: min(1, max(0, delinearize(linear.green))),
            b: min(1, max(0, delinearize(linear.blue))),
            a: 1
        )
    }

    private static func clampedRGBA(lightness: Double, chroma: Double, hue: Double) -> ColorRGBA {
        let linear = channels(lightness: lightness, chroma: chroma, hue: hue)
        return ColorRGBA(
            r: min(1, max(0, delinearize(linear.red))),
            g: min(1, max(0, delinearize(linear.green))),
            b: min(1, max(0, delinearize(linear.blue))),
            a: 1
        )
    }
}

// MARK: - Appearance

/// Which of the four appearances a color is being resolved for.
enum ColorAppearance: Hashable {
    case light
    case dark
    case highContrastLight
    case highContrastDark

    var isDark: Bool {
        self == .dark || self == .highContrastDark
    }

    init(isDark: Bool, increaseContrast: Bool) {
        switch (isDark, increaseContrast) {
        case (false, false): self = .light
        case (false, true): self = .highContrastLight
        case (true, false): self = .dark
        case (true, true): self = .highContrastDark
        }
    }
}

// MARK: - Accent ramp

/// The five shades every accent resolves to. Named by ROLE, not by number, so
/// a call site asks for what it means and cannot invent a sixth shade by
/// reaching for `.opacity()`.
struct AccentRamp: Hashable {
    /// The faintest tint that still reads as "this row is selected". Sits
    /// directly on a surface as an opaque fill.
    let subtle: ColorRGBA
    /// One step up: a hover fill, a chip background.
    let muted: ColorRGBA
    /// The accent proper — icons, focus rings, accent-colored text. Meets
    /// WCAG AA against its own appearance's canvas.
    let base: ColorRGBA
    /// A pressed or otherwise emphasized state of `base`.
    let strong: ColorRGBA
    /// Text and icons drawn ON TOP of a `base` fill, chosen for contrast.
    let onAccent: ColorRGBA
}

/// One accent option's identity: a point on the OKLCH hue wheel plus how
/// colorful it should be. Everything else about it is derived.
struct AccentSeed: Hashable {
    let hue: Double
    let chroma: Double
}

/// One value per ramp role — used for both the lightness targets and the
/// chroma scale factors, since they are indexed identically.
private struct RampValues {
    let subtle: Double
    let muted: Double
    let base: Double
    let strong: Double
}

enum ColorRamp {
    @MainActor private static var cache: [RampKey: AccentRamp] = [:]

    private struct RampKey: Hashable {
        let seed: AccentSeed
        let appearance: ColorAppearance
    }

    /// The lightness each role targets, per appearance. Identical for every
    /// hue — that's what makes every accent option read as one family rather
    /// than six unrelated colors.
    ///
    /// `base` is placed where an accent-colored label clears WCAG AA (4.5:1)
    /// against the DARKEST surface of its appearance it may sit on — the
    /// ivory chrome in light mode, not the lighter canvas — and the symmetric
    /// constraint (the lightest dark surface) in dark mode. Increase Contrast
    /// pushes it a further step away from the surface rather than merely
    /// saturating it, since contrast is what that setting asks for.
    private static func lightnesses(for appearance: ColorAppearance) -> RampValues {
        switch appearance {
        case .light: RampValues(subtle: 0.965, muted: 0.920, base: 0.515, strong: 0.440)
        case .highContrastLight: RampValues(subtle: 0.955, muted: 0.900, base: 0.435, strong: 0.375)
        case .dark: RampValues(subtle: 0.300, muted: 0.380, base: 0.760, strong: 0.850)
        case .highContrastDark: RampValues(subtle: 0.330, muted: 0.420, base: 0.840, strong: 0.910)
        }
    }

    /// Chroma is scaled DOWN for the near-surface roles rather than held
    /// constant — a wash at full chroma but near-white lightness reads as a
    /// wrong, dirty color rather than a tint of the accent (the
    /// Helmholtz–Kohlrausch effect); pulling chroma back in proportion keeps
    /// `subtle` recognizably the same color as `base`.
    private static func chromaScales(for appearance: ColorAppearance) -> RampValues {
        appearance.isDark
            ? RampValues(subtle: 0.40, muted: 0.55, base: 1.00, strong: 0.92)
            : RampValues(subtle: 0.22, muted: 0.40, base: 1.00, strong: 1.00)
    }

    @MainActor
    static func ramp(for seed: AccentSeed, appearance: ColorAppearance) -> AccentRamp {
        let key = RampKey(seed: seed, appearance: appearance)
        if let cached = cache[key] {
            return cached
        }
        let derived = uncachedRamp(for: seed, appearance: appearance)
        cache[key] = derived
        return derived
    }

    static func uncachedRamp(for seed: AccentSeed, appearance: ColorAppearance) -> AccentRamp {
        let l = lightnesses(for: appearance)
        let c = chromaScales(for: appearance)

        func shade(_ lightness: Double, _ chromaScale: Double) -> ColorRGBA {
            OKLCH(lightness: lightness, chroma: seed.chroma * chromaScale, hue: seed.hue).rgba
        }

        let base = shade(l.base, c.base)

        // Near-white and near-black rather than pure #FFF/#000 — a pure-white
        // label on a colored fill glares, and the app has no pure black
        // anywhere else. Both still clear AA against every generated `base`.
        let lightInk = OKLCH(lightness: 0.985, chroma: seed.chroma * 0.02, hue: seed.hue).rgba
        let darkInk = OKLCH(lightness: 0.180, chroma: seed.chroma * 0.10, hue: seed.hue).rgba

        return AccentRamp(
            subtle: shade(l.subtle, c.subtle),
            muted: shade(l.muted, c.muted),
            base: base,
            strong: shade(l.strong, c.strong),
            onAccent: base.wcagContrast(against: lightInk) >= base.wcagContrast(against: darkInk) ? lightInk : darkInk
        )
    }
}
