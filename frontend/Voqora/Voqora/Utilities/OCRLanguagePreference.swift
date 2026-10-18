import Foundation

nonisolated enum OCRLanguagePreference {
    static let fallbackLanguage = "en-US"

    static func visionLanguage(forVoice voiceID: String) -> String? {
        switch DashboardViewModel.langCode(forVoice: voiceID) {
        case "en-us": "en-US"
        case "en-gb": "en-GB"
        case "es": "es-ES"
        case "fr-fr": "fr-FR"
        case "it": "it-IT"
        case "pt-br": "pt-BR"
        case "cmn": "zh-Hans"
        default: nil
        }
    }

    static func preferredLanguages(forVoices voiceIDs: [String]) -> [String] {
        var seen = Set<String>()
        let candidates = voiceIDs.compactMap(visionLanguage(forVoice:)) + [fallbackLanguage]
        return candidates.filter { seen.insert($0).inserted }
    }

    static func supported(_ preferred: [String], available: [String]) -> [String] {
        let availableLanguages = Set(available)
        return preferred.filter { availableLanguages.contains($0) }
    }
}
