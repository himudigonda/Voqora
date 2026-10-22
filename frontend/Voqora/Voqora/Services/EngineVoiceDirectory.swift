import Foundation

final nonisolated class EngineVoiceDirectory: @unchecked Sendable {
    nonisolated struct Summary: Codable, Equatable, Sendable {
        let name: String
        let lang: String
        let custom: Bool
    }

    static let shared = EngineVoiceDirectory(defaults: .standard)
    static let defaultsKey = "engineVoiceDirectory"

    private let lock = NSLock()
    private let defaults: UserDefaults
    private var summaries: [String: Summary]

    init(defaults: UserDefaults) {
        self.defaults = defaults
        summaries = Self.load(from: defaults)
    }

    func summary(for id: String) -> Summary? {
        lock.withLock { summaries[id] }
    }

    func record(_ voices: [SpeechEngineVoice]) {
        let snapshot: [String: Summary]? = lock.withLock {
            var changed = false
            for voice in voices {
                let summary = Summary(name: voice.name, lang: voice.lang, custom: voice.custom)
                if summaries[voice.id] != summary {
                    summaries[voice.id] = summary
                    changed = true
                }
            }
            return changed ? summaries : nil
        }
        if let snapshot {
            save(snapshot)
        }
    }

    private func save(_ snapshot: [String: Summary]) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    private static func load(from defaults: UserDefaults) -> [String: Summary] {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([String: Summary].self, from: data)
        else { return [:] }
        return decoded
    }
}

nonisolated enum EngineVoiceLanguage {
    static func appCode(forEngineLanguage lang: String) -> String? {
        switch lang.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) {
        case "zh": "cmn"
        case "en": "en-us"
        case "es": "es"
        case "fr": "fr-fr"
        case "hi": "hi"
        case "it": "it"
        case "pt": "pt-br"
        default: nil
        }
    }
}
