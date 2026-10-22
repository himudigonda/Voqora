import Foundation

nonisolated enum MyVoiceKind: String, Hashable {
    case blend
    case designed
    case cloned

    var title: String {
        switch self {
        case .blend: "Blend"
        case .designed: "Designed"
        case .cloned: "Cloned"
        }
    }
}

nonisolated struct MyVoiceItem: Identifiable, Hashable {
    let id: String
    let name: String
    let kind: MyVoiceKind
    let supporting: String
    let blend: VoiceBlend?
    let mingVoice: SpeechEngineVoice?
}

enum MyVoiceItems {
    static func make(blends: [VoiceBlend], mingVoices: [SpeechEngineVoice]) -> [MyVoiceItem] {
        let blendItems = blends.map { blend in
            MyVoiceItem(id: blend.id, name: blend.name, kind: .blend, supporting: blendSummary(blend), blend: blend, mingVoice: nil)
        }
        let mingItems = mingVoices.filter(\.custom).map { voice in
            MyVoiceItem(id: voice.id, name: voice.name, kind: kind(of: voice), supporting: supporting(for: voice), blend: nil, mingVoice: voice)
        }
        return blendItems + mingItems
    }

    static func blendSummary(_ blend: VoiceBlend) -> String {
        blend.components
            .map { "\(DashboardViewModel.voiceName(for: $0.voice)) \(Int(($0.normalizedWeight * 100).rounded()))%" }
            .joined(separator: " · ")
    }

    static func kind(of voice: SpeechEngineVoice) -> MyVoiceKind {
        let description = voice.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return description.isEmpty ? .cloned : .designed
    }

    static func supporting(for voice: SpeechEngineVoice) -> String {
        let language = MingVoiceLanguage.label(voice.lang)
        switch kind(of: voice) {
        case .designed: return voice.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? language
        case .cloned: return voice.lang.isEmpty ? "Cloned" : "Cloned · \(language)"
        case .blend: return language
        }
    }

    static func deletionWarning(for item: MyVoiceItem) -> String {
        if let blend = item.blend {
            return "Anything set to \(blend.name) switches to \(DashboardViewModel.voiceName(for: blend.fallbackVoice)), including audiobooks still being narrated."
        }
        return "Anything set to \(item.name) switches to Bella."
    }
}

enum NewVoiceSheet: Identifiable {
    case chooser
    case blend(VoiceBlend?)
    case describe
    case clone

    var id: String {
        switch self {
        case .chooser: "chooser"
        case let .blend(blend): "blend.\(blend?.id ?? "new")"
        case .describe: "describe"
        case .clone: "clone"
        }
    }
}
