import Foundation

nonisolated enum SpeechEngineID {
    static let kokoro = "kokoro"
    static let supertonic = "supertonic"
    static let supertonicVoicePrefix = "supertonic:"

    static func isSupertonicVoice(_ voice: String) -> Bool {
        voice.hasPrefix(supertonicVoicePrefix)
    }

    static func engine(forVoice voice: String) -> String {
        isSupertonicVoice(voice) ? supertonic : kokoro
    }

    static func resolvedEngine(voice: String?, requested: String?) -> String? {
        guard let voice, isSupertonicVoice(voice) else { return requested }
        return supertonic
    }
}

nonisolated struct SpeechEngineVoice: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let gender: String
}

nonisolated struct SpeechEngine: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let installed: Bool
    let downloading: Bool
    let progress: Double
    let sizeBytes: Int64
    let license: String
    let languages: [String]
    let voices: [SpeechEngineVoice]
    let error: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case installed
        case downloading
        case progress
        case sizeBytes = "size_bytes"
        case license
        case languages
        case voices
        case error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        installed = try container.decode(Bool.self, forKey: .installed)
        downloading = try container.decodeIfPresent(Bool.self, forKey: .downloading) ?? false
        progress = try container.decodeIfPresent(Double.self, forKey: .progress) ?? 0
        sizeBytes = try container.decodeIfPresent(Int64.self, forKey: .sizeBytes) ?? 0
        license = try container.decodeIfPresent(String.self, forKey: .license) ?? ""
        languages = try container.decodeIfPresent([String].self, forKey: .languages) ?? []
        voices = (try? container.decodeIfPresent([SpeechEngineVoice].self, forKey: .voices)) ?? []
        error = try container.decodeIfPresent(String.self, forKey: .error)
    }

    init(
        id: String,
        name: String,
        installed: Bool,
        downloading: Bool = false,
        progress: Double = 0,
        sizeBytes: Int64 = 0,
        license: String = "",
        languages: [String] = [],
        voices: [SpeechEngineVoice] = [],
        error: String? = nil
    ) {
        self.id = id
        self.name = name
        self.installed = installed
        self.downloading = downloading
        self.progress = progress
        self.sizeBytes = sizeBytes
        self.license = license
        self.languages = languages
        self.voices = voices
        self.error = error
    }

    var isBuiltIn: Bool {
        id == SpeechEngineID.kokoro
    }

    var clampedProgress: Double {
        min(max(progress, 0), 1)
    }

    var sizeDescription: String? {
        sizeBytes > 0 ? ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file) : nil
    }
}

nonisolated struct SpeechEngineList: Decodable, Equatable, Sendable {
    let engines: [SpeechEngine]

    init(engines: [SpeechEngine]) {
        self.engines = engines
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        engines = try container.decodeIfPresent([LossyEngine].self, forKey: .engines)?.compactMap(\.engine) ?? []
    }

    enum CodingKeys: String, CodingKey {
        case engines
    }

    private struct LossyEngine: Decodable {
        let engine: SpeechEngine?

        init(from decoder: Decoder) throws {
            engine = try? SpeechEngine(from: decoder)
        }
    }
}

nonisolated enum SpeechEngineCatalog {
    static let fallbackVoice = "af_bella"

    static func engine(_ id: String, in engines: [SpeechEngine]) -> SpeechEngine? {
        engines.first { $0.id == id }
    }

    static func installedVoices(for id: String, in engines: [SpeechEngine]) -> [SpeechEngineVoice] {
        guard let engine = engine(id, in: engines), engine.installed else { return [] }
        return engine.voices
    }

    static func isAvailable(voice: String, in engines: [SpeechEngine]) -> Bool {
        guard SpeechEngineID.isSupertonicVoice(voice) else { return true }
        return installedVoices(for: SpeechEngineID.supertonic, in: engines).contains { $0.id == voice }
    }

    static func resolve(voice: String, in engines: [SpeechEngine]) -> String {
        isAvailable(voice: voice, in: engines) ? voice : fallbackVoice
    }

    static func displayName(forVoice voice: String, in engines: [SpeechEngine] = []) -> String? {
        guard SpeechEngineID.isSupertonicVoice(voice) else { return nil }
        if let known = engine(SpeechEngineID.supertonic, in: engines)?.voices.first(where: { $0.id == voice }) {
            return "Supertonic \(known.name)"
        }
        let style = voice.dropFirst(SpeechEngineID.supertonicVoicePrefix.count)
        return style.isEmpty ? "Supertonic" : "Supertonic \(style)"
    }
}
