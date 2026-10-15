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
    }

    var activeSeconds: Double {
        speechSeconds + listeningSeconds
    }

    var isActive: Bool {
        speechCount > 0 || listeningSeconds >= 1 || documentsAdded > 0
    }
}

struct UsageLedger: Codable, Equatable {
    var firstRecorded: Date?
    var importedHistory = false
    var days: [String: DayUsage] = [:]

    init(firstRecorded: Date? = nil, importedHistory: Bool = false, days: [String: DayUsage] = [:]) {
        self.firstRecorded = firstRecorded
        self.importedHistory = importedHistory
        self.days = days
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        firstRecorded = try c.decodeIfPresent(Date.self, forKey: .firstRecorded)
        importedHistory = try c.decodeIfPresent(Bool.self, forKey: .importedHistory) ?? false
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

    mutating func recordSpeech(_ sample: SpeechSample, at date: Date, calendar: Calendar) {
        let words = Self.wordCount(sample.text)
        let seconds = max(0, sample.audioSeconds)
        let hour = calendar.component(.hour, from: date)
        update(at: date, calendar: calendar) { day in
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
