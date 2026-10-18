import Foundation

nonisolated enum PodcastLimits {
    static let speakers = 1 ... 4
    static let turns = 1 ... 600
    static let turnCharacters = 2000
    static let titleCharacters = 200
    static let speakerNameCharacters = 60
    static let sectionCharacters = 120
    static let pauseSeconds = 0.0 ... 3.0
    static let defaultPauseSeconds = 0.4
    static let minutes = 2 ... 30
    static let defaultMinutes = 8
    static let sourceCharacters = 384_000
    static let hosts = 1 ... 2
    static let wordsPerSecond = 2.75
    static let speakerIDPattern = "^[A-Za-z0-9_-]{1,32}$"

    static func length(of text: String) -> Int {
        text.unicodeScalars.count
    }
}

nonisolated struct PodcastSpeaker: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var voice: String
}

nonisolated struct PodcastTurn: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    var speakerID: String
    var text: String
    var pauseAfterSeconds: Double
    var section: String?

    init(
        id: UUID = UUID(),
        speakerID: String,
        text: String,
        pauseAfterSeconds: Double = PodcastLimits.defaultPauseSeconds,
        section: String? = nil
    ) {
        self.id = id
        self.speakerID = speakerID
        self.text = text
        self.pauseAfterSeconds = pauseAfterSeconds
        self.section = section
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = UUID()
        speakerID = try container.decode(String.self, forKey: .speakerID)
        text = try container.decode(String.self, forKey: .text)
        pauseAfterSeconds = try container.decodeIfPresent(Double.self, forKey: .pauseAfterSeconds)
            ?? PodcastLimits.defaultPauseSeconds
        section = try container.decodeIfPresent(String.self, forKey: .section)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(speakerID, forKey: .speakerID)
        try container.encode(text, forKey: .text)
        try container.encode(pauseAfterSeconds, forKey: .pauseAfterSeconds)
        try container.encodeIfPresent(section, forKey: .section)
    }

    enum CodingKeys: String, CodingKey {
        case speakerID = "speaker_id"
        case text
        case pauseAfterSeconds = "pause_after_seconds"
        case section
    }
}

nonisolated struct PodcastScript: Codable, Hashable, Sendable {
    var title: String
    var speakers: [PodcastSpeaker]
    var turns: [PodcastTurn]

    static func blank(firstVoice: String, secondVoice: String) -> PodcastScript {
        let speakers = [
            PodcastSpeaker(id: "host_1", name: "Host 1", voice: firstVoice),
            PodcastSpeaker(id: "host_2", name: "Host 2", voice: secondVoice),
        ]
        return PodcastScript(
            title: "Untitled Script",
            speakers: speakers,
            turns: [PodcastTurn(speakerID: speakers[0].id, text: "")]
        )
    }

    func speaker(withID id: String) -> PodcastSpeaker? {
        speakers.first { $0.id == id }
    }

    var wordCount: Int {
        turns.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
    }

    var estimatedAudioSeconds: Double {
        Double(wordCount) / PodcastLimits.wordsPerSecond + turns.reduce(0) { $0 + $1.pauseAfterSeconds }
    }

    func nextSpeakerID() -> String {
        let taken = Set(speakers.map(\.id))
        var index = speakers.count + 1
        while taken.contains("host_\(index)") {
            index += 1
        }
        return "host_\(index)"
    }

    func normalizedForRender() -> PodcastScript {
        PodcastScript(
            title: PodcastText.singleLine(title),
            speakers: speakers.map {
                PodcastSpeaker(id: $0.id, name: PodcastText.singleLine($0.name), voice: $0.voice)
            },
            turns: turns.map { turn in
                let section = turn.section.map(PodcastText.singleLine)
                return PodcastTurn(
                    id: turn.id,
                    speakerID: turn.speakerID,
                    text: turn.text.trimmingCharacters(in: .whitespacesAndNewlines),
                    pauseAfterSeconds: min(max(turn.pauseAfterSeconds, 0), PodcastLimits.pauseSeconds.upperBound),
                    section: section?.isEmpty == false ? section : nil
                )
            }
        )
    }
}

nonisolated enum PodcastText {
    static func singleLine(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

nonisolated enum PodcastStyle: String, CaseIterable, Identifiable, Codable, Sendable {
    case deepDive = "deep_dive"
    case brief
    case debate
    case lecture

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .deepDive: "Deep Dive"
        case .brief: "Brief"
        case .debate: "Debate"
        case .lecture: "Lecture"
        }
    }

    var summary: String {
        switch self {
        case .deepDive: "A relaxed conversation that explores the ideas in depth."
        case .brief: "A quick rundown of the key points."
        case .debate: "Two hosts argue different sides."
        case .lecture: "One host teaches the material."
        }
    }

    var allowedHostCounts: ClosedRange<Int> {
        switch self {
        case .deepDive, .brief: 1 ... 2
        case .debate: 2 ... 2
        case .lecture: 1 ... 1
        }
    }
}

nonisolated enum PodcastLanguage: String, CaseIterable, Identifiable, Codable, Sendable {
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
        case .mandarin: "Mandarin (Beta)"
        }
    }

    var baseCode: String {
        Self.baseCode(of: rawValue)
    }

    static func baseCode(of code: String) -> String {
        String(code.split(separator: "-").first ?? Substring(code))
    }
}

nonisolated struct PodcastHost: Codable, Hashable, Sendable {
    var name: String
    var voice: String
}

nonisolated enum PodcastSource: Hashable, Sendable {
    case text(String)
    case book(String)
}

nonisolated struct PodcastScriptRequest: Encodable, Hashable, Sendable {
    let source: PodcastSource
    let style: PodcastStyle
    let minutes: Int
    let language: PodcastLanguage
    let hosts: [PodcastHost]
    let title: String?

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        var sourceContainer = container.nestedContainer(keyedBy: SourceKeys.self, forKey: .source)
        switch source {
        case let .text(text): try sourceContainer.encode(text, forKey: .text)
        case let .book(bookID): try sourceContainer.encode(bookID, forKey: .bookID)
        }
        try container.encode(style, forKey: .style)
        try container.encode(minutes, forKey: .minutes)
        try container.encode(language, forKey: .language)
        try container.encode(hosts, forKey: .hosts)
        try container.encodeIfPresent(title, forKey: .title)
    }

    private enum CodingKeys: String, CodingKey {
        case source, style, minutes, language, hosts, title
    }

    private enum SourceKeys: String, CodingKey {
        case text
        case bookID = "book_id"
    }
}

nonisolated struct PodcastScriptResult: Decodable, Hashable, Sendable {
    let script: PodcastScript
    let usedNotes: Bool
    let repaired: Bool
    let sourceTruncated: Bool
    let estimatedAudioSeconds: Double
    let llmProvider: String
    let llmModel: String

    enum CodingKeys: String, CodingKey {
        case script
        case usedNotes = "used_notes"
        case repaired
        case sourceTruncated = "source_truncated"
        case estimatedAudioSeconds = "estimated_audio_seconds"
        case llmProvider = "llm_provider"
        case llmModel = "llm_model"
    }
}

nonisolated struct PodcastRenderRequest: Encodable, Sendable {
    let script: PodcastScript
}

nonisolated struct PodcastRenderReceipt: Decodable, Hashable, Sendable {
    let status: String
    let bookID: String
    let kind: String
    let title: String
    let turnCount: Int
    let speakers: [PodcastSpeaker]
    let estimatedAudioSeconds: Double

    enum CodingKeys: String, CodingKey {
        case status
        case bookID = "book_id"
        case kind, title
        case turnCount = "turn_count"
        case speakers
        case estimatedAudioSeconds = "estimated_audio_seconds"
    }
}

nonisolated struct PodcastVoiceBlend: Decodable, Hashable, Identifiable, Sendable {
    let id: String
    let name: String
    let lang: String
}

nonisolated struct PodcastVoiceBlendList: Decodable, Sendable {
    let blends: [PodcastVoiceBlend]
}

nonisolated struct PodcastSpeechPreviewRequest: Encodable, Sendable {
    let text: String
    let voice: String
}
