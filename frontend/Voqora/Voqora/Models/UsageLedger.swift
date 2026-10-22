import Foundation

struct VoiceUsage: Codable, Equatable {
    var uses = 0
    var words = 0
    var seconds: Double = 0

    init(uses: Int = 0, words: Int = 0, seconds: Double = 0) {
        self.uses = uses
        self.words = words
        self.seconds = seconds
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uses = try c.decodeIfPresent(Int.self, forKey: .uses) ?? 0
        words = try c.decodeIfPresent(Int.self, forKey: .words) ?? 0
        seconds = try c.decodeIfPresent(Double.self, forKey: .seconds) ?? 0
    }

    static func + (lhs: VoiceUsage, rhs: VoiceUsage) -> VoiceUsage {
        VoiceUsage(uses: lhs.uses + rhs.uses, words: lhs.words + rhs.words, seconds: lhs.seconds + rhs.seconds)
    }

    static func += (lhs: inout VoiceUsage, rhs: VoiceUsage) {
        lhs = lhs + rhs
    }
}

struct SpeechSample: Equatable {
    let text: String
    let voice: String
    let speed: Double
    let audioSeconds: Double
}

struct DayUsage: Codable, Equatable {
    var speechCount = 0
    var speechWords = 0
    var speechChars = 0
    var speechSeconds: Double = 0
    var listeningSeconds: Double = 0
    var exports = 0
    var documentsAdded = 0
    var pagesAdded = 0
    var launches = 0
    var hours: [Double] = Array(repeating: 0, count: 24)
    var voices: [String: VoiceUsage] = [:]
    var speeds: [String: Int] = [:]
    var books: [String: Double] = [:]
    var speech = SpeechDetail()
    var dictation = DictationUsage()
    var creation = CreationUsage()
    var ai = AIActivity()

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        speechCount = try c.decodeIfPresent(Int.self, forKey: .speechCount) ?? 0
        speechWords = try c.decodeIfPresent(Int.self, forKey: .speechWords) ?? 0
        speechChars = try c.decodeIfPresent(Int.self, forKey: .speechChars) ?? 0
        speechSeconds = try c.decodeIfPresent(Double.self, forKey: .speechSeconds) ?? 0
        listeningSeconds = try c.decodeIfPresent(Double.self, forKey: .listeningSeconds) ?? 0
        exports = try c.decodeIfPresent(Int.self, forKey: .exports) ?? 0
        documentsAdded = try c.decodeIfPresent(Int.self, forKey: .documentsAdded) ?? 0
        pagesAdded = try c.decodeIfPresent(Int.self, forKey: .pagesAdded) ?? 0
        launches = try c.decodeIfPresent(Int.self, forKey: .launches) ?? 0
        let storedHours = try c.decodeIfPresent([Double].self, forKey: .hours) ?? []
        hours = storedHours.count == 24 ? storedHours : Array(repeating: 0, count: 24)
        voices = try c.decodeIfPresent([String: VoiceUsage].self, forKey: .voices) ?? [:]
        speeds = try c.decodeIfPresent([String: Int].self, forKey: .speeds) ?? [:]
        books = try c.decodeIfPresent([String: Double].self, forKey: .books) ?? [:]
        speech = (try? c.decodeIfPresent(SpeechDetail.self, forKey: .speech)) ?? SpeechDetail()
        dictation = (try? c.decodeIfPresent(DictationUsage.self, forKey: .dictation)) ?? DictationUsage()
        creation = (try? c.decodeIfPresent(CreationUsage.self, forKey: .creation)) ?? CreationUsage()
        ai = (try? c.decodeIfPresent(AIActivity.self, forKey: .ai)) ?? AIActivity()
    }

    var activeSeconds: Double {
        speechSeconds + listeningSeconds + dictation.seconds
    }

    var isActive: Bool {
        speechCount > 0 || listeningSeconds >= 1 || documentsAdded > 0 || dictation.sessions > 0
            || creation.booksGenerated > 0 || creation.podcastRenders > 0 || ai.totalRequests > 0
    }
}

struct UsageLedger: Codable, Equatable {
    var firstRecorded: Date?
    var importedHistory = false
    var importedDictation = false
    var days: [String: DayUsage] = [:]

    init(firstRecorded: Date? = nil, importedHistory: Bool = false, importedDictation: Bool = false, days: [String: DayUsage] = [:]) {
        self.firstRecorded = firstRecorded
        self.importedHistory = importedHistory
        self.importedDictation = importedDictation
        self.days = days
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        firstRecorded = try c.decodeIfPresent(Date.self, forKey: .firstRecorded)
        importedHistory = try c.decodeIfPresent(Bool.self, forKey: .importedHistory) ?? false
        importedDictation = try c.decodeIfPresent(Bool.self, forKey: .importedDictation) ?? false
        days = try c.decodeIfPresent([String: DayUsage].self, forKey: .days) ?? [:]
    }

    static func dayKey(for date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func date(forKey key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    static func speedKey(_ speed: Double) -> String {
        String(format: "%.2f", (speed * 20).rounded() / 20)
    }

    mutating func update(at date: Date, calendar: Calendar, _ change: (inout DayUsage) -> Void) {
        if firstRecorded == nil || date < firstRecorded! {
            firstRecorded = date
        }
        let key = Self.dayKey(for: date, calendar: calendar)
        var day = days[key] ?? DayUsage()
        change(&day)
        days[key] = day
    }

    mutating func recordSpeech(_ sample: SpeechSample, run: SpeechRun? = nil, at date: Date, calendar: Calendar) {
        let words = Self.wordCount(sample.text)
        let seconds = max(0, sample.audioSeconds)
        let hour = calendar.component(.hour, from: date)
        update(at: date, calendar: calendar) { day in
            if let run {
                day.speech.sources[run.source.rawValue, default: 0] += 1
                var engine = day.speech.engines[run.engine] ?? EngineUsage()
                engine.uses += 1
                engine.words += words
                engine.audioSeconds += seconds
                engine.renderSeconds += max(0, run.renderSeconds)
                if let ms = run.firstAudioMs, ms >= 0 {
                    engine.firstAudioCount += 1
                    engine.firstAudioMsTotal += ms
                    engine.firstAudioBuckets[LatencyBuckets.index(forMs: ms)] += 1
                }
                day.speech.engines[run.engine] = engine
            }
            day.speechCount += 1
            day.speechWords += words
            day.speechChars += sample.text.count
            day.speechSeconds += seconds
            day.hours[hour] += max(seconds, 1)
            day.voices[sample.voice, default: VoiceUsage()] += VoiceUsage(uses: 1, words: words, seconds: seconds)
            day.speeds[Self.speedKey(sample.speed), default: 0] += 1
        }
    }

    mutating func recordListening(bookID: String, seconds: Double, at date: Date, calendar: Calendar) {
        guard seconds > 0 else { return }
        let hour = calendar.component(.hour, from: date)
        update(at: date, calendar: calendar) { day in
            day.listeningSeconds += seconds
            day.hours[hour] += seconds
            day.books[bookID, default: 0] += seconds
        }
    }

    mutating func recordSpeechFailure(engine: String, at date: Date, calendar: Calendar) {
        update(at: date, calendar: calendar) { day in
            day.speech.failures += 1
            day.speech.engines[engine, default: EngineUsage()].failures += 1
        }
    }

    mutating func recordRelay(client: String, at date: Date, calendar: Calendar) {
        let name = client.trimmingCharacters(in: .whitespacesAndNewlines)
        update(at: date, calendar: calendar) { day in
            day.speech.relayClients[name.isEmpty ? "Unnamed" : String(name.prefix(48)), default: 0] += 1
        }
    }

    mutating func recordDictation(_ session: DictationSession, at date: Date, calendar: Calendar) {
        let words = Self.wordCount(session.text)
        let hour = calendar.component(.hour, from: date)
        update(at: date, calendar: calendar) { day in
            var d = day.dictation
            d.outcomes[session.outcome, default: 0] += 1
            guard words > 0 else {
                d.cancelled += 1
                day.dictation = d
                return
            }
            d.sessions += 1
            d.words += words
            d.chars += session.text.count
            if let seconds = session.seconds, seconds > 0 {
                d.seconds += seconds
                d.timedWords += words
                d.hours[hour] += seconds
            } else {
                d.hours[hour] += 1
            }
            if session.tidied {
                d.tidied += 1
            }
            if let language = session.language, !language.isEmpty {
                d.languages[language, default: 0] += 1
            }
            if let app = session.app, !app.isEmpty {
                d.apps[app, default: 0] += 1
            }
            d.lengths[DictationLengthBuckets.index(forWords: words)] += 1
            day.dictation = d
        }
    }

    mutating func recordDictationCancelled(at date: Date, calendar: Calendar) {
        update(at: date, calendar: calendar) { day in
            day.dictation.cancelled += 1
            day.dictation.outcomes["cancelled", default: 0] += 1
        }
    }

    mutating func recordAI(_ run: AIRun, at date: Date, calendar: Calendar) {
        update(at: date, calendar: calendar) { day in
            day.ai.requests[run.tool, default: 0] += 1
            day.ai.providers[run.provider, default: 0] += 1
            if run.ok {
                day.ai.latencyMsTotal += max(0, run.latencyMs)
                day.ai.latencyCount += 1
                day.ai.wordsIn += max(0, run.wordsIn)
                day.ai.wordsOut += max(0, run.wordsOut)
            } else {
                day.ai.failures[run.tool, default: 0] += 1
            }
        }
    }

    mutating func recordBookGenerated(chapters: Int, audioSeconds: Double, renderSeconds: Double, at date: Date, calendar: Calendar) {
        update(at: date, calendar: calendar) { day in
            day.creation.booksGenerated += 1
            day.creation.chaptersGenerated += max(0, chapters)
            day.creation.bookAudioSeconds += max(0, audioSeconds)
            day.creation.bookRenderSeconds += max(0, renderSeconds)
        }
    }

    mutating func recordBookFinished(at date: Date, calendar: Calendar) {
        update(at: date, calendar: calendar) { $0.creation.booksFinished += 1 }
    }

    mutating func recordPodcastScript(at date: Date, calendar: Calendar) {
        update(at: date, calendar: calendar) { $0.creation.podcastScripts += 1 }
    }

    mutating func recordPodcastRender(speakers: Int, audioSeconds: Double, at date: Date, calendar: Calendar) {
        update(at: date, calendar: calendar) { day in
            day.creation.podcastRenders += 1
            day.creation.podcastSpeakers += max(0, speakers)
            day.creation.podcastAudioSeconds += max(0, audioSeconds)
        }
    }

    mutating func recordM4BExport(at date: Date, calendar: Calendar) {
        update(at: date, calendar: calendar) { $0.creation.m4bExports += 1 }
    }

    mutating func recordImport(kind: String, at date: Date, calendar: Calendar) {
        update(at: date, calendar: calendar) { $0.creation.imports[kind, default: 0] += 1 }
    }

    mutating func importDictationHistory(_ transcripts: [DictationTranscript], calendar: Calendar) {
        guard !importedDictation else { return }
        importedDictation = true
        for transcript in transcripts {
            let language = transcript.localeIdentifier.flatMap { Locale(identifier: $0).language.languageCode?.identifier }
            recordDictation(
                DictationSession(text: transcript.text, seconds: nil, outcome: "imported", language: language, app: nil, tidied: false),
                at: transcript.createdAt,
                calendar: calendar
            )
        }
    }

    mutating func recordExport(at date: Date, calendar: Calendar) {
        update(at: date, calendar: calendar) { $0.exports += 1 }
    }

    mutating func recordDocumentAdded(pages: Int, at date: Date, calendar: Calendar) {
        update(at: date, calendar: calendar) { day in
            day.documentsAdded += 1
            day.pagesAdded += max(0, pages)
        }
    }

    mutating func recordLaunch(at date: Date, calendar: Calendar) {
        update(at: date, calendar: calendar) { $0.launches += 1 }
    }

    mutating func importHistory(_ entries: [HistoryEntry], calendar: Calendar) {
        guard !importedHistory else { return }
        importedHistory = true
        for entry in entries {
            let words = Self.wordCount(entry.text)
            let hour = calendar.component(.hour, from: entry.timestamp)
            update(at: entry.timestamp, calendar: calendar) { day in
                day.speechCount += 1
                day.speechWords += words
                day.speechChars += entry.text.count
                day.hours[hour] += 1
                day.voices[entry.voice, default: VoiceUsage()] += VoiceUsage(uses: 1, words: words, seconds: 0)
            }
        }
    }
}
