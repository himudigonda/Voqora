@testable import Voqora
import XCTest

@MainActor
final class UsageStatsTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Phoenix")!
        return calendar
    }

    private func date(_ day: Int, hour: Int = 12, month: Int = 10) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("voqora-usage-tests-\(UUID().uuidString).json")
    }

    func test_recordSpeechCountsWordsVoiceSpeedAndHour() {
        var ledger = UsageLedger()
        ledger.recordSpeech(SpeechSample(text: "one two  three\nfour", voice: "af_bella", speed: 1.24, audioSeconds: 12), at: date(15, hour: 21), calendar: calendar)
        let day = ledger.days["2026-10-15"]
        XCTAssertEqual(day?.speechCount, 1)
        XCTAssertEqual(day?.speechWords, 4)
        XCTAssertEqual(day?.speechSeconds, 12)
        XCTAssertEqual(day?.hours[21], 12)
        XCTAssertEqual(day?.voices["af_bella"], VoiceUsage(uses: 1, words: 4, seconds: 12))
        XCTAssertEqual(day?.speeds["1.25"], 1)
        XCTAssertEqual(ledger.firstRecorded, date(15, hour: 21))
    }

    func test_summaryTotalsOnlyCountTheRangeAndComparePreviousPeriod() {
        var ledger = UsageLedger()
        ledger.recordSpeech(SpeechSample(text: "a b c", voice: "af_bella", speed: 1, audioSeconds: 60), at: date(15), calendar: calendar)
        ledger.recordListening(bookID: "book", seconds: 600, at: date(10), calendar: calendar)
        ledger.recordSpeech(SpeechSample(text: "old words", voice: "bm_george", speed: 1, audioSeconds: 30), at: date(5), calendar: calendar)
        ledger.recordSpeech(SpeechSample(text: "much older", voice: "bm_george", speed: 1, audioSeconds: 30), at: date(1, month: 9), calendar: calendar)

        let summary = UsageSummary.make(ledger: ledger, range: .week, now: date(15), calendar: calendar)
        XCTAssertEqual(summary.series.count, 7)
        XCTAssertEqual(summary.totals.speechCount, 1)
        XCTAssertEqual(summary.totals.listeningSeconds, 600)
        XCTAssertEqual(summary.totals.activeDays, 2)
        XCTAssertEqual(summary.previous?.speechCount, 1)
        XCTAssertEqual(summary.lifetime.speechCount, 3)
        XCTAssertEqual(summary.books, [RankedBook(bookID: "book", seconds: 600)])
        XCTAssertEqual(summary.voices.map(\.voice), ["af_bella"])
        XCTAssertEqual(summary.busiestDay?.date, calendar.startOfDay(for: date(10)))
        XCTAssertEqual(UsageSummary.change(660, 30), 21)
    }

    func test_yearRangeBucketsByMonth() {
        var ledger = UsageLedger()
        ledger.recordListening(bookID: "b", seconds: 120, at: date(3, month: 2), calendar: calendar)
        let summary = UsageSummary.make(ledger: ledger, range: .year, now: date(15), calendar: calendar)
        XCTAssertEqual(summary.series.count, 12)
        XCTAssertEqual(summary.series.first { $0.listeningMinutes > 0 }?.date, date(1, hour: 0, month: 2))
    }

    func test_streaksCountConsecutiveActiveDaysAndAllowTodayToBeQuiet() {
        var ledger = UsageLedger()
        for day in [3, 4, 5, 6, 12, 13, 14] {
            ledger.recordSpeech(SpeechSample(text: "hi", voice: "af_bella", speed: 1, audioSeconds: 2), at: date(day), calendar: calendar)
        }
        let streaks = UsageSummary.streaks(ledger: ledger, now: date(15), calendar: calendar)
        XCTAssertEqual(streaks.current, 3)
        XCTAssertEqual(streaks.longest, 4)
        XCTAssertEqual(UsageSummary.streaks(ledger: ledger, now: date(17), calendar: calendar).current, 0)
    }

    func test_heatmapStartsOnMondayAndMarksFutureDays() {
        let heatmap = UsageSummary.heatmap(ledger: UsageLedger(), weeks: 4, now: date(15), calendar: calendar)
        XCTAssertEqual(heatmap.count, 4)
        XCTAssertEqual(calendar.component(.weekday, from: heatmap[0][0].date), 2)
        XCTAssertEqual(heatmap[3].filter(\.isFuture).count, 3)
    }

    func test_milestonePicksNextTargetAndReachedSteps() {
        let milestone = UsageSummary.milestone(title: "Words", value: 12000, ladder: UsageSummary.wordMilestones)
        XCTAssertEqual(milestone.target, 50000)
        XCTAssertEqual(milestone.reached, [1000, 10000])
        XCTAssertEqual(milestone.progress, 0.24, accuracy: 0.0001)
    }

    func test_listeningTicksAccumulateWallClockAndIgnoreGaps() {
        let store = UsageStatsStore(storageURL: temporaryURL(), calendar: calendar, saveDelay: .seconds(60))
        let start = date(15)
        store.listeningTick(bookID: "book", isPlaying: true, now: start)
        store.listeningTick(bookID: "book", isPlaying: true, now: start.addingTimeInterval(2))
        store.listeningTick(bookID: "book", isPlaying: true, now: start.addingTimeInterval(4))
        store.listeningTick(bookID: "book", isPlaying: true, now: start.addingTimeInterval(60))
        store.listeningTick(bookID: "book", isPlaying: true, now: start.addingTimeInterval(61))
        store.listeningTick(bookID: "book", isPlaying: false, now: start.addingTimeInterval(62))
        XCTAssertEqual(store.ledger.days["2026-10-15"]?.listeningSeconds ?? 0, 6, accuracy: 0.001)
        XCTAssertEqual(store.ledger.days["2026-10-15"]?.books["book"] ?? 0, 6, accuracy: 0.001)
    }

    func test_listeningSwitchesBooksWithoutMixingTime() {
        let store = UsageStatsStore(storageURL: temporaryURL(), calendar: calendar, saveDelay: .seconds(60))
        let start = date(15)
        store.listeningTick(bookID: "a", isPlaying: true, now: start)
        store.listeningTick(bookID: "a", isPlaying: true, now: start.addingTimeInterval(3))
        store.listeningTick(bookID: "b", isPlaying: true, now: start.addingTimeInterval(4))
        store.listeningTick(bookID: "b", isPlaying: true, now: start.addingTimeInterval(5))
        store.listeningTick(bookID: nil, isPlaying: false, now: start.addingTimeInterval(6))
        let books = store.ledger.days["2026-10-15"]?.books ?? [:]
        XCTAssertEqual(books["a"] ?? 0, 3, accuracy: 0.001)
        XCTAssertEqual(books["b"] ?? 0, 1, accuracy: 0.001)
    }

    func test_storePersistsAndImportsHistoryOnce() {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = UsageStatsStore(storageURL: url, calendar: calendar)
        let entries = [HistoryEntry(text: "hello there world", voice: "af_sarah")]
        writer.importHistoryIfNeeded(entries)
        writer.importHistoryIfNeeded(entries)
        writer.recordExport(at: date(15))
        writer.saveNow()

        let reader = UsageStatsStore(storageURL: url, calendar: calendar)
        let lifetime = UsageSummary.make(ledger: reader.ledger, range: .all, now: Date(), calendar: calendar).lifetime
        XCTAssertEqual(lifetime.speechCount, 1)
        XCTAssertEqual(lifetime.speechWords, 3)
        XCTAssertEqual(lifetime.exports, 1)
        XCTAssertTrue(reader.ledger.importedHistory)
    }

    func test_eraseRemovesFileAndBlocksLaterSaves() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = UsageStatsStore(storageURL: url, calendar: calendar)
        store.recordLaunch()
        store.saveNow()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        try store.eraseAll()
        store.recordLaunch()
        store.saveNow()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(store.ledger.days.isEmpty)
    }

    func test_recordingStaysBlockedAfterEraseUntilResumed() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = UsageStatsStore(storageURL: url, calendar: calendar)
        store.recordLaunch()
        try store.eraseAll()
        store.recordLaunch(at: date(15))
        XCTAssertTrue(store.ledger.days.isEmpty)
    }

    func test_recordingResumesAfterFailedErase() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = UsageStatsStore(storageURL: url, calendar: calendar)
        store.recordLaunch()
        try store.eraseAll()

        store.resumeAfterFailedErase()
        store.recordLaunch(at: date(15))
        store.saveNow()

        XCTAssertEqual(store.ledger.days["2026-10-15"]?.launches, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func test_previousWeekKeepsItsFirstDayAcrossDaylightSavingStart() throws {
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let now = try XCTUnwrap(newYork.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 12)))
        let current = StatsRange.week.interval(endingAt: now, firstRecorded: nil, calendar: newYork)

        let previous = StatsRange.week.previousInterval(before: current, calendar: newYork)

        XCTAssertEqual(previous?.start, newYork.date(from: DateComponents(year: 2026, month: 2, day: 25)))
        XCTAssertEqual(previous?.end, current.start)

        var ledger = UsageLedger()
        let oldestDay = try XCTUnwrap(newYork.date(from: DateComponents(year: 2026, month: 2, day: 25, hour: 9)))
        ledger.recordSpeech(SpeechSample(text: "a b", voice: "af_bella", speed: 1, audioSeconds: 10), at: oldestDay, calendar: newYork)
        let summary = UsageSummary.make(ledger: ledger, range: .week, now: now, calendar: newYork)
        XCTAssertEqual(summary.previous?.speechCount, 1)
    }

    func test_previousMonthKeepsItsFirstDayAcrossDaylightSavingStart() throws {
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let now = try XCTUnwrap(newYork.date(from: DateComponents(year: 2026, month: 3, day: 20, hour: 12)))
        let current = StatsRange.month.interval(endingAt: now, firstRecorded: nil, calendar: newYork)

        let previous = StatsRange.month.previousInterval(before: current, calendar: newYork)

        XCTAssertEqual(previous?.start, newYork.date(from: DateComponents(year: 2026, month: 1, day: 20)))
    }

    func test_unreadableFileIsSetAsideAndReported() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not json".utf8).write(to: url)
        let store = UsageStatsStore(storageURL: url, calendar: calendar)
        XCTAssertNotNil(store.persistenceError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func test_formattersReadNaturally() {
        XCTAssertEqual(StatsFormat.duration(0), "0m")
        XCTAssertEqual(StatsFormat.duration(42), "42s")
        XCTAssertEqual(StatsFormat.duration(3 * 3600 + 25 * 60), "3h 25m")
        XCTAssertEqual(StatsFormat.change(0.256), "+26%")
        XCTAssertEqual(StatsFormat.change(-0.5), "-50%")
        XCTAssertNil(StatsFormat.change(nil))
        XCTAssertEqual(StatsFormat.voiceDetail("bm_george"), "British · Male")
    }

    func test_libraryStatsSumsBooks() throws {
        let json = """
        [{"book_id":"1","title":"A.pdf","created_at":"","page_count":10,"status":"done",
          "phase_progress":{"page_done":10,"page_total":10},"sections":[],"page_to_time":{},
          "total_audio_seconds":3600,"failed_pages":[],"engine":"kokoro","voice":"af_bella","speed":1,
          "uses_gemini_cleanup":true,
          "actual":{"pages":10,"words":5000,"audio_seconds":3600,"processing_seconds":120,"sections":2,"tokens_used":900,"cost_usd":0.02}},
         {"book_id":"2","title":"B.txt","created_at":"","page_count":3,"status":"tts",
          "phase_progress":{"page_done":1,"page_total":3},"sections":[],"page_to_time":{},
          "total_audio_seconds":0,"failed_pages":[],"engine":"kokoro","voice":"af_bella","speed":1}]
        """
        let books = try JSONDecoder().decode([Audiobook].self, from: Data(json.utf8))
        let stats = LibraryStats(books: books)
        XCTAssertEqual(stats.books, 2)
        XCTAssertEqual(stats.ready, 1)
        XCTAssertEqual(stats.inProgress, 1)
        XCTAssertEqual(stats.pages, 13)
        XCTAssertEqual(stats.words, 5000)
        XCTAssertEqual(stats.tokens, 900)
        XCTAssertEqual(stats.cleanupCostUsd, 0.02, accuracy: 0.0001)
        XCTAssertEqual(stats.longest?.title, "A")
    }
}
