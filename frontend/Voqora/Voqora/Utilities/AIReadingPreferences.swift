import Foundation

nonisolated enum AIReadingPreferences {
    static let translateTargetKey = "aiTranslateTargetLanguage"

    static func translateTarget(defaults: UserDefaults, preferredLanguages: [String]) -> AILanguage {
        if let stored = defaults.string(forKey: translateTargetKey).flatMap(AILanguage.init(rawValue:)) {
            return stored
        }
        return defaultTranslateTarget(preferredLanguages: preferredLanguages)
    }

    static func defaultTranslateTarget(preferredLanguages: [String]) -> AILanguage {
        preferredLanguages
            .compactMap(AILanguage.init(localeIdentifier:))
            .first { !$0.isEnglish && DashboardViewModel.defaultVoice(forLang: $0.rawValue) != nil }
            ?? .spanish
    }
}

nonisolated enum AIVoiceMatcher {
    static func voice(for language: AILanguage, current: String) -> String {
        let currentLanguage = DashboardViewModel.langCode(forVoice: current)
        if currentLanguage == language.rawValue {
            return current
        }
        if language.isEnglish, currentLanguage.hasPrefix("en") {
            return current
        }
        return DashboardViewModel.defaultVoice(forLang: language.rawValue) ?? current
    }
}
