import Foundation

enum OnboardingStep: Int, CaseIterable, Identifiable {
    case welcome
    case privacy
    case permissions
    case engine
    case voice
    case shortcuts
    case dictation
    case audiobooks
    case ai
    case appearance
    case done

    var id: Int {
        rawValue
    }

    var key: String {
        switch self {
        case .welcome: "welcome"
        case .privacy: "privacy"
        case .permissions: "permissions"
        case .engine: "engine"
        case .voice: "voice"
        case .shortcuts: "shortcuts"
        case .dictation: "dictation"
        case .audiobooks: "audiobooks"
        case .ai: "ai"
        case .appearance: "appearance"
        case .done: "done"
        }
    }

    var railTitle: String {
        switch self {
        case .welcome: "Welcome"
        case .privacy: "Privacy"
        case .permissions: "Permissions"
        case .engine: "Speech Engine"
        case .voice: "Voice"
        case .shortcuts: "Shortcuts"
        case .dictation: "Dictation"
        case .audiobooks: "Audiobooks"
        case .ai: "AI Provider"
        case .appearance: "Appearance"
        case .done: "Finish"
        }
    }

    var systemImage: String {
        switch self {
        case .welcome: "hand.wave.fill"
        case .privacy: "lock.shield.fill"
        case .permissions: "hand.tap.fill"
        case .engine: "cpu.fill"
        case .voice: "waveform"
        case .shortcuts: "command"
        case .dictation: "mic.fill"
        case .audiobooks: "books.vertical.fill"
        case .ai: "sparkles"
        case .appearance: "paintpalette.fill"
        case .done: "checkmark.seal.fill"
        }
    }

    var group: String {
        switch self {
        case .welcome, .privacy, .permissions: Self.groups[0]
        case .engine, .voice, .shortcuts, .dictation, .audiobooks, .ai: Self.groups[1]
        case .appearance, .done: Self.groups[2]
        }
    }

    var isOptional: Bool {
        switch self {
        case .privacy, .dictation, .audiobooks, .ai: true
        default: false
        }
    }

    static let groups = ["Get started", "Set up", "Make it yours"]

    init?(key: String) {
        guard let match = Self.allCases.first(where: { $0.key == key }) else { return nil }
        self = match
    }

    static func clamped(_ raw: Int) -> OnboardingStep {
        OnboardingStep(rawValue: min(max(0, raw), allCases.count - 1)) ?? .welcome
    }

    static func firstUnseen(in seen: Set<String>) -> OnboardingStep {
        allCases.first { !seen.contains($0.key) } ?? .welcome
    }

    func nextUnseen(in seen: Set<String>) -> OnboardingStep {
        let later = Self.allCases.filter { $0.rawValue > rawValue }
        return later.first { !seen.contains($0.key) } ?? later.first ?? self
    }
}
