import AppKit
import SwiftUI

struct Theme {
    let surface: Color
    let surfaceContainerLow: Color
    let surfaceContainer: Color
    let surfaceContainerHigh: Color
    let surfaceContainerHighest: Color
    let onSurface: Color
    let onSurfaceVariant: Color
    let onSurfaceMuted: Color
    let primary: Color
    let onPrimary: Color
    let primaryContainer: Color
    let onPrimaryContainer: Color
    let secondaryContainer: Color
    let outline: Color
    let outlineVariant: Color
    let success: Color
    let warning: Color
    let danger: Color
}

extension Theme {
    enum Shape {
        static let xs: CGFloat = 6
        static let sm: CGFloat = 10
        static let md: CGFloat = 14
        static let lg: CGFloat = 20
        static let xl: CGFloat = 28
    }

    enum Space {
        static let unit: CGFloat = 4
        static let listGap: CGFloat = 2
        static let item: CGFloat = 12
        static let card: CGFloat = 20
        static let section: CGFloat = 32
        static let gutter: CGFloat = 40
        static let pageMaxWidth: CGFloat = 1040
    }

    enum Motion {
        static var selection: Animation? {
            reduceMotionEnabled ? nil : .spring(response: 0.35, dampingFraction: 0.86)
        }

        static var hover: Animation? {
            reduceMotionEnabled ? nil : .easeOut(duration: 0.12)
        }

        private static var reduceMotionEnabled: Bool {
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
    }

    struct TypeStyle {
        let size: CGFloat
        let weight: Font.Weight
    }

    static let fallback = Theme.make(for: .clay)

    private static var cache: [AccentColorOption: Theme] = [:]

    static func resolved(for option: AccentColorOption) -> Theme {
        if let cached = cache[option] {
            return cached
        }
        let built = make(for: option)
        cache[option] = built
        return built
    }

    private static func make(for option: AccentColorOption) -> Theme {
        let seed = option.seed
        var ramps: [ColorAppearance: AccentRamp] = [:]
        for appearance in [ColorAppearance.light, .dark, .highContrastLight, .highContrastDark] {
            ramps[appearance] = ColorRamp.uncachedRamp(for: seed, appearance: appearance)
        }
        func role(_ pick: @escaping (AccentRamp) -> ColorRGBA) -> Color {
            Adaptive.color { appearance in ramps[appearance].map(pick) ?? ColorRGBA(r: 0, g: 0, b: 0, a: 1) }
        }
        func tonal(_ lightness: [ColorAppearance: Double], chroma: Double) -> Color {
            Adaptive.color { ColorRamp.tone(seed: seed, lightness: lightness[$0] ?? 0.5, chroma: chroma) }
        }
        return Theme(
            surface: tonal(surfaceLightness, chroma: 0.006),
            surfaceContainerLow: tonal(lowLightness, chroma: 0.008),
            surfaceContainer: tonal(containerLightness, chroma: 0.010),
            surfaceContainerHigh: tonal(highLightness, chroma: 0.011),
            surfaceContainerHighest: tonal(highestLightness, chroma: 0.012),
            onSurface: Palette.textPrimary,
            onSurfaceVariant: Palette.textSecondary,
            onSurfaceMuted: Palette.textTertiary,
            primary: role(\.base),
            onPrimary: role(\.onAccent),
            primaryContainer: role(\.muted),
            onPrimaryContainer: role(\.strong),
            secondaryContainer: role(\.subtle),
            outline: Palette.controlBorder,
            outlineVariant: Palette.separator,
            success: Palette.success,
            warning: Palette.warning,
            danger: Palette.danger
        )
    }

    private static let surfaceLightness: [ColorAppearance: Double] = [
        .light: 0.985, .dark: 0.205, .highContrastLight: 1.0, .highContrastDark: 0.165,
    ]
    private static let lowLightness: [ColorAppearance: Double] = [
        .light: 0.965, .dark: 0.235, .highContrastLight: 0.972, .highContrastDark: 0.205,
    ]
    private static let containerLightness: [ColorAppearance: Double] = [
        .light: 0.950, .dark: 0.255, .highContrastLight: 0.948, .highContrastDark: 0.235,
    ]
    private static let highLightness: [ColorAppearance: Double] = [
        .light: 0.935, .dark: 0.285, .highContrastLight: 0.924, .highContrastDark: 0.270,
    ]
    private static let highestLightness: [ColorAppearance: Double] = [
        .light: 0.915, .dark: 0.315, .highContrastLight: 0.900, .highContrastDark: 0.310,
    ]
}

extension Theme.TypeStyle {
    static let display = Self(size: 34, weight: .bold)
    static let headline = Self(size: 26, weight: .semibold)
    static let title = Self(size: 20, weight: .semibold)
    static let titleSmall = Self(size: 15, weight: .semibold)
    static let body = Self(size: 14, weight: .regular)
    static let bodySmall = Self(size: 12.5, weight: .regular)
    static let label = Self(size: 13, weight: .medium)
    static let labelSmall = Self(size: 11, weight: .medium)
}

private enum Adaptive {
    static func color(_ shade: (ColorAppearance) -> ColorRGBA) -> Color {
        let light = shade(.light)
        let dark = shade(.dark)
        let highContrastLight = shade(.highContrastLight)
        let highContrastDark = shade(.highContrastDark)
        return Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let increased = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            let rgba = switch (isDark, increased) {
            case (false, false): light
            case (true, false): dark
            case (false, true): highContrastLight
            case (true, true): highContrastDark
            }
            return NSColor(srgbRed: CGFloat(rgba.r), green: CGFloat(rgba.g), blue: CGFloat(rgba.b), alpha: 1)
        })
    }
}

extension EnvironmentValues {
    @Entry var voqoraTheme: Theme = .fallback
}

private struct ThemeInjector: ViewModifier {
    @EnvironmentObject var vm: DashboardViewModel

    func body(content: Content) -> some View {
        content.environment(\.voqoraTheme, vm.theme)
    }
}

private struct ThemedFont: ViewModifier {
    @EnvironmentObject var vm: DashboardViewModel
    let style: Theme.TypeStyle

    func body(content: Content) -> some View {
        content.font(vm.font(style))
    }
}

extension View {
    func voqoraTheme() -> some View {
        modifier(ThemeInjector())
    }

    func voqoraFont(_ style: Theme.TypeStyle) -> some View {
        modifier(ThemedFont(style: style))
    }
}

extension DashboardViewModel {
    var theme: Theme {
        Theme.resolved(for: accentColorID)
    }

    func font(_ style: Theme.TypeStyle) -> Font {
        appFont(size: style.size, weight: style.weight)
    }
}
