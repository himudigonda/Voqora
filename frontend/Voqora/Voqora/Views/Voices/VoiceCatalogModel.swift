import Foundation

nonisolated enum VoiceCatalogFilter: String, CaseIterable, Identifiable {
    case all
    case kokoro
    case supertonic
    case ming

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .all: "All"
        case .kokoro: "Kokoro"
        case .supertonic: "Supertonic"
        case .ming: "Ming"
        }
    }

    func includes(engine engineID: String) -> Bool {
        self == .all || rawValue == engineID
    }
}

nonisolated struct VoiceCatalogEntry: Identifiable, Hashable {
    let id: String
    let name: String
    let engineID: String
    let engineName: String
    let language: String
    let detail: String
    let searchText: String
    let hasEmotions: Bool
    let engineVoice: SpeechEngineVoice?

    var isCustom: Bool {
        engineVoice?.custom ?? false
    }
}

nonisolated struct VoiceCatalogSection: Identifiable, Hashable {
    let id: String
    let title: String
    let entries: [VoiceCatalogEntry]
}

enum VoiceCatalogBuilder {
    static func sections(
        engines: [SpeechEngine],
        filter: VoiceCatalogFilter,
        language: String? = nil,
        query: String
    ) -> [VoiceCatalogSection] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let entries = allEntries(engines: engines, filter: filter).filter { entry in
            (language == nil || entry.language == language)
                && (needle.isEmpty || entry.searchText.localizedCaseInsensitiveContains(needle))
        }
        return group(entries)
    }

    static func languages(engines: [SpeechEngine], filter: VoiceCatalogFilter) -> [String] {
        sortedLanguages(Set(allEntries(engines: engines, filter: filter).map(\.language)))
    }

    static func installableEngines(engines: [SpeechEngine], filter: VoiceCatalogFilter) -> [SpeechEngine] {
        engines.filter { !$0.installed && SpeechEngineID.downloadable.contains($0.id) && filter.includes(engine: $0.id) }
    }

    static func gender(forKokoroVoice id: String) -> String {
        let characters = Array(id.prefix(2))
        guard characters.count == 2 else { return "" }
        switch characters[1] {
        case "f": return "Female"
        case "m": return "Male"
        default: return ""
        }
    }

    static func baseLanguage(_ title: String) -> String {
        title.components(separatedBy: " (").first ?? title
    }

    private static func allEntries(engines: [SpeechEngine], filter: VoiceCatalogFilter) -> [VoiceCatalogEntry] {
        var entries: [VoiceCatalogEntry] = []
        if filter.includes(engine: SpeechEngineID.kokoro) {
            entries += kokoroEntries()
        }
        if filter.includes(engine: SpeechEngineID.supertonic) {
            entries += engineEntries(engines: engines, engineID: SpeechEngineID.supertonic, engineName: "Supertonic")
        }
        if filter.includes(engine: SpeechEngineID.ming) {
            entries += engineEntries(engines: engines, engineID: SpeechEngineID.ming, engineName: "Ming")
        }
        return entries
    }

    private static func group(_ entries: [VoiceCatalogEntry]) -> [VoiceCatalogSection] {
        var byLanguage: [String: [VoiceCatalogEntry]] = [:]
        for entry in entries {
            byLanguage[entry.language, default: []].append(entry)
        }
        return sortedLanguages(Set(byLanguage.keys)).map { language in
            VoiceCatalogSection(id: language, title: language, entries: byLanguage[language] ?? [])
        }
    }

    private static func sortedLanguages(_ languages: Set<String>) -> [String] {
        languages.sorted { lhs, rhs in
            if lhs == "English" || rhs == "English" {
                return lhs == "English" && rhs != "English"
            }
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
    }

    private static func kokoroEntries() -> [VoiceCatalogEntry] {
        DashboardViewModel.voiceCatalog.map { voice in
            let gender = gender(forKokoroVoice: voice.id)
            let detail = [voice.language, gender, voice.beta ? "Beta" : ""].filter { !$0.isEmpty }.joined(separator: " · ")
            return VoiceCatalogEntry(
                id: voice.id,
                name: voice.name,
                engineID: SpeechEngineID.kokoro,
                engineName: "Kokoro",
                language: baseLanguage(voice.language),
                detail: detail,
                searchText: [voice.name, detail, "Kokoro"].joined(separator: " "),
                hasEmotions: false,
                engineVoice: nil
            )
        }
    }

    private static func engineEntries(engines: [SpeechEngine], engineID: String, engineName: String) -> [VoiceCatalogEntry] {
        SpeechEngineCatalog.installedVoices(for: engineID, in: engines)
            .filter { !$0.custom }
            .map { voice in
                let language = languageTitle(voice.lang)
                let gender = voice.gender.lowercased() == "unknown" ? "" : voice.gender.capitalized
                let description = voice.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let line = [language == "Other" ? "" : language, gender].filter { !$0.isEmpty }.joined(separator: " · ")
                return VoiceCatalogEntry(
                    id: voice.id,
                    name: voice.name,
                    engineID: engineID,
                    engineName: engineName,
                    language: language,
                    detail: line.isEmpty ? description : line,
                    searchText: [voice.name, line, description, engineName].joined(separator: " "),
                    hasEmotions: !voice.emotions.isEmpty,
                    engineVoice: voice
                )
            }
    }

    private static func languageTitle(_ code: String) -> String {
        code.isEmpty ? "Other" : MingVoiceLanguage.label(code)
    }
}
