import NaturalLanguage

enum LanguageDetector {
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

    static func voiceForText(
        _ text: String,
        fallback: String,
        minConfidence: Double = 0.55
    ) -> String {
        guard !SpeechEngineID.isDownloadableEngineVoice(fallback) else { return fallback }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 4 else { return fallback }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        guard let language = recognizer.dominantLanguage else { return fallback }
        let confidence = recognizer.languageHypotheses(withMaximum: 1)[language] ?? 0
        guard confidence >= minConfidence,
              let voiceLanguage = nlToVoiceLang[language]
        else { return fallback }

        let fallbackLanguage = DashboardViewModel.langCode(forVoice: fallback)
        if voiceLanguage.hasPrefix("en"), fallbackLanguage.hasPrefix("en") {
            return fallback
        }
        if voiceLanguage == fallbackLanguage {
            return fallback
        }

        return DashboardViewModel.defaultVoice(forLang: voiceLanguage) ?? fallback
    }
}
