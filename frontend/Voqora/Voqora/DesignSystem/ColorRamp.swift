import Foundation
import SwiftUI

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

    var wcagLuminance: Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    func wcagContrast(against other: ColorRGBA) -> Double {
        let lighter = max(wcagLuminance, other.wcagLuminance)
        let darker = min(wcagLuminance, other.wcagLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }
}

extension Color {
    init(_ rgba: ColorRGBA) {
        self.init(red: rgba.r, green: rgba.g, blue: rgba.b, opacity: rgba.a)
    }
}

private struct OKLCH {
    private struct LinearChannels {
        let red: Double
        let green: Double
        let blue: Double
    }

    var lightness: Double
    var chroma: Double
    var hue: Double

    var rgba: ColorRGBA {
        if let exact = OKLCH.inGamutRGBA(lightness: lightness, chroma: chroma, hue: hue) {
            return exact
        }
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

struct AccentRamp: Hashable {
    let subtle: ColorRGBA
    let muted: ColorRGBA
    let base: ColorRGBA
    let strong: ColorRGBA
    let onAccent: ColorRGBA
}

struct AccentSeed: Hashable {
    let hue: Double
    let chroma: Double
}

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

    private static func lightnesses(for appearance: ColorAppearance) -> RampValues {
        switch appearance {
        case .light: RampValues(subtle: 0.965, muted: 0.920, base: 0.515, strong: 0.440)
        case .highContrastLight: RampValues(subtle: 0.955, muted: 0.900, base: 0.435, strong: 0.375)
        case .dark: RampValues(subtle: 0.300, muted: 0.380, base: 0.760, strong: 0.850)
        case .highContrastDark: RampValues(subtle: 0.330, muted: 0.420, base: 0.840, strong: 0.910)
        }
    }

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
