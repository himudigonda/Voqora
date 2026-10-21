import Foundation

nonisolated enum SpeechEngineID {
    static let kokoro = "kokoro"
    static let supertonic = "supertonic"
    static let supertonicVoicePrefix = "supertonic:"
    static let ming = "ming"
    static let mingVoicePrefix = "ming:"
    static let mingCustomVoicePrefix = "ming:custom:"

    static let downloadable = [supertonic, ming]

    static func voicePrefix(forEngine engine: String) -> String {
        "\(engine):"
    }

    static func isSupertonicVoice(_ voice: String) -> Bool {
        voice.hasPrefix(supertonicVoicePrefix)
    }

    static func isMingVoice(_ voice: String) -> Bool {
        voice.hasPrefix(mingVoicePrefix)
    }

    static func isCustomMingVoice(_ voice: String) -> Bool {
        voice.hasPrefix(mingCustomVoicePrefix)
    }

    static func downloadableEngine(forVoice voice: String) -> String? {
        downloadable.first { voice.hasPrefix(voicePrefix(forEngine: $0)) }
    }

    static func isDownloadableEngineVoice(_ voice: String) -> Bool {
        downloadableEngine(forVoice: voice) != nil
    }

    static func engine(forVoice voice: String) -> String {
        downloadableEngine(forVoice: voice) ?? kokoro
    }

    static func resolvedEngine(voice: String?, requested: String?) -> String? {
        guard let voice else { return requested }
        if let engine = downloadableEngine(forVoice: voice) {
            return engine
        }
        return requested.flatMap { downloadable.contains($0) ? nil : $0 }
    }
}

nonisolated enum MingVoiceGroup: String, CaseIterable, Sendable {
    case english
    case chinese
    case mine

    var title: String {
        switch self {
        case .english: "Ming · English"
        case .chinese: "Ming · Chinese"
        case .mine: "Ming · My voices"
        }
    }
}

nonisolated struct SpeechEngineVoice: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let gender: String
    let lang: String
    let description: String?
    let emotions: [String]
    let custom: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case gender
        case lang
        case description
        case emotions
        case custom
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        gender = try container.decodeIfPresent(String.self, forKey: .gender) ?? ""
        lang = try container.decodeIfPresent(String.self, forKey: .lang) ?? ""
        description = try container.decodeIfPresent(String.self, forKey: .description)
        emotions = (try? container.decodeIfPresent([String].self, forKey: .emotions)) ?? []
        custom = try container.decodeIfPresent(Bool.self, forKey: .custom) ?? SpeechEngineID.isCustomMingVoice(id)
    }

    init(
        id: String,
        name: String,
        gender: String,
        lang: String = "",
        description: String? = nil,
        emotions: [String] = [],
        custom: Bool = false
    ) {
        self.id = id
        self.name = name
        self.gender = gender
        self.lang = lang
        self.description = description
        self.emotions = emotions
        self.custom = custom
    }

    var isChinese: Bool {
        lang.lowercased().hasPrefix("zh")
    }

    var mingGroup: MingVoiceGroup {
        if custom {
            return .mine
        }
        return isChinese ? .chinese : .english
    }
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
    let notice: String?
    let capabilities: [String]

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
        case notice
        case capabilities
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
        notice = try container.decodeIfPresent(String.self, forKey: .notice)
        capabilities = (try? container.decodeIfPresent([String].self, forKey: .capabilities)) ?? []
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
        error: String? = nil,
        notice: String? = nil,
        capabilities: [String] = []
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
        self.notice = notice
        self.capabilities = capabilities
    }

    var trimmedNotice: String? {
        let trimmed = notice?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    func supports(_ capability: String) -> Bool {
        capabilities.contains(capability)
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

    static func voice(_ id: String, in engines: [SpeechEngine]) -> SpeechEngineVoice? {
        guard let engineID = SpeechEngineID.downloadableEngine(forVoice: id) else { return nil }
        return installedVoices(for: engineID, in: engines).first { $0.id == id }
    }

    static func isAvailable(voice: String, in engines: [SpeechEngine]) -> Bool {
        guard let engineID = SpeechEngineID.downloadableEngine(forVoice: voice) else { return true }
        return installedVoices(for: engineID, in: engines).contains { $0.id == voice }
    }

    static func resolve(voice: String, in engines: [SpeechEngine]) -> String {
        isAvailable(voice: voice, in: engines) ? voice : fallbackVoice
    }

    static func displayName(
        forVoice voice: String,
        in engines: [SpeechEngine] = [],
        directory: EngineVoiceDirectory? = nil
    ) -> String? {
        guard let engineID = SpeechEngineID.downloadableEngine(forVoice: voice) else { return nil }
        let engineName = engineID == SpeechEngineID.ming ? "Ming" : "Supertonic"
        if let known = self.voice(voice, in: engines) {
            return known.custom ? known.name : "\(engineName) \(known.name)"
        }
        if let remembered = directory?.summary(for: voice) {
            return remembered.custom ? remembered.name : "\(engineName) \(remembered.name)"
        }
        if SpeechEngineID.isCustomMingVoice(voice) {
            return "\(engineName) custom voice"
        }
        let suffix = voice.dropFirst(SpeechEngineID.voicePrefix(forEngine: engineID).count)
        let label = engineID == SpeechEngineID.ming ? suffix.split(separator: "_").last.map(String.init) ?? "" : String(suffix)
        return label.isEmpty ? engineName : "\(engineName) \(label)"
    }
}
