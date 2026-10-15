import Foundation

enum StatsRange: String, CaseIterable, Identifiable {
    case week
    case month
    case year
    case all

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .week: "7 Days"
        case .month: "30 Days"
        case .year: "12 Months"
        case .all: "All Time"
        }
    }

    var comparisonLabel: String? {
        switch self {
        case .week: "vs previous 7 days"
        case .month: "vs previous 30 days"
        case .year: "vs previous 12 months"
        case .all: nil
        }
    }

    var bucket: Calendar.Component {
        switch self {
        case .week, .month: .day
        case .year, .all: .month
        }
    }

    func interval(endingAt now: Date, firstRecorded: Date?, calendar: Calendar) -> DateInterval {
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        let start: Date = switch self {
        case .week:
            calendar.date(byAdding: .day, value: -7, to: end)!
        case .month:
            calendar.date(byAdding: .day, value: -30, to: end)!
        case .year:
            calendar.date(byAdding: .month, value: -11, to: calendar.dateInterval(of: .month, for: now)!.start)!
        case .all:
            min(
                calendar.dateInterval(of: .month, for: firstRecorded ?? now)!.start,
                calendar.date(byAdding: .month, value: -5, to: calendar.dateInterval(of: .month, for: now)!.start)!
            )
        }
        return DateInterval(start: start, end: end)
    }

    func previousInterval(before interval: DateInterval, calendar: Calendar) -> DateInterval? {
        switch self {
        case .week, .month:
            DateInterval(start: interval.start.addingTimeInterval(-interval.duration), end: interval.start)
        case .year:
            DateInterval(start: calendar.date(byAdding: .month, value: -12, to: interval.start)!, end: interval.start)
        case .all:
            nil
        }
    }
}

struct UsageTotals: Equatable {
    var speechCount = 0
    var speechWords = 0
    var speechChars = 0
    var speechSeconds: Double = 0
    var listeningSeconds: Double = 0
    var exports = 0
    var documentsAdded = 0
    var pagesAdded = 0
    var launches = 0
    var activeDays = 0

    var totalSeconds: Double {
        speechSeconds + listeningSeconds
    }

    mutating func add(_ day: DayUsage) {
        speechCount += day.speechCount
        speechWords += day.speechWords
        speechChars += day.speechChars
        speechSeconds += day.speechSeconds
        listeningSeconds += day.listeningSeconds
        exports += day.exports
        documentsAdded += day.documentsAdded
        pagesAdded += day.pagesAdded
        launches += day.launches
        if day.isActive {
            activeDays += 1
        }
    }
}

struct ActivityPoint: Identifiable, Equatable {
    let date: Date
    let speechMinutes: Double
    let listeningMinutes: Double

    var id: Date {
        date
    }

    var totalMinutes: Double {
        speechMinutes + listeningMinutes
    }
}

struct HeatmapDay: Identifiable, Equatable {
    let date: Date
    let minutes: Double
    let isActive: Bool
    let isFuture: Bool

    var id: Date {
        date
    }
}

struct RankedVoice: Identifiable, Equatable {
    let voice: String
    let usage: VoiceUsage
    let share: Double

    var id: String {
        voice
    }
}

struct RankedBook: Identifiable, Equatable {
    let bookID: String
    let seconds: Double

    var id: String {
        bookID
    }
}

struct Milestone: Equatable {
    let title: String
    let current: Double
    let target: Double
    let reached: [Double]

    var progress: Double {
        target > 0 ? min(1, current / target) : 1
    }
}

struct UsageSummary: Equatable {
    let range: StatsRange
    let interval: DateInterval
    let totals: UsageTotals
    let previous: UsageTotals?
    let series: [ActivityPoint]
    let hours: [Double]
    let weekdays: [Double]
    let voices: [RankedVoice]
    let favoriteSpeed: Double?
    let books: [RankedBook]
    let currentStreak: Int
    let longestStreak: Int
    let busiestDay: (date: Date, minutes: Double)?
    let lifetime: UsageTotals
    let firstRecorded: Date?

    static func == (lhs: UsageSummary, rhs: UsageSummary) -> Bool {
        lhs.range == rhs.range && lhs.interval == rhs.interval && lhs.totals == rhs.totals
            && lhs.previous == rhs.previous && lhs.series == rhs.series && lhs.hours == rhs.hours
            && lhs.voices == rhs.voices && lhs.books == rhs.books && lhs.currentStreak == rhs.currentStreak
            && lhs.longestStreak == rhs.longestStreak && lhs.lifetime == rhs.lifetime
    }

    var peakHour: Int? {
        guard let peak = hours.max(), peak > 0 else { return nil }
        return hours.firstIndex(of: peak)
    }

    var peakWeekday: Int? {
        guard let peak = weekdays.max(), peak > 0 else { return nil }
        return weekdays.firstIndex(of: peak)
    }

    var isEmpty: Bool {
        lifetime.speechCount == 0 && lifetime.listeningSeconds < 1 && lifetime.documentsAdded == 0
    }

    static func change(_ current: Double, _ previous: Double?) -> Double? {
        guard let previous, previous > 0 else { return nil }
        return (current - previous) / previous
    }

    static func make(ledger: UsageLedger, range: StatsRange, now: Date, calendar: Calendar) -> UsageSummary {
        let interval = range.interval(endingAt: now, firstRecorded: ledger.firstRecorded, calendar: calendar)
        let previousInterval = range.previousInterval(before: interval, calendar: calendar)
        var dated: [(date: Date, day: DayUsage)] = ledger.days.compactMap { key, day in
            UsageLedger.date(forKey: key, calendar: calendar).map { ($0, day) }
        }
        dated.sort { $0.date < $1.date }

        var totals = UsageTotals()
        var previous = previousInterval.map { _ in UsageTotals() }
        var lifetime = UsageTotals()
        var hours = Array(repeating: 0.0, count: 24)
        var weekdays = Array(repeating: 0.0, count: 7)
        var voices: [String: VoiceUsage] = [:]
        var speeds: [String: Int] = [:]
        var books: [String: Double] = [:]
        var buckets: [Date: (speech: Double, listening: Double)] = [:]
        var busiest: (date: Date, minutes: Double)?

        for (date, day) in dated {
            lifetime.add(day)
            if let previousInterval, previousInterval.contains(date), date < previousInterval.end {
                previous?.add(day)
            }
            guard date >= interval.start, date < interval.end else { continue }
            totals.add(day)
            for hour in 0 ..< 24 {
                hours[hour] += day.hours[hour]
            }
            weekdays[(calendar.component(.weekday, from: date) + 5) % 7] += day.hours.reduce(0, +)
            for (voice, usage) in day.voices {
                voices[voice] = (voices[voice] ?? VoiceUsage()) + usage
            }
            for (speed, count) in day.speeds {
                speeds[speed, default: 0] += count
            }
            for (book, seconds) in day.books {
                books[book, default: 0] += seconds
            }
            let bucket = calendar.dateInterval(of: range.bucket, for: date)!.start
            let existing = buckets[bucket] ?? (0, 0)
            buckets[bucket] = (existing.speech + day.speechSeconds / 60, existing.listening + day.listeningSeconds / 60)
            let minutes = day.activeSeconds / 60
            if minutes > 0, minutes > (busiest?.minutes ?? 0) {
                busiest = (date, minutes)
            }
        }

        var series: [ActivityPoint] = []
        var cursor = interval.start
        while cursor < interval.end {
            let value = buckets[cursor] ?? (0, 0)
            series.append(ActivityPoint(date: cursor, speechMinutes: value.speech, listeningMinutes: value.listening))
            cursor = calendar.date(byAdding: range.bucket, value: 1, to: cursor)!
        }

        let totalUses = max(1, voices.values.reduce(0) { $0 + $1.uses })
        let rankedVoices = voices
            .map { RankedVoice(voice: $0.key, usage: $0.value, share: Double($0.value.uses) / Double(totalUses)) }
            .sorted { ($0.usage.uses, $0.usage.seconds, $1.voice) > ($1.usage.uses, $1.usage.seconds, $0.voice) }
        let favoriteSpeed = speeds.max { ($0.value, $1.key) < ($1.value, $0.key) }.flatMap { Double($0.key) }
        let rankedBooks = books
            .map { RankedBook(bookID: $0.key, seconds: $0.value) }
            .sorted { ($0.seconds, $1.bookID) > ($1.seconds, $0.bookID) }

        let streaks = Self.streaks(ledger: ledger, now: now, calendar: calendar)
        return UsageSummary(
            range: range,
            interval: interval,
            totals: totals,
            previous: previous,
            series: series,
            hours: hours,
            weekdays: weekdays,
            voices: rankedVoices,
            favoriteSpeed: favoriteSpeed,
            books: rankedBooks,
            currentStreak: streaks.current,
            longestStreak: streaks.longest,
            busiestDay: busiest,
            lifetime: lifetime,
            firstRecorded: ledger.firstRecorded
        )
    }

    static func streaks(ledger: UsageLedger, now: Date, calendar: Calendar) -> (current: Int, longest: Int) {
        let active = Set(ledger.days.filter(\.value.isActive).keys)
        guard !active.isEmpty else { return (0, 0) }
        let sorted = active.compactMap { UsageLedger.date(forKey: $0, calendar: calendar) }.sorted()
        var longest = 0
        var run = 0
        var previous: Date?
        for date in sorted {
            if let previous, calendar.date(byAdding: .day, value: 1, to: previous) == date {
                run += 1
            } else {
                run = 1
            }
            longest = max(longest, run)
            previous = date
        }
        var current = 0
        var cursor = calendar.startOfDay(for: now)
        if !active.contains(UsageLedger.dayKey(for: cursor, calendar: calendar)) {
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor)!
        }
        while active.contains(UsageLedger.dayKey(for: cursor, calendar: calendar)) {
            current += 1
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor)!
        }
        return (current, longest)
    }

    static func heatmap(ledger: UsageLedger, weeks: Int, now: Date, calendar: Calendar) -> [[HeatmapDay]] {
        let today = calendar.startOfDay(for: now)
        let weekday = (calendar.component(.weekday, from: today) + 5) % 7
        let thisMonday = calendar.date(byAdding: .day, value: -weekday, to: today)!
        let firstMonday = calendar.date(byAdding: .weekOfYear, value: -(weeks - 1), to: thisMonday)!
        return (0 ..< weeks).map { week in
            (0 ..< 7).map { offset in
                let date = calendar.date(byAdding: .day, value: week * 7 + offset, to: firstMonday)!
                let day = ledger.days[UsageLedger.dayKey(for: date, calendar: calendar)]
                return HeatmapDay(
                    date: date,
                    minutes: (day?.activeSeconds ?? 0) / 60,
                    isActive: day?.isActive ?? false,
                    isFuture: date > today
                )
            }
        }
    }

    static let wordMilestones: [Double] = [1000, 10000, 50000, 100_000, 250_000, 500_000, 1_000_000, 5_000_000]
    static let hourMilestones: [Double] = [1, 5, 10, 25, 50, 100, 250, 500, 1000]

    static func milestone(title: String, value: Double, ladder: [Double]) -> Milestone {
        let reached = ladder.filter { value >= $0 }
        let target = ladder.first { value < $0 } ?? ladder.last ?? 0
        return Milestone(title: title, current: value, target: target, reached: reached)
    }
}

struct LibraryStats: Equatable {
    var books = 0
    var ready = 0
    var inProgress = 0
    var pages = 0
    var words = 0
    var audioSeconds: Double = 0
    var processingSeconds: Double = 0
    var cleanupCostUsd: Double = 0
    var tokens = 0
    var cleanedBooks = 0
    var longest: (title: String, seconds: Double)?
    var voices: [String: Int] = [:]

    static func == (lhs: LibraryStats, rhs: LibraryStats) -> Bool {
        lhs.books == rhs.books && lhs.ready == rhs.ready && lhs.pages == rhs.pages && lhs.words == rhs.words
            && lhs.audioSeconds == rhs.audioSeconds && lhs.cleanupCostUsd == rhs.cleanupCostUsd
            && lhs.tokens == rhs.tokens && lhs.longest?.title == rhs.longest?.title
    }

    init() {}

    init(books library: [Audiobook]) {
        books = library.count
        for book in library {
            pages += book.pageCount
            if book.displayStatus.isReady {
                ready += 1
            } else if book.displayStatus.isProcessing {
                inProgress += 1
            }
            if let actual = book.actual {
                words += actual.words
                processingSeconds += actual.processingSeconds
                tokens += actual.tokensUsed
                cleanupCostUsd += actual.costUsd
            } else if let estimated = book.estimated {
                words += book.displayStatus.isReady ? estimated.words : 0
            }
            if book.requiresLLMCleanup, book.actual != nil {
                cleanedBooks += 1
            }
            audioSeconds += book.totalAudioSeconds
            if book.totalAudioSeconds > (longest?.seconds ?? 0) {
                longest = (book.displayTitle, book.totalAudioSeconds)
            }
            voices[book.voice, default: 0] += 1
        }
    }
}
