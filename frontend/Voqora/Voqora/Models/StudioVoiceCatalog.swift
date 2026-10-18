import Foundation

struct StudioVoiceOption: Identifiable, Hashable {
    let id: String
    let name: String
    let isBlend: Bool
}

struct StudioVoiceGroup: Identifiable, Hashable {
    let id: String
    let voices: [StudioVoiceOption]
}

enum StudioVoiceCatalog {
    static let blendPrefix = "blend:"
    static let blendGroupTitle = "Your Blends"

    static func isBlend(_ voiceID: String) -> Bool {
        voiceID.hasPrefix(blendPrefix)
    }

    static func groups(blends: [PodcastVoiceBlend], language: PodcastLanguage? = nil) -> [StudioVoiceGroup] {
        let blendOptions = blends
            .filter { blend in matches(blend.lang, language) }
            .map { StudioVoiceOption(id: $0.id, name: $0.name, isBlend: true) }
        var groups: [StudioVoiceGroup] = []
        if !blendOptions.isEmpty {
            groups.append(StudioVoiceGroup(id: blendGroupTitle, voices: blendOptions))
        }
        for group in DashboardViewModel.languageGroups {
            let voices = group.voices
                .filter { voice in matches(DashboardViewModel.langCode(forVoice: voice.id), language) }
                .map { StudioVoiceOption(id: $0.id, name: $0.display, isBlend: false) }
            if !voices.isEmpty {
                groups.append(StudioVoiceGroup(id: group.id, voices: voices))
            }
        }
        return groups
    }

    static func displayName(for voiceID: String, blends: [PodcastVoiceBlend]) -> String {
        if voiceID.isEmpty {
            return "No voice"
        }
        if isBlend(voiceID) {
            return blends.first { $0.id == voiceID }?.name ?? "Custom blend"
        }
        return DashboardViewModel.voiceName(for: voiceID)
    }

    static func languageCode(for voiceID: String, blends: [PodcastVoiceBlend]) -> String? {
        guard isBlend(voiceID) else { return DashboardViewModel.langCode(forVoice: voiceID) }
        return blends.first { $0.id == voiceID }?.lang
    }

    static func speaks(_ voiceID: String, language: PodcastLanguage, blends: [PodcastVoiceBlend]) -> Bool {
        guard let code = languageCode(for: voiceID, blends: blends) else { return true }
        return sameLanguage(code, language.rawValue)
    }

    static func defaultVoices(for language: PodcastLanguage) -> [String] {
        let voices = DashboardViewModel.voiceCatalog
            .map(\.id)
            .filter { sameLanguage(DashboardViewModel.langCode(forVoice: $0), language.rawValue) }
        let preferred = voices.filter { DashboardViewModel.langCode(forVoice: $0) == language.rawValue }
        let pool = preferred.count >= 2 ? preferred : voices
        let female = pool.first { $0.dropFirst().first == "f" }
        let male = pool.first { $0.dropFirst().first == "m" }
        let picks = [female, male].compactMap(\.self)
        return picks.count >= 2 ? picks : Array(pool.prefix(2))
    }

    static func isBundledSample(_ voiceID: String) -> Bool {
        !isBlend(voiceID) && DashboardViewModel.voicesByID[voiceID] != nil
    }

    private static func matches(_ code: String, _ language: PodcastLanguage?) -> Bool {
        guard let language else { return true }
        return sameLanguage(code, language.rawValue)
    }

    private static func sameLanguage(_ lhs: String, _ rhs: String) -> Bool {
        PodcastLanguage.baseCode(of: lhs) == PodcastLanguage.baseCode(of: rhs)
    }
}
