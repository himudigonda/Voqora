import Foundation
import SwiftUI

nonisolated enum ReadingFontFamily: String, CaseIterable, Identifiable, Sendable {
    case standard
    case rounded
    case serif
    case monospaced

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .standard: "System"
        case .rounded: "Rounded"
        case .serif: "Serif"
        case .monospaced: "Mono"
        }
    }

    var design: Font.Design {
        switch self {
        case .standard: .default
        case .rounded: .rounded
        case .serif: .serif
        case .monospaced: .monospaced
        }
    }
}

nonisolated struct ReadingTypography: Equatable, Sendable {
    static let fontSizeRange: ClosedRange<Double> = 14 ... 48
    static let lineHeightRange: ClosedRange<Double> = 1.0 ... 2.5
    static let letterSpacingRange: ClosedRange<Double> = 0 ... 0.25
    static let wordSpacingRange: ClosedRange<Double> = 0 ... 1.0
    static let fontSizeStep = 2.0
    static let standard = ReadingTypography(
        fontSize: defaultFontSize,
        family: .standard,
        letterSpacing: defaultSpacing,
        wordSpacing: defaultSpacing,
        lineHeight: defaultLineHeight
    )

    private static let defaultFontSize = 24.0
    private static let defaultSpacing = 0.0
    private static let defaultLineHeight = 1.5
    private static let naturalLineHeight = 1.2
    private static let headingScale = 1.25
    private static let charactersPerLine = 34.0

    var fontSize: Double {
        didSet { fontSize = Self.clamp(fontSize, to: Self.fontSizeRange, fallback: Self.defaultFontSize) }
    }

    var family: ReadingFontFamily

    var letterSpacing: Double {
        didSet { letterSpacing = Self.clamp(letterSpacing, to: Self.letterSpacingRange, fallback: Self.defaultSpacing) }
    }

    var wordSpacing: Double {
        didSet { wordSpacing = Self.clamp(wordSpacing, to: Self.wordSpacingRange, fallback: Self.defaultSpacing) }
    }

    var lineHeight: Double {
        didSet { lineHeight = Self.clamp(lineHeight, to: Self.lineHeightRange, fallback: Self.defaultLineHeight) }
    }

    init(fontSize: Double, family: ReadingFontFamily, letterSpacing: Double, wordSpacing: Double, lineHeight: Double) {
        self.fontSize = Self.clamp(fontSize, to: Self.fontSizeRange, fallback: Self.defaultFontSize)
        self.family = family
        self.letterSpacing = Self.clamp(letterSpacing, to: Self.letterSpacingRange, fallback: Self.defaultSpacing)
        self.wordSpacing = Self.clamp(wordSpacing, to: Self.wordSpacingRange, fallback: Self.defaultSpacing)
        self.lineHeight = Self.clamp(lineHeight, to: Self.lineHeightRange, fallback: Self.defaultLineHeight)
    }

    var letterKerning: CGFloat {
        CGFloat(letterSpacing * fontSize)
    }

    var wordKerning: CGFloat {
        CGFloat(wordSpacing * fontSize)
    }

    var lineSpacing: CGFloat {
        CGFloat(max(0, lineHeight - 1) * fontSize * Self.naturalLineHeight)
    }

    var headingSize: Double {
        fontSize * Self.headingScale
    }

    var measure: CGFloat {
        CGFloat(fontSize * Self.charactersPerLine * (1 + letterSpacing * 2 + wordSpacing * 0.2))
    }

    var canDecreaseFontSize: Bool {
        fontSize > Self.fontSizeRange.lowerBound
    }

    var canIncreaseFontSize: Bool {
        fontSize < Self.fontSizeRange.upperBound
    }

    func adjustingFontSize(by delta: Double) -> ReadingTypography {
        var copy = self
        copy.fontSize = fontSize + delta
        return copy
    }

    func font(isHeading: Bool) -> Font {
        .system(size: CGFloat(isHeading ? headingSize : fontSize), weight: isHeading ? .bold : .regular, design: family.design)
    }

    private static func clamp(_ value: Double, to range: ClosedRange<Double>, fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return min(range.upperBound, max(range.lowerBound, value))
    }
}

nonisolated enum ReadingTheme: String, CaseIterable, Identifiable, Sendable {
    case paper
    case sepia
    case dark
    case highContrast

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .paper: "Paper"
        case .sepia: "Sepia"
        case .dark: "Dark"
        case .highContrast: "High Contrast"
        }
    }
}

nonisolated enum ReadingTint: String, CaseIterable, Identifiable, Sendable {
    case clear
    case rose
    case peach
    case lemon
    case mint
    case aqua
    case lavender

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .clear: "None"
        case .rose: "Rose"
        case .peach: "Peach"
        case .lemon: "Lemon"
        case .mint: "Mint"
        case .aqua: "Aqua"
        case .lavender: "Lavender"
        }
    }

    var hex: String? {
        switch self {
        case .clear: nil
        case .rose: "#F7C6CF"
        case .peach: "#F9D6B4"
        case .lemon: "#FBEFA0"
        case .mint: "#C8EAD1"
        case .aqua: "#BEE4EE"
        case .lavender: "#D8CEF0"
        }
    }
}

struct ReadingPalette: Equatable {
    let background: ColorRGBA
    let text: ColorRGBA
    let focusBand: ColorRGBA
    let emphasis: ColorRGBA
    let emphasisText: ColorRGBA
    let dimmedOpacity: Double
    let isDark: Bool
}

enum ReadingThemeResolver {
    private struct Base {
        let background: String
        let text: String
        let contrastText: String
        let focusBand: String
        let emphasis: String
        let emphasisText: String
        let isDark: Bool
        let tintStrength: Double
    }

    static let dimmedOpacity = 0.35
    static let increasedContrastDimmedOpacity = 0.6

    static func palette(theme: ReadingTheme, tint: ReadingTint, increaseContrast: Bool) -> ReadingPalette {
        let base = base(for: theme)
        let strength = increaseContrast ? base.tintStrength / 2 : base.tintStrength
        let background = tint.hex.map { blend(color(base.background), toward: color($0), amount: strength) } ?? color(base.background)
        let text = color(increaseContrast ? base.contrastText : base.text)
        return ReadingPalette(
            background: background,
            text: text,
            focusBand: blend(color(base.focusBand), toward: background, amount: 0.25),
            emphasis: color(base.emphasis),
            emphasisText: color(base.emphasisText),
            dimmedOpacity: increaseContrast || theme == .highContrast ? increasedContrastDimmedOpacity : dimmedOpacity,
            isDark: base.isDark
        )
    }

    private static func base(for theme: ReadingTheme) -> Base {
        switch theme {
        case .paper:
            Base(
                background: "#FBFAF6", text: "#1F1E1C", contrastText: "#000000", focusBand: "#EDE7D6",
                emphasis: "#FFE07A", emphasisText: "#000000", isDark: false, tintStrength: 0.4
            )
        case .sepia:
            Base(
                background: "#F4ECD8", text: "#3B2E1E", contrastText: "#1A120A", focusBand: "#E6D8B8",
                emphasis: "#E8C25E", emphasisText: "#1A120A", isDark: false, tintStrength: 0.3
            )
        case .dark:
            Base(
                background: "#1C1C1A", text: "#E9E7E1", contrastText: "#FFFFFF", focusBand: "#33322E",
                emphasis: "#6A5512", emphasisText: "#FFFFFF", isDark: true, tintStrength: 0.12
            )
        case .highContrast:
            Base(
                background: "#000000", text: "#FFFFFF", contrastText: "#FFFFFF", focusBand: "#262626",
                emphasis: "#FFD60A", emphasisText: "#000000", isDark: true, tintStrength: 0
            )
        }
    }

    private static func color(_ hex: String) -> ColorRGBA {
        ColorRGBA(hex: hex) ?? ColorRGBA(r: 0, g: 0, b: 0, a: 1)
    }

    private static func blend(_ base: ColorRGBA, toward target: ColorRGBA, amount: Double) -> ColorRGBA {
        let weight = min(1, max(0, amount))
        return ColorRGBA(
            r: base.r + (target.r - base.r) * weight,
            g: base.g + (target.g - base.g) * weight,
            b: base.b + (target.b - base.b) * weight,
            a: 1
        )
    }
}
