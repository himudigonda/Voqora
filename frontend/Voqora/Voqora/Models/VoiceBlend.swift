import Foundation

nonisolated enum VoiceBlendRules {
    static let idPrefix = "blend:"
    static let minComponents = 2
    static let maxComponents = 4
    static let minWeight = 0.05
    static let maxWeight = 1.0
    static let defaultWeight = 0.5
    static let maxNameLength = 40
    static let fallbackVoice = "af_bella"

    static func isBlendID(_ id: String) -> Bool {
        guard id.hasPrefix(idPrefix) else { return false }
        let uuid = String(id.dropFirst(idPrefix.count))
        return uuid.count == 36 && uuid == uuid.lowercased() && UUID(uuidString: uuid) != nil
    }

    static func telemetryVoice(_ id: String) -> String {
        isBlendID(id) ? "blend" : id
    }
}

nonisolated struct VoiceBlendComponent: Codable, Hashable, Sendable {
    let voice: String
    let weight: Double
    let normalizedWeight: Double

    enum CodingKeys: String, CodingKey {
        case voice
        case weight
        case normalizedWeight = "normalized_weight"
    }
}

nonisolated struct VoiceBlend: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let lang: String
    let version: Int
    let components: [VoiceBlendComponent]
    let createdAt: String
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case lang
        case version
        case components
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    var fallbackVoice: String {
        components.first?.voice ?? VoiceBlendRules.fallbackVoice
    }
}

nonisolated struct VoiceBlendList: Decodable, Sendable {
    let blends: [VoiceBlend]
    let maxBlends: Int

    enum CodingKeys: String, CodingKey {
        case blends
        case maxBlends = "max_blends"
    }
}

nonisolated struct VoiceBlendRequest: Encodable, Equatable, Sendable {
    nonisolated struct Component: Encodable, Equatable, Sendable {
        let voice: String
        let weight: Double
    }

    let name: String
    let components: [Component]
}

nonisolated struct VoiceBlendPreviewRequest: Encodable, Equatable, Sendable {
    let components: [String]
    let weights: [Double]
    var text: String?
    var lang: String?
}

nonisolated struct VoiceBlendDraft: Equatable, Sendable {
    nonisolated struct Component: Identifiable, Equatable, Sendable {
        let id: UUID
        var voice: String
        var weight: Double

        init(id: UUID = UUID(), voice: String, weight: Double) {
            self.id = id
            self.voice = voice
            self.weight = weight
        }
    }

    var name: String
    var components: [Component]

    init(name: String = "", components: [Component]? = nil) {
        self.name = name
        self.components = components ?? [
            Component(voice: "af_bella", weight: VoiceBlendRules.defaultWeight),
            Component(voice: "af_sarah", weight: VoiceBlendRules.defaultWeight),
        ]
    }

    init(blend: VoiceBlend) {
        name = blend.name
        components = blend.components.map { Component(voice: $0.voice, weight: $0.weight) }
    }

    var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var canAddComponent: Bool {
        components.count < VoiceBlendRules.maxComponents && nextUnusedVoice != nil
    }

    var canRemoveComponent: Bool {
        components.count > VoiceBlendRules.minComponents
    }

    var validationMessage: String? {
        let name = trimmedName
        if name.isEmpty {
            return "Give your voice a name."
        }
        if name.scalarCount > VoiceBlendRules.maxNameLength {
            return "Keep the name to \(VoiceBlendRules.maxNameLength) characters or fewer."
        }
        if name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            return "The name can't contain control characters."
        }
        return componentsMessage
    }

    var componentsMessage: String? {
        if !(VoiceBlendRules.minComponents ... VoiceBlendRules.maxComponents).contains(components.count) {
            return "Mix \(VoiceBlendRules.minComponents) to \(VoiceBlendRules.maxComponents) voices."
        }
        let voices = components.map(\.voice)
        if Set(voices).count != voices.count {
            return "Each voice can appear only once in a blend."
        }
        let builtIn = Set(DashboardViewModel.voiceCatalog.map(\.id))
        if voices.contains(where: { !builtIn.contains($0) }) {
            return "Blends can only mix built-in voices."
        }
        if components.contains(where: { !(VoiceBlendRules.minWeight ... VoiceBlendRules.maxWeight).contains($0.weight) }) {
            return "Each weight must be between 5% and 100%."
        }
        return nil
    }

    var isPreviewable: Bool {
        componentsMessage == nil
    }

    var isValid: Bool {
        validationMessage == nil
    }

    var request: VoiceBlendRequest {
        VoiceBlendRequest(
            name: trimmedName,
            components: components.map { VoiceBlendRequest.Component(voice: $0.voice, weight: Self.rounded($0.weight)) }
        )
    }

    var previewRequest: VoiceBlendPreviewRequest {
        VoiceBlendPreviewRequest(
            components: components.map(\.voice),
            weights: components.map { Self.rounded($0.weight) }
        )
    }

    func share(of component: Component) -> Double {
        let total = components.reduce(0) { $0 + $1.weight }
        guard total > 0 else { return 0 }
        return component.weight / total
    }

    var nextUnusedVoice: String? {
        let used = Set(components.map(\.voice))
        return DashboardViewModel.voiceCatalog.first { !used.contains($0.id) }?.id
    }

    mutating func addComponent() {
        guard canAddComponent, let voice = nextUnusedVoice else { return }
        components.append(Component(voice: voice, weight: VoiceBlendRules.defaultWeight))
    }

    mutating func removeComponent(_ id: UUID) {
        guard canRemoveComponent else { return }
        components.removeAll { $0.id == id }
    }

    private static func rounded(_ weight: Double) -> Double {
        (weight * 100).rounded() / 100
    }
}
