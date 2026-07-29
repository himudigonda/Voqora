import NaturalLanguage

/// On-device language detection → matching voice selection.
///
/// Uses Apple's `NLLanguageRecognizer` (zero dependencies, fully offline) so that
/// when "Auto-detect language" is enabled, speaking Spanish/French/Hindi/etc. text
/// automatically picks a voice in that language instead of mispronouncing it with
/// the current (e.g. English) voice. The supported set mirrors the backend catalog.
enum LanguageDetector {
    /// Apple `NLLanguage` → our espeak voice-language code (supported subset only).
    /// Japanese is intentionally absent — espeak can't narrate kanji (see languages.py).
    static let nlToVoiceLang: [NLLanguage: String] = [
        .english: "en-us",
        .spanish: "es",
        .french: "fr-fr",
        .italian: "it",
        .portuguese: "pt-br",
        .hindi: "hi",
        .simplifiedChinese: "cmn",
        .traditionalChinese: "cmn",
    ]

    /// Detect the dominant language of `text` and return a matching voice id.
    ///
    /// Returns `fallback` (the user's chosen voice) when:
    ///   - detection is below `minConfidence` (e.g. text too short/ambiguous),
    ///   - the language isn't one we support, or
    ///   - the text is already in the fallback voice's language (incl. EN variants),
    ///     so a deliberate US-vs-UK or specific-voice pick is preserved.
    static func voiceForText(
        _ text: String,
        fallback: String,
        minConfidence: Double = 0.55
    ) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Very short strings detect poorly; don't second-guess the user's voice.
        guard trimmed.count >= 4 else { return fallback }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        guard let lang = recognizer.dominantLanguage else { return fallback }
        let confidence = recognizer.languageHypotheses(withMaximum: 1)[lang] ?? 0
        guard confidence >= minConfidence,
              let voiceLang = nlToVoiceLang[lang]
        else { return fallback }

        let fallbackLang = DashboardViewModel.langCode(forVoice: fallback)
        // Never switch between English variants (US ⇄ UK) or within the same language.
        if voiceLang.hasPrefix("en"), fallbackLang.hasPrefix("en") {
            return fallback
        }
        if voiceLang == fallbackLang {
            return fallback
        }

        return DashboardViewModel.defaultVoice(forLang: voiceLang) ?? fallback
    }
}
