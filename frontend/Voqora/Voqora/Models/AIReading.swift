import Foundation

nonisolated enum AILanguage: String, CaseIterable, Identifiable, Sendable {
    case englishUS = "en-us"
    case englishUK = "en-gb"
    case spanish = "es"
    case french = "fr-fr"
    case italian = "it"
    case portuguese = "pt-br"
    case hindi = "hi"
    case mandarin = "cmn"

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .englishUS: "English (US)"
        case .englishUK: "English (UK)"
        case .spanish: "Spanish"
        case .french: "French"
        case .italian: "Italian"
        case .portuguese: "Portuguese"
        case .hindi: "Hindi"
        case .mandarin: "Mandarin"
        }
    }

    var isEnglish: Bool {
        self == .englishUS || self == .englishUK
    }

    init?(localeIdentifier: String) {
        let normalized = localeIdentifier.lowercased().replacingOccurrences(of: "_", with: "-")
        let base = normalized.split(separator: "-").first.map(String.init) ?? normalized
        switch base {
        case "en": self = normalized.hasPrefix("en-gb") ? .englishUK : .englishUS
        case "es": self = .spanish
        case "fr": self = .french
        case "it": self = .italian
        case "pt": self = .portuguese
        case "hi": self = .hindi
        case "zh", "cmn": self = .mandarin
        default: return nil
        }
    }
}

nonisolated enum AISummaryLength: String, CaseIterable, Identifiable, Sendable {
    case short
    case medium
    case detailed

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .short: "Short"
        case .medium: "Medium"
        case .detailed: "Detailed"
        }
    }
}

nonisolated enum AIQuizDifficulty: String, CaseIterable, Identifiable, Sendable {
    case easy
    case medium
    case hard

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .easy: "Easy"
        case .medium: "Medium"
        case .hard: "Hard"
        }
    }
}

nonisolated enum AISource: Equatable, Sendable {
    case text(String)
    case book(String)
}

nonisolated enum AIChatRole: String, Codable, Sendable {
    case user
    case assistant
}

nonisolated struct AIChatTurn: Codable, Equatable, Sendable {
    let role: AIChatRole
    let content: String
}

nonisolated struct AIUsage: Decodable, Equatable, Sendable {
    let tokens: Int
    let tokensEstimated: Bool
    let costUSD: Double?
    let provider: String
    let model: String

    enum CodingKeys: String, CodingKey {
        case tokens
        case tokensEstimated = "tokens_estimated"
        case costUSD = "cost_usd"
        case provider
        case model
    }
}

nonisolated struct AISummary: Equatable, Sendable {
    let summary: String
    let usage: AIUsage
}

nonisolated struct AITranslation: Equatable, Sendable {
    let text: String
    let detectedSourceLanguage: String?
    let usage: AIUsage
}

nonisolated struct AICitation: Codable, Hashable, Sendable {
    let sectionTitle: String?
    let page: Int
    let passageIndex: Int
    let quote: String

    enum CodingKeys: String, CodingKey {
        case sectionTitle = "section_title"
        case page
        case passageIndex = "passage_index"
        case quote
    }
}

nonisolated struct AIAnswer: Equatable, Sendable {
    let answer: String
    let found: Bool
    let citations: [AICitation]
    let usage: AIUsage
}

nonisolated struct AIQuizQuestion: Codable, Equatable, Sendable {
    let question: String
    let choices: [String]
    let answerIndex: Int
    let explanation: String

    enum CodingKeys: String, CodingKey {
        case question
        case choices
        case answerIndex = "answer_index"
        case explanation
    }

    var isWellFormed: Bool {
        choices.count >= 2 && choices.indices.contains(answerIndex)
    }
}

nonisolated struct AIQuiz: Equatable, Sendable {
    let questions: [AIQuizQuestion]
    let usage: AIUsage
}

nonisolated struct AIFlashcard: Codable, Equatable, Sendable {
    let front: String
    let back: String
}

nonisolated struct AIFlashcardDeck: Equatable, Sendable {
    let cards: [AIFlashcard]
    let usage: AIUsage
}

nonisolated extension AISummary: Decodable {
    private enum CodingKeys: String, CodingKey {
        case summary
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(summary: container.decode(String.self, forKey: .summary), usage: AIUsage(from: decoder))
    }
}

nonisolated extension AITranslation: Decodable {
    private enum CodingKeys: String, CodingKey {
        case text
        case detectedSourceLanguage = "detected_source_language"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            text: container.decode(String.self, forKey: .text),
            detectedSourceLanguage: container.decodeIfPresent(String.self, forKey: .detectedSourceLanguage),
            usage: AIUsage(from: decoder)
        )
    }
}

nonisolated extension AIAnswer: Decodable {
    private enum CodingKeys: String, CodingKey {
        case answer
        case found
        case citations
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            answer: container.decode(String.self, forKey: .answer),
            found: container.decodeIfPresent(Bool.self, forKey: .found) ?? true,
            citations: container.decodeIfPresent([AICitation].self, forKey: .citations) ?? [],
            usage: AIUsage(from: decoder)
        )
    }
}

nonisolated extension AIQuiz: Decodable {
    private enum CodingKeys: String, CodingKey {
        case questions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            questions: container.decode([AIQuizQuestion].self, forKey: .questions).filter(\.isWellFormed),
            usage: AIUsage(from: decoder)
        )
    }
}

nonisolated extension AIFlashcardDeck: Decodable {
    private enum CodingKeys: String, CodingKey {
        case cards
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(cards: container.decode([AIFlashcard].self, forKey: .cards), usage: AIUsage(from: decoder))
    }
}
