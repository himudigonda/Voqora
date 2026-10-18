import Foundation

final nonisolated class VoiceBlendDirectory: @unchecked Sendable {
    nonisolated struct Summary: Codable, Equatable, Sendable {
        let name: String
        let fallbackVoice: String
    }

    static let shared = VoiceBlendDirectory(defaults: .standard)
    static let defaultsKey = "voiceBlendDirectory"

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

    func name(for id: String) -> String? {
        summary(for: id)?.name
    }

    func fallbackVoice(for id: String) -> String? {
        summary(for: id)?.fallbackVoice
    }

    func record(_ blends: [VoiceBlend]) {
        let snapshot: [String: Summary] = lock.withLock {
            for blend in blends {
                summaries[blend.id] = Summary(name: blend.name, fallbackVoice: blend.fallbackVoice)
            }
            return summaries
        }
        save(snapshot)
    }

    private func save(_ snapshot: [String: Summary]) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    private static func load(from defaults: UserDefaults) -> [String: Summary] {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([String: Summary].self, from: data)
        else { return [:] }
        return decoded.filter { VoiceBlendRules.isBlendID($0.key) && !VoiceBlendRules.isBlendID($0.value.fallbackVoice) }
    }
}

nonisolated enum VoiceSelectionResolver {
    static func resolve(
        _ voice: String,
        liveBlendIDs: Set<String>,
        directory: VoiceBlendDirectory
    ) -> String {
        guard VoiceBlendRules.isBlendID(voice) else { return voice }
        if liveBlendIDs.contains(voice) {
            return voice
        }
        return directory.fallbackVoice(for: voice) ?? VoiceBlendRules.fallbackVoice
    }
}
