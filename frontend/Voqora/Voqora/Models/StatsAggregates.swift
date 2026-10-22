import Foundation

enum StatsAssumptions {
    static let readingWordsPerMinute = 238.0
    static let typingWordsPerMinute = 40.0
}

enum StatsLabels {
    static func engine(_ key: String) -> String {
        switch key {
        case SpeechEngineID.kokoro: "Kokoro"
        case SpeechEngineID.supertonic: "Supertonic"
        case SpeechEngineID.ming: "Ming"
        case "blend": "Blend"
        case "other": "Other"
        default: key.prefix(1).uppercased() + key.dropFirst()
        }
    }

    static func tool(_ key: String) -> String {
        switch key {
        case "podcast_script": "Podcast script"
        case "flashcards": "Flashcards"
        default: key.prefix(1).uppercased() + key.dropFirst()
        }
    }

    static func provider(_ key: String) -> String {
        LLMProvider(rawValue: key)?.displayName ?? (key.prefix(1).uppercased() + key.dropFirst())
    }

    static func importKind(_ key: String) -> String {
        switch key {
        case "pdf": "PDF"
        case "epub": "EPUB"
        case "txt": "Text file"
        case "docx": "Word"
        case "md": "Markdown"
        case "html": "HTML"
        case "web": "Web page"
        case "inbox": "Inbox"
        case "text": "Pasted text"
        default: "Other"
        }
    }

    static func outcome(_ key: String) -> String {
        switch key {
        case "pasted": "Pasted"
        case "copied": "Copied"
        case "copied_needs_accessibility": "Needs Accessibility"
        case "copied_app_changed": "App changed"
        case "cancelled": "Cancelled"
        default: "Other"
        }
    }

    static func language(_ code: String) -> String {
        let base = code.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? code
        return Locale.current.localizedString(forLanguageCode: base)?.capitalized ?? code.uppercased()
    }

    static func source(_ key: String) -> String {
        SpeechSource(rawValue: key)?.title ?? key.capitalized
    }
}

struct PeriodAggregate: Equatable {
    var activeDays = 0
    var speechCount = 0
    var speechWords = 0
    var speechSeconds: Double = 0
    var listeningSeconds: Double = 0
    var exports = 0
    var documentsAdded = 0
    var speech = SpeechDetail()
    var dictation = DictationUsage()
    var creation = CreationUsage()
    var ai = AIActivity()
    var voices: [String: VoiceUsage] = [:]
    var speeds: [String: Int] = [:]
    var books: [String: Double] = [:]
    var hours = Array(repeating: 0.0, count: 24)

    mutating func add(_ day: DayUsage) {
        speechCount += day.speechCount
        speechWords += day.speechWords
        speechSeconds += day.speechSeconds
        listeningSeconds += day.listeningSeconds
        exports += day.exports
        documentsAdded += day.documentsAdded
        speech = day.speech + speech
        dictation = day.dictation + dictation
        creation = day.creation + creation
        ai = day.ai + ai
        for (voice, usage) in day.voices {
            voices[voice, default: VoiceUsage()] += usage
        }
        for (speed, count) in day.speeds {
            speeds[speed, default: 0] += count
        }
        for (book, seconds) in day.books {
            books[book, default: 0] += seconds
        }
        for hour in 0 ..< 24 {
            hours[hour] += day.hours[hour] + day.dictation.hours[hour]
        }
        if day.isActive {
            activeDays += 1
        }
    }

    var heardSeconds: Double {
        speechSeconds + listeningSeconds
    }

    var hasActivity: Bool {
        speechCount > 0 || listeningSeconds >= 1 || documentsAdded > 0 || dictation.sessions > 0 || dictation.cancelled > 0
            || creation.booksGenerated > 0 || creation.podcastRenders > 0 || creation.podcastScripts > 0 || ai.totalRequests > 0
    }

    var readingEquivalentSeconds: Double {
        Double(speechWords) / StatsAssumptions.readingWordsPerMinute * 60
    }

    var listeningSavedSeconds: Double {
        max(0, readingEquivalentSeconds - speechSeconds)
    }

    var typingEquivalentSeconds: Double {
        Double(dictation.timedWords) / StatsAssumptions.typingWordsPerMinute * 60
    }

    var dictationSavedSeconds: Double {
        max(0, typingEquivalentSeconds - dictation.seconds)
    }

    var totalSavedSeconds: Double {
        listeningSavedSeconds + dictationSavedSeconds
    }

    var aiSuccessRate: Double? {
        let requests = ai.totalRequests
        guard requests > 0 else { return nil }
        return 1 - Double(min(ai.totalFailures, requests)) / Double(requests)
    }

    var renderSpeed: Double? {
        creation.bookRenderSeconds > 0 && creation.bookAudioSeconds > 0 ? creation.bookAudioSeconds / creation.bookRenderSeconds : nil
    }

    var tidiedShare: Double? {
        dictation.sessions > 0 ? Double(dictation.tidied) / Double(dictation.sessions) : nil
    }

    var averageSelectionWords: Int {
        speechCount > 0 ? speechWords / speechCount : 0
    }
}

struct EngineRow: Identifiable, Equatable {
    let id: String
    let usage: EngineUsage
    let share: Double

    var name: String {
        StatsLabels.engine(id)
    }

    var failureRate: Double? {
        let attempts = usage.uses + usage.failures
        return attempts > 0 ? Double(usage.failures) / Double(attempts) : nil
    }
}

struct TimelinePoint: Identifiable, Equatable {
    let date: Date
    var listeningMinutes: Double = 0
    var speechMinutes: Double = 0
    var dictationMinutes: Double = 0
    var creatingMinutes: Double = 0
    var aiRequests = 0
    var booksGenerated = 0
    var podcastRenders = 0
    var m4bExports = 0
    var dictationWords = 0
    var dictationTimedWords = 0
    var dictationSeconds: Double = 0
    var engineUses: [String: Int] = [:]

    var id: Date {
        date
    }

    var totalMinutes: Double {
        listeningMinutes + speechMinutes + dictationMinutes + creatingMinutes
    }

    var wordsPerMinute: Double? {
        dictationSeconds >= 1 && dictationTimedWords > 0 ? Double(dictationTimedWords) / (dictationSeconds / 60) : nil
    }

    mutating func absorb(_ other: TimelinePoint) {
        listeningMinutes += other.listeningMinutes
        speechMinutes += other.speechMinutes
        dictationMinutes += other.dictationMinutes
        creatingMinutes += other.creatingMinutes
        aiRequests += other.aiRequests
        booksGenerated += other.booksGenerated
        podcastRenders += other.podcastRenders
        m4bExports += other.m4bExports
        dictationWords += other.dictationWords
        dictationTimedWords += other.dictationTimedWords
        dictationSeconds += other.dictationSeconds
        engineUses.merge(other.engineUses, uniquingKeysWith: +)
    }
}

struct ContributionCell: Identifiable, Equatable {
    let week: Int
    let weekday: Int
    let date: Date
    let minutes: Double
    let level: Int
    let isFuture: Bool

    var id: Int {
        week * 7 + weekday
    }
}

struct MonthLabel: Equatable {
    let week: Int
    let text: String
}

struct Contributions: Equatable {
    var weeks = 0
    var cells: [ContributionCell] = []
    var monthLabels: [MonthLabel] = []
    var activeDays = 0

    static func level(minutes: Double, isActive: Bool, peak: Double) -> Int {
        guard isActive || minutes > 0 else { return 0 }
        guard peak > 0 else { return 1 }
        let fraction = minutes / peak
        if fraction > 0.75 {
            return 4
        }
        if fraction > 0.5 {
            return 3
        }
        if fraction > 0.25 {
            return 2
        }
        return 1
    }

    static func make(ledger: UsageLedger, weeks: Int, now: Date, calendar: Calendar) -> Contributions {
        let grid = UsageSummary.heatmap(ledger: ledger, weeks: weeks, now: now, calendar: calendar)
        let peak = grid.joined().filter { !$0.isFuture }.map(\.minutes).max() ?? 0
        var cells: [ContributionCell] = []
        var labels: [MonthLabel] = []
        var previousMonth: Int?
        var active = 0
        for (week, days) in grid.enumerated() {
            if let first = days.first {
                let month = calendar.component(.month, from: first.date)
                if month != previousMonth {
                    labels.append(MonthLabel(week: week, text: first.date.formatted(Date.FormatStyle(calendar: calendar).month(.abbreviated))))
                    previousMonth = month
                }
            }
            for (weekday, day) in days.enumerated() {
                let level = day.isFuture ? 0 : level(minutes: day.minutes, isActive: day.isActive, peak: peak)
                if level > 0 {
                    active += 1
                }
                cells.append(ContributionCell(week: week, weekday: weekday, date: day.date, minutes: day.minutes, level: level, isFuture: day.isFuture))
            }
        }
        if labels.count > 1, labels[1].week - labels[0].week < 3 {
            labels.removeFirst()
        }
        return Contributions(weeks: weeks, cells: cells, monthLabels: labels, activeDays: active)
    }
}

struct StatsAggregates: Equatable {
    let range: StatsRange
    let interval: DateInterval
    let previousInterval: DateInterval?
    let current: PeriodAggregate
    let previous: PeriodAggregate?
    let lifetime: PeriodAggregate
    let timeline: [TimelinePoint]
    let trend: [TimelinePoint]
    let hourWeekday: [[Double]]
    let contributions: Contributions
    let currentStreak: Int
    let longestStreak: Int
    let recentWeek: [Bool]
    let engines: [EngineRow]
    let firstRecorded: Date?
    let dayCount: Int

    static let contributionWeeks = 26

    var trendUnit: Calendar.Component {
        range == .quarter ? .weekOfYear : range.bucket
    }

    var trendUnitName: String {
        switch trendUnit {
        case .day: "day"
        case .weekOfYear: "week"
        default: "month"
        }
    }

    var comparison: String? {
        previous == nil ? nil : range.comparisonLabel
    }

    func change(_ value: (PeriodAggregate) -> Double) -> Double? {
        UsageSummary.change(value(current), previous.map(value))
    }

    var peakHour: Int? {
        guard let peak = current.hours.max(), peak > 0 else { return nil }
        return current.hours.firstIndex(of: peak)
    }

    var weekdayTotals: [Double] {
        hourWeekday.map { $0.reduce(0, +) }
    }

    var peakWeekday: Int? {
        let totals = weekdayTotals
        guard let peak = totals.max(), peak > 0 else { return nil }
        return totals.firstIndex(of: peak)
    }

    var hourWeekdayPeak: Double {
        hourWeekday.joined().max() ?? 0
    }

    var busiest: TimelinePoint? {
        timeline.filter { $0.totalMinutes > 0 }.max { $0.totalMinutes < $1.totalMinutes }
    }

    var enginesWithRealTime: [EngineRow] {
        engines.filter { $0.usage.realTimeFactor != nil }
    }

    var fastestEngine: EngineRow? {
        enginesWithRealTime.max { ($0.usage.realTimeFactor ?? 0) < ($1.usage.realTimeFactor ?? 0) }
    }

    var quickestStartEngine: EngineRow? {
        engines.filter { $0.usage.averageFirstAudioMs != nil }.min { ($0.usage.averageFirstAudioMs ?? 0) < ($1.usage.averageFirstAudioMs ?? 0) }
    }

    var engineSeries: [String] {
        engines.map(\.id)
    }

    static func make(ledger: UsageLedger, range: StatsRange, now: Date, calendar: Calendar) -> StatsAggregates {
        let interval = range.interval(endingAt: now, firstRecorded: ledger.firstRecorded, calendar: calendar)
        let previousInterval = range.previousInterval(before: interval, calendar: calendar)
        let dated: [(date: Date, day: DayUsage)] = ledger.days
            .compactMap { key, day in UsageLedger.date(forKey: key, calendar: calendar).map { ($0, day) } }
            .sorted { $0.date < $1.date }

        var current = PeriodAggregate()
        var previous = previousInterval.map { _ in PeriodAggregate() }
        var lifetime = PeriodAggregate()
        var hourWeekday = Array(repeating: Array(repeating: 0.0, count: 24), count: 7)
        var points: [Date: TimelinePoint] = [:]

        for (date, day) in dated {
            lifetime.add(day)
            if let previousInterval, date >= previousInterval.start, date < previousInterval.end {
                previous?.add(day)
            }
            guard date >= interval.start, date < interval.end else { continue }
            current.add(day)
            let weekday = (calendar.component(.weekday, from: date) + 5) % 7
            for hour in 0 ..< 24 {
                hourWeekday[weekday][hour] += (day.hours[hour] + day.dictation.hours[hour]) / 60
            }
            let bucket = calendar.start(of: range.bucket, for: date)
            var point = points[bucket] ?? TimelinePoint(date: bucket)
            point.listeningMinutes += day.listeningSeconds / 60
            point.speechMinutes += day.speechSeconds / 60
            point.dictationMinutes += day.dictation.seconds / 60
            point.creatingMinutes += day.creation.bookRenderSeconds / 60
            point.aiRequests += day.ai.totalRequests
            point.booksGenerated += day.creation.booksGenerated
            point.podcastRenders += day.creation.podcastRenders
            point.m4bExports += day.creation.m4bExports
            point.dictationWords += day.dictation.words
            point.dictationTimedWords += day.dictation.timedWords
            point.dictationSeconds += day.dictation.seconds
            for (engine, usage) in day.speech.engines where usage.uses > 0 {
                point.engineUses[engine, default: 0] += usage.uses
            }
            points[bucket] = point
        }

        var timeline: [TimelinePoint] = []
        var cursor = interval.start
        while cursor < interval.end {
            timeline.append(points[cursor] ?? TimelinePoint(date: cursor))
            cursor = calendar.shifting(cursor, range.bucket, 1)
        }

        let trendUnit: Calendar.Component = range == .quarter ? .weekOfYear : range.bucket
        var trend = timeline
        if trendUnit != range.bucket {
            var merged: [Date: TimelinePoint] = [:]
            for point in timeline {
                let start = calendar.start(of: trendUnit, for: point.date)
                var bucket = merged[start] ?? TimelinePoint(date: start)
                bucket.absorb(point)
                merged[start] = bucket
            }
            trend = merged.values.sorted { $0.date < $1.date }
        }

        let totalUses = max(1, current.speech.engines.values.reduce(0) { $0 + $1.uses })
        let engines = current.speech.engines
            .filter { $0.value.uses > 0 || $0.value.failures > 0 }
            .map { EngineRow(id: $0.key, usage: $0.value, share: Double($0.value.uses) / Double(totalUses)) }
            .sorted { ($0.usage.uses, $1.id) > ($1.usage.uses, $0.id) }

        let streaks = UsageSummary.streaks(ledger: ledger, now: now, calendar: calendar)
        let today = calendar.startOfDay(for: now)
        let recentWeek = (0 ..< 7).reversed().map { offset -> Bool in
            let date = calendar.shifting(today, .day, -offset)
            return ledger.days[UsageLedger.dayKey(for: date, calendar: calendar)]?.isActive ?? false
        }
        let dayCount = max(1, Int((interval.duration / 86400).rounded()))

        return StatsAggregates(
            range: range,
            interval: interval,
            previousInterval: previousInterval,
            current: current,
            previous: previous,
            lifetime: lifetime,
            timeline: timeline,
            trend: trend,
            hourWeekday: hourWeekday,
            contributions: Contributions.make(ledger: ledger, weeks: contributionWeeks, now: now, calendar: calendar),
            currentStreak: streaks.current,
            longestStreak: streaks.longest,
            recentWeek: recentWeek,
            engines: engines,
            firstRecorded: ledger.firstRecorded,
            dayCount: dayCount
        )
    }
}

extension StatsAggregates {
    func narrative(voiceName: (String) -> String, weekdayName: (Int) -> String) -> String {
        let phrase = range.narrativeLead
        guard current.hasActivity else {
            let when = range == .all ? "Nothing has been recorded yet." : "Nothing was recorded in \(range.phrase)."
            return "\(when) Read some text aloud, dictate a note, or start an audiobook and this summary fills itself in."
        }
        var sentences: [String] = []
        let activeNoun = current.activeDays == 1 ? "day" : "days"
        if current.heardSeconds >= 1 {
            let total = range.bucket == .day ? " of \(dayCount)" : ""
            sentences.append("\(phrase) you were active on \(current.activeDays)\(total) \(activeNoun) and listened for \(Self.spokenDuration(current.heardSeconds)).")
        } else {
            sentences.append("\(phrase) you were active on \(current.activeDays) \(activeNoun).")
        }
        if let voice = current.voices.max(by: { ($0.value.uses, $1.key) < ($1.value.uses, $0.key) }) {
            let uses = voice.value.uses
            sentences.append("\(voiceName(voice.key)) was your most-used voice across \(uses) \(uses == 1 ? "read" : "reads").")
        }
        if current.dictation.sessions > 0 {
            var text = "You dictated \(current.dictation.words.formatted()) words in \(current.dictation.sessions) \(current.dictation.sessions == 1 ? "session" : "sessions")"
            if let wpm = current.dictation.wordsPerMinute {
                text += " at about \(Int(wpm.rounded())) words per minute"
            }
            if current.dictationSavedSeconds >= 60 {
                text += ", which saved roughly \(Self.spokenDuration(current.dictationSavedSeconds)) of typing"
            }
            sentences.append(text + ".")
        }
        if current.creation.booksGenerated > 0 || current.creation.podcastRenders > 0 {
            var parts: [String] = []
            if current.creation.booksGenerated > 0 {
                let books = current.creation.booksGenerated
                parts.append("\(books) \(books == 1 ? "audiobook" : "audiobooks") (\(Self.spokenDuration(current.creation.bookAudioSeconds)) of audio)")
            }
            if current.creation.podcastRenders > 0 {
                let podcasts = current.creation.podcastRenders
                parts.append("\(podcasts) \(podcasts == 1 ? "podcast" : "podcasts")")
            }
            sentences.append("You created \(parts.joined(separator: " and ")).")
        }
        if current.ai.totalRequests > 0 {
            var text = "AI helped \(current.ai.totalRequests) \(current.ai.totalRequests == 1 ? "time" : "times")"
            if let rate = current.aiSuccessRate {
                text += " with a \(Int((rate * 100).rounded())) percent success rate"
            }
            sentences.append(text + ".")
        }
        if let hour = peakHour, let day = peakWeekday {
            sentences.append("You are busiest around \(Self.hourName(hour)) and on \(weekdayName(day))s.")
        }
        if let comparison = previous.flatMap({ UsageSummary.change(current.heardSeconds, $0.heardSeconds) }), let label = range.comparisonLabel {
            let percent = Int((abs(comparison) * 100).rounded())
            sentences.append(percent == 0 ? "Listening time is steady \(label)." : "Listening time is \(comparison > 0 ? "up" : "down") \(percent) percent \(label).")
        }
        return sentences.joined(separator: " ")
    }

    static func spokenDuration(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        guard minutes >= 60 else { return "\(max(minutes, 1)) \(minutes <= 1 ? "minute" : "minutes")" }
        let hours = minutes / 60
        let rest = minutes % 60
        let hourText = "\(hours) \(hours == 1 ? "hour" : "hours")"
        return rest == 0 || hours >= 100 ? hourText : "\(hourText) \(rest) min"
    }

    static func hourName(_ hour: Int) -> String {
        let normalized = hour % 12 == 0 ? 12 : hour % 12
        return "\(normalized) \(hour < 12 ? "AM" : "PM")"
    }
}
