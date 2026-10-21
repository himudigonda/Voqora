import Foundation

enum VoicePickerScope: Equatable {
    case everything
    case podcast(PodcastLanguage?)

    var language: PodcastLanguage? {
        guard case let .podcast(language) = self else { return nil }
        return language
    }

    var includesEngineVoices: Bool {
        self == .everything
    }
}

struct VoicePickerEntry: Identifiable, Hashable {
    let id: String
    let name: String
    let detail: String
    let engineName: String
}

struct VoicePickerSection: Identifiable, Hashable {
    let id: String
    let title: String
    let entries: [VoicePickerEntry]
}

struct VoicePickerDescriptor: Equatable {
    let name: String
    let engineName: String
    let languageLabel: String
}

enum VoicePickerCatalog {
    static let blendEngineName = "Blend"

    static func sections(
        blends: [VoiceBlend],
        engines: [SpeechEngine],
        query: String,
        scope: VoicePickerScope
    ) -> [VoicePickerSection] {
        var sections: [VoicePickerSection] = []
        let mine = blends
            .filter { matches(language: scope.language, code: $0.lang) }
            .map { VoicePickerEntry(id: $0.id, name: $0.name, detail: languageLabel(forBlend: $0), engineName: blendEngineName) }
        if !mine.isEmpty {
            sections.append(VoicePickerSection(id: "mine", title: "My Voices", entries: mine))
        }
        sections += kokoroSections(scope: scope)
        if scope.includesEngineVoices {
            sections += supertonicSections(engines: engines)
            sections += mingSections(engines: engines)
        }
        return filtered(sections, query: query)
    }

    static func descriptor(forVoice id: String, blends: [VoiceBlend]) -> VoicePickerDescriptor {
        let name = DashboardViewModel.voiceName(for: id)
        if let blend = blends.first(where: { $0.id == id }) {
            return VoicePickerDescriptor(name: blend.name, engineName: blendEngineName, languageLabel: languageLabel(forBlend: blend))
        }
        if VoiceBlendRules.isBlendID(id) {
            return VoicePickerDescriptor(name: name, engineName: blendEngineName, languageLabel: "")
        }
        switch SpeechEngineID.engine(forVoice: id) {
        case SpeechEngineID.ming:
            return VoicePickerDescriptor(name: name, engineName: "Ming", languageLabel: engineLanguageLabel(forVoice: id))
        case SpeechEngineID.supertonic:
            return VoicePickerDescriptor(name: name, engineName: "Supertonic", languageLabel: engineLanguageLabel(forVoice: id))
        default:
            return VoicePickerDescriptor(
                name: name,
                engineName: "Kokoro",
                languageLabel: DashboardViewModel.voicesByID[id]?.language ?? ""
            )
        }
    }

    private static func kokoroSections(scope: VoicePickerScope) -> [VoicePickerSection] {
        DashboardViewModel.languageGroups.compactMap { group in
            let entries = group.voices
                .filter { matches(language: scope.language, code: DashboardViewModel.langCode(forVoice: $0.id)) }
                .map { VoicePickerEntry(id: $0.id, name: $0.name, detail: $0.language, engineName: "Kokoro") }
            guard !entries.isEmpty else { return nil }
            return VoicePickerSection(
                id: "kokoro.\(group.id)",
                title: group.beta ? "\(group.flag) \(group.id) (Beta)" : "\(group.flag) \(group.id)",
                entries: entries
            )
        }
    }

    private static func supertonicSections(engines: [SpeechEngine]) -> [VoicePickerSection] {
        let voices = SpeechEngineCatalog.installedVoices(for: SpeechEngineID.supertonic, in: engines)
        var order: [String] = []
        var byLanguage: [String: [SpeechEngineVoice]] = [:]
        for voice in voices {
            let title = languageTitle(voice.lang)
            if byLanguage[title] == nil {
                order.append(title)
            }
            byLanguage[title, default: []].append(voice)
        }
        return order.map { title in
            VoicePickerSection(
                id: "supertonic.\(title)",
                title: "Supertonic · \(title)",
                entries: (byLanguage[title] ?? []).map { entry($0, engineName: "Supertonic") }
            )
        }
    }

    private static func mingSections(engines: [SpeechEngine]) -> [VoicePickerSection] {
        let voices = SpeechEngineCatalog.installedVoices(for: SpeechEngineID.ming, in: engines)
        return MingVoiceGroup.allCases.compactMap { group in
            let members = voices.filter { $0.mingGroup == group }
            guard !members.isEmpty else { return nil }
            let title = switch group {
            case .english: "English"
            case .chinese: "Chinese"
            case .mine: "My voices"
            }
            return VoicePickerSection(
                id: "ming.\(group.rawValue)",
                title: "Ming · \(title)",
                entries: members.map { entry($0, engineName: "Ming") }
            )
        }
    }

    private static func entry(_ voice: SpeechEngineVoice, engineName: String) -> VoicePickerEntry {
        let description = voice.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fallback = [voice.gender.capitalized, languageTitle(voice.lang)]
            .filter { !$0.isEmpty && $0 != "Other" }
            .joined(separator: " · ")
        return VoicePickerEntry(
            id: voice.id,
            name: voice.name,
            detail: description.isEmpty ? fallback : description,
            engineName: engineName
        )
    }

    private static func languageTitle(_ code: String) -> String {
        code.isEmpty ? "Other" : MingVoiceLanguage.label(code)
    }

    private static func filtered(_ sections: [VoicePickerSection], query: String) -> [VoicePickerSection] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return sections }
        return sections.compactMap { section in
            let entries = section.entries.filter { entry in
                [entry.name, entry.detail, entry.engineName, section.title].contains { $0.localizedCaseInsensitiveContains(needle) }
            }
            return entries.isEmpty ? nil : VoicePickerSection(id: section.id, title: section.title, entries: entries)
        }
    }

    private static func matches(language: PodcastLanguage?, code: String) -> Bool {
        guard let language else { return true }
        return PodcastLanguage.baseCode(of: code) == language.baseCode
    }

    private static func languageLabel(forBlend blend: VoiceBlend) -> String {
        PodcastLanguage(rawValue: blend.lang)?.displayName ?? ""
    }

    private static func engineLanguageLabel(forVoice id: String) -> String {
        guard let lang = EngineVoiceDirectory.shared.summary(for: id)?.lang, !lang.isEmpty else { return "" }
        return MingVoiceLanguage.label(lang)
    }
}
