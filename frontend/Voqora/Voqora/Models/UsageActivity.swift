import Foundation

nonisolated enum SpeechSource: String, CaseIterable, Codable, Sendable {
    case selection
    case clipboard
    case screen
    case shortcut
    case inbox
    case history
    case ai
    case relay
    case sample
    case reader
    case app

    @TaskLocal static var current: SpeechSource = .app

    var title: String {
        switch self {
        case .selection: "Selected Text"
        case .clipboard: "Clipboard"
        case .screen: "Screen Text"
        case .shortcut: "Shortcuts"
        case .inbox: "Inbox"
        case .history: "History"
        case .ai: "AI Answers"
        case .relay: "Apps & Agents"
        case .sample: "Voice Previews"
        case .reader: "Reader"
        case .app: "In App"
        }
    }
}

nonisolated enum LatencyBuckets {
    static let edgesMs: [Double] = [250, 500, 1000, 2000, 4000]
    static let labels = ["<250 ms", "<0.5 s", "<1 s", "<2 s", "<4 s", "4 s+"]

    static func index(forMs ms: Double) -> Int {
        edgesMs.firstIndex { ms < $0 } ?? edgesMs.count
    }
}

nonisolated enum DictationLengthBuckets {
    static let edges = [10, 25, 50, 100, 250]
    static let labels = ["<10", "10–24", "25–49", "50–99", "100–249", "250+"]

    static func index(forWords words: Int) -> Int {
        edges.firstIndex { words < $0 } ?? edges.count
    }
}

private extension KeyedDecodingContainer {
    func value<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }

    func buckets(_ key: Key, count: Int) -> [Int] {
        let stored = (try? decodeIfPresent([Int].self, forKey: key)) ?? []
        return stored.count == count ? stored : Array(repeating: 0, count: count)
    }
}

private nonisolated func merged<V>(_ lhs: [String: V], _ rhs: [String: V], _ add: (V, V) -> V) -> [String: V] {
    lhs.merging(rhs, uniquingKeysWith: add)
}

struct EngineUsage: Codable, Equatable {
    var uses = 0
    var words = 0
    var audioSeconds: Double = 0
    var renderSeconds: Double = 0
    var firstAudioCount = 0
    var firstAudioMsTotal: Double = 0
    var firstAudioBuckets = Array(repeating: 0, count: LatencyBuckets.labels.count)
    var failures = 0

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uses = c.value(.uses, 0)
        words = c.value(.words, 0)
        audioSeconds = c.value(.audioSeconds, 0)
        renderSeconds = c.value(.renderSeconds, 0)
        firstAudioCount = c.value(.firstAudioCount, 0)
        firstAudioMsTotal = c.value(.firstAudioMsTotal, 0)
        firstAudioBuckets = c.buckets(.firstAudioBuckets, count: LatencyBuckets.labels.count)
        failures = c.value(.failures, 0)
    }

    var averageFirstAudioMs: Double? {
        firstAudioCount > 0 ? firstAudioMsTotal / Double(firstAudioCount) : nil
    }

    var realTimeFactor: Double? {
        renderSeconds > 0 && audioSeconds > 0 ? audioSeconds / renderSeconds : nil
    }

    static func + (lhs: EngineUsage, rhs: EngineUsage) -> EngineUsage {
        var out = lhs
        out.uses += rhs.uses
        out.words += rhs.words
        out.audioSeconds += rhs.audioSeconds
        out.renderSeconds += rhs.renderSeconds
        out.firstAudioCount += rhs.firstAudioCount
        out.firstAudioMsTotal += rhs.firstAudioMsTotal
        out.firstAudioBuckets = zip(lhs.firstAudioBuckets, rhs.firstAudioBuckets).map(+)
        out.failures += rhs.failures
        return out
    }
}

struct SpeechDetail: Codable, Equatable {
    var sources: [String: Int] = [:]
    var engines: [String: EngineUsage] = [:]
    var relayClients: [String: Int] = [:]
    var failures = 0

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sources = c.value(.sources, [:])
        engines = c.value(.engines, [:])
        relayClients = c.value(.relayClients, [:])
        failures = c.value(.failures, 0)
    }

    static func + (lhs: SpeechDetail, rhs: SpeechDetail) -> SpeechDetail {
        var out = SpeechDetail()
        out.sources = merged(lhs.sources, rhs.sources, +)
        out.engines = merged(lhs.engines, rhs.engines, +)
        out.relayClients = merged(lhs.relayClients, rhs.relayClients, +)
        out.failures = lhs.failures + rhs.failures
        return out
    }
}

struct DictationUsage: Codable, Equatable {
    var sessions = 0
    var words = 0
    var chars = 0
    var seconds: Double = 0
    var timedWords = 0
    var cancelled = 0
    var tidied = 0
    var outcomes: [String: Int] = [:]
    var languages: [String: Int] = [:]
    var apps: [String: Int] = [:]
    var hours: [Double] = Array(repeating: 0, count: 24)
    var lengths = Array(repeating: 0, count: DictationLengthBuckets.labels.count)

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessions = c.value(.sessions, 0)
        words = c.value(.words, 0)
        chars = c.value(.chars, 0)
        seconds = c.value(.seconds, 0)
        timedWords = c.value(.timedWords, 0)
        cancelled = c.value(.cancelled, 0)
        tidied = c.value(.tidied, 0)
        outcomes = c.value(.outcomes, [:])
        languages = c.value(.languages, [:])
        apps = c.value(.apps, [:])
        let storedHours: [Double] = c.value(.hours, [])
        hours = storedHours.count == 24 ? storedHours : Array(repeating: 0, count: 24)
        lengths = c.buckets(.lengths, count: DictationLengthBuckets.labels.count)
    }

    var wordsPerMinute: Double? {
        seconds >= 1 && timedWords > 0 ? Double(timedWords) / (seconds / 60) : nil
    }

    static func + (lhs: DictationUsage, rhs: DictationUsage) -> DictationUsage {
        var out = lhs
        out.sessions += rhs.sessions
        out.words += rhs.words
        out.chars += rhs.chars
        out.seconds += rhs.seconds
        out.timedWords += rhs.timedWords
        out.cancelled += rhs.cancelled
        out.tidied += rhs.tidied
        out.outcomes = merged(lhs.outcomes, rhs.outcomes, +)
        out.languages = merged(lhs.languages, rhs.languages, +)
        out.apps = merged(lhs.apps, rhs.apps, +)
        out.hours = zip(lhs.hours, rhs.hours).map(+)
        out.lengths = zip(lhs.lengths, rhs.lengths).map(+)
        return out
    }
}

struct CreationUsage: Codable, Equatable {
    var booksGenerated = 0
    var chaptersGenerated = 0
    var bookAudioSeconds: Double = 0
    var bookRenderSeconds: Double = 0
    var booksFinished = 0
    var podcastScripts = 0
    var podcastRenders = 0
    var podcastAudioSeconds: Double = 0
    var podcastSpeakers = 0
    var m4bExports = 0
    var imports: [String: Int] = [:]

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        booksGenerated = c.value(.booksGenerated, 0)
        chaptersGenerated = c.value(.chaptersGenerated, 0)
        bookAudioSeconds = c.value(.bookAudioSeconds, 0)
        bookRenderSeconds = c.value(.bookRenderSeconds, 0)
        booksFinished = c.value(.booksFinished, 0)
        podcastScripts = c.value(.podcastScripts, 0)
        podcastRenders = c.value(.podcastRenders, 0)
        podcastAudioSeconds = c.value(.podcastAudioSeconds, 0)
        podcastSpeakers = c.value(.podcastSpeakers, 0)
        m4bExports = c.value(.m4bExports, 0)
        imports = c.value(.imports, [:])
    }

    static func + (lhs: CreationUsage, rhs: CreationUsage) -> CreationUsage {
        var out = lhs
        out.booksGenerated += rhs.booksGenerated
        out.chaptersGenerated += rhs.chaptersGenerated
        out.bookAudioSeconds += rhs.bookAudioSeconds
        out.bookRenderSeconds += rhs.bookRenderSeconds
        out.booksFinished += rhs.booksFinished
        out.podcastScripts += rhs.podcastScripts
        out.podcastRenders += rhs.podcastRenders
        out.podcastAudioSeconds += rhs.podcastAudioSeconds
        out.podcastSpeakers += rhs.podcastSpeakers
        out.m4bExports += rhs.m4bExports
        out.imports = merged(lhs.imports, rhs.imports, +)
        return out
    }
}

struct AIActivity: Codable, Equatable {
    var requests: [String: Int] = [:]
    var failures: [String: Int] = [:]
    var providers: [String: Int] = [:]
    var latencyMsTotal: Double = 0
    var latencyCount = 0
    var wordsIn = 0
    var wordsOut = 0

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        requests = c.value(.requests, [:])
        failures = c.value(.failures, [:])
        providers = c.value(.providers, [:])
        latencyMsTotal = c.value(.latencyMsTotal, 0)
        latencyCount = c.value(.latencyCount, 0)
        wordsIn = c.value(.wordsIn, 0)
        wordsOut = c.value(.wordsOut, 0)
    }

    var totalRequests: Int {
        requests.values.reduce(0, +)
    }

    var totalFailures: Int {
        failures.values.reduce(0, +)
    }

    var averageLatencyMs: Double? {
        latencyCount > 0 ? latencyMsTotal / Double(latencyCount) : nil
    }

    static func + (lhs: AIActivity, rhs: AIActivity) -> AIActivity {
        var out = lhs
        out.requests = merged(lhs.requests, rhs.requests, +)
        out.failures = merged(lhs.failures, rhs.failures, +)
        out.providers = merged(lhs.providers, rhs.providers, +)
        out.latencyMsTotal += rhs.latencyMsTotal
        out.latencyCount += rhs.latencyCount
        out.wordsIn += rhs.wordsIn
        out.wordsOut += rhs.wordsOut
        return out
    }
}

nonisolated struct SpeechRun: Equatable, Sendable {
    var engine: String
    var source: SpeechSource
    var firstAudioMs: Double?
    var renderSeconds: Double
}

nonisolated struct DictationSession: Equatable, Sendable {
    var text: String
    var seconds: Double?
    var outcome: String
    var language: String?
    var app: String?
    var tidied: Bool
}

nonisolated struct AIRun: Equatable, Sendable {
    var tool: String
    var provider: String
    var ok: Bool
    var latencyMs: Double
    var wordsIn: Int
    var wordsOut: Int
}
