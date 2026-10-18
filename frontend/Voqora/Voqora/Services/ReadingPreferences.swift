import Combine
import Foundation

final class ReadingPreferences: ObservableObject {
    enum Keys {
        static let fontSize = "readingFontSize"
        static let fontFamily = "readingFontFamily"
        static let letterSpacing = "readingLetterSpacing"
        static let wordSpacing = "readingWordSpacing"
        static let lineHeight = "readingLineHeight"
        static let theme = "readingTheme"
        static let tint = "readingTint"
        static let showsRuler = "readingShowsRuler"
        static let emphasizesWords = "readingEmphasizesWords"
    }

    static let shared = ReadingPreferences()

    @Published var typography: ReadingTypography {
        didSet { persistTypography() }
    }

    @Published var theme: ReadingTheme {
        didSet { defaults.set(theme.rawValue, forKey: Keys.theme) }
    }

    @Published var tint: ReadingTint {
        didSet { defaults.set(tint.rawValue, forKey: Keys.tint) }
    }

    @Published var showsRuler: Bool {
        didSet { defaults.set(showsRuler, forKey: Keys.showsRuler) }
    }

    @Published var emphasizesWords: Bool {
        didSet { defaults.set(emphasizesWords, forKey: Keys.emphasizesWords) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let standard = ReadingTypography.standard
        typography = ReadingTypography(
            fontSize: defaults.object(forKey: Keys.fontSize) as? Double ?? standard.fontSize,
            family: defaults.string(forKey: Keys.fontFamily).flatMap(ReadingFontFamily.init(rawValue:)) ?? standard.family,
            letterSpacing: defaults.object(forKey: Keys.letterSpacing) as? Double ?? standard.letterSpacing,
            wordSpacing: defaults.object(forKey: Keys.wordSpacing) as? Double ?? standard.wordSpacing,
            lineHeight: defaults.object(forKey: Keys.lineHeight) as? Double ?? standard.lineHeight
        )
        theme = defaults.string(forKey: Keys.theme).flatMap(ReadingTheme.init(rawValue:)) ?? .paper
        tint = defaults.string(forKey: Keys.tint).flatMap(ReadingTint.init(rawValue:)) ?? .clear
        showsRuler = defaults.object(forKey: Keys.showsRuler) as? Bool ?? true
        emphasizesWords = defaults.object(forKey: Keys.emphasizesWords) as? Bool ?? true
    }

    func resetToDefaults() {
        typography = .standard
        theme = .paper
        tint = .clear
        showsRuler = true
        emphasizesWords = true
        VoqoraLog.info("ReadingMode", "Reading preferences reset")
    }

    private func persistTypography() {
        defaults.set(typography.fontSize, forKey: Keys.fontSize)
        defaults.set(typography.family.rawValue, forKey: Keys.fontFamily)
        defaults.set(typography.letterSpacing, forKey: Keys.letterSpacing)
        defaults.set(typography.wordSpacing, forKey: Keys.wordSpacing)
        defaults.set(typography.lineHeight, forKey: Keys.lineHeight)
    }
}
