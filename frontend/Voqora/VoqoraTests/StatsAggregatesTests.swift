@testable import Voqora
import XCTest

@MainActor
final class StatsAggregatesTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Phoenix")!
        calendar.firstWeekday = 2
        return calendar
    }

    private func date(_ day: Int, hour: Int = 12, month: Int = 10) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }

    private func dictation(words: Int, seconds: Double?, outcome: String = "pasted", language: String? = "en", app: String? = "Notes") -> DictationSession {
        DictationSession(
            text: Array(repeating: "word", count: words).joined(separator: " "),
            seconds: seconds,
            outcome: outcome,
            language: language,
            app: app,
            tidied: false
        )
    }

    private func speech(words: Int, seconds: Double, engine: String = "kokoro", firstAudioMs: Double? = 300, render: Double = 2) -> (SpeechSample, SpeechRun) {
        (
            SpeechSample(text: Array(repeating: "w", count: words).joined(separator: " "), voice: "af_bella", speed: 1, audioSeconds: seconds),
            SpeechRun(engine: engine, source: .selection, firstAudioMs: firstAudioMs, renderSeconds: render)
        )
    }

    func test_quarterRangeCovers90DaysAndComparesAgainstThePrecedingNinety() throws {
        let now = date(15)
        let interval = StatsRange.quarter.interval(endingAt: now, firstRecorded: nil, calendar: calendar)
        XCTAssertEqual(calendar.dateComponents([.day], from: interval.start, to: interval.end).day, 90)
        let previous = StatsRange.quarter.previousInterval(before: interval, calendar: calendar)
        XCTAssertEqual(previous?.end, interval.start)
        XCTAssertEqual(try calendar.dateComponents([.day], from: XCTUnwrap(previous?.start), to: XCTUnwrap(previous?.end)).day, 90)
        XCTAssertEqual(StatsRange.quarter.comparisonLabel, "vs previous 90 days")
        XCTAssertEqual(StatsRange.quarter.bucket, .day)
        XCTAssertNil(StatsRange.all.comparisonLabel)
    }

    func test_rangesPickOnlyTheirOwnDaysAndKeepThePreviousPeriodSeparate() {
        var ledger = UsageLedger()
        let pair = speech(words: 10, seconds: 60)
        ledger.recordSpeech(pair.0, run: pair.1, at: date(15), calendar: calendar)
        ledger.recordSpeech(pair.0, run: pair.1, at: date(5), calendar: calendar)
        ledger.recordSpeech(pair.0, run: pair.1, at: date(5, month: 9), calendar: calendar)

        let week = StatsAggregates.make(ledger: ledger, range: .week, now: date(15), calendar: calendar)
        XCTAssertEqual(week.current.speechCount, 1)
        XCTAssertEqual(week.previous?.speechCount, 1)
        XCTAssertEqual(week.timeline.count, 7)
        XCTAssertEqual(week.comparison, "vs previous 7 days")

        let quarter = StatsAggregates.make(ledger: ledger, range: .quarter, now: date(15), calendar: calendar)
        XCTAssertEqual(quarter.current.speechCount, 3)
        XCTAssertEqual(quarter.timeline.count, 90)

        let all = StatsAggregates.make(ledger: ledger, range: .all, now: date(15), calendar: calendar)
        XCTAssertNil(all.previous)
        XCTAssertNil(all.comparison)
        XCTAssertEqual(all.lifetime.speechCount, 3)
    }

    func test_changeComparesCurrentAgainstPreviousAndIsNilWithoutABaseline() {
        var ledger = UsageLedger()
        for _ in 0 ..< 3 {
            let pair = speech(words: 10, seconds: 60)
            ledger.recordSpeech(pair.0, run: pair.1, at: date(14), calendar: calendar)
        }
        let pair = speech(words: 10, seconds: 60)
        ledger.recordSpeech(pair.0, run: pair.1, at: date(5), calendar: calendar)
        let week = StatsAggregates.make(ledger: ledger, range: .week, now: date(15), calendar: calendar)
        XCTAssertEqual(week.change { Double($0.speechCount) } ?? 0, 2, accuracy: 0.0001)
        let empty = StatsAggregates.make(ledger: UsageLedger(), range: .week, now: date(15), calendar: calendar)
        XCTAssertNil(empty.change { Double($0.speechCount) })
    }

    func test_timeSavedUsesReadingAndTypingSpeedsAndNeverGoesNegative() {
        var ledger = UsageLedger()
        let fast = speech(words: 476, seconds: 60)
        ledger.recordSpeech(fast.0, run: fast.1, at: date(15), calendar: calendar)
        ledger.recordDictation(dictation(words: 80, seconds: 30), at: date(15), calendar: calendar)
        let aggregates = StatsAggregates.make(ledger: ledger, range: .week, now: date(15), calendar: calendar)
        let current = aggregates.current
        XCTAssertEqual(current.readingEquivalentSeconds, 120, accuracy: 0.001)
        XCTAssertEqual(current.listeningSavedSeconds, 60, accuracy: 0.001)
        XCTAssertEqual(current.typingEquivalentSeconds, 120, accuracy: 0.001)
        XCTAssertEqual(current.dictationSavedSeconds, 90, accuracy: 0.001)
        XCTAssertEqual(current.totalSavedSeconds, 150, accuracy: 0.001)

        var slow = UsageLedger()
        let crawl = speech(words: 100, seconds: 600)
        slow.recordSpeech(crawl.0, run: crawl.1, at: date(15), calendar: calendar)
        slow.recordDictation(dictation(words: 10, seconds: 600), at: date(15), calendar: calendar)
        let slowCurrent = StatsAggregates.make(ledger: slow, range: .week, now: date(15), calendar: calendar).current
        XCTAssertEqual(slowCurrent.listeningSavedSeconds, 0)
        XCTAssertEqual(slowCurrent.dictationSavedSeconds, 0)
    }

    func test_untimedDictationWordsDoNotInflateTimeSavedOrWPM() {
        var ledger = UsageLedger()
        ledger.recordDictation(dictation(words: 60, seconds: 30), at: date(15), calendar: calendar)
        ledger.recordDictation(dictation(words: 500, seconds: nil), at: date(15), calendar: calendar)
        let current = StatsAggregates.make(ledger: ledger, range: .week, now: date(15), calendar: calendar).current
        XCTAssertEqual(current.dictation.words, 560)
        XCTAssertEqual(current.dictation.wordsPerMinute ?? 0, 120, accuracy: 0.001)
        XCTAssertEqual(current.typingEquivalentSeconds, 90, accuracy: 0.001)
    }

    func test_wordsPerMinuteTrendIsPerBucketAndSkipsDaysWithoutTimedSessions() {
        var ledger = UsageLedger()
        ledger.recordDictation(dictation(words: 100, seconds: 60), at: date(13), calendar: calendar)
        ledger.recordDictation(dictation(words: 50, seconds: 60), at: date(13, hour: 15), calendar: calendar)
        ledger.recordDictation(dictation(words: 90, seconds: nil), at: date(14), calendar: calendar)
        let timeline = StatsAggregates.make(ledger: ledger, range: .week, now: date(15), calendar: calendar).timeline
        XCTAssertEqual(timeline.compactMap(\.wordsPerMinute).count, 1)
        XCTAssertEqual(timeline.first { $0.wordsPerMinute != nil }?.wordsPerMinute ?? 0, 75, accuracy: 0.001)
        XCTAssertEqual(timeline.first { $0.date == calendar.startOfDay(for: date(14)) }?.dictationWords, 90)
    }

    func test_hourWeekdayMatrixBucketsMinutesByMondayFirstWeekdayAndHour() {
        var ledger = UsageLedger()
        let monday = date(12, hour: 9)
        ledger.recordListening(bookID: "b", seconds: 1800, at: monday, calendar: calendar)
        ledger.recordDictation(dictation(words: 30, seconds: 600), at: monday, calendar: calendar)
        let sunday = date(11, hour: 22)
        ledger.recordListening(bookID: "b", seconds: 120, at: sunday, calendar: calendar)
        let aggregates = StatsAggregates.make(ledger: ledger, range: .week, now: date(15), calendar: calendar)
        XCTAssertEqual(aggregates.hourWeekday.count, 7)
        XCTAssertEqual(aggregates.hourWeekday[0][9], 40, accuracy: 0.001)
        XCTAssertEqual(aggregates.hourWeekday[6][22], 2, accuracy: 0.001)
        XCTAssertEqual(aggregates.peakWeekday, 0)
        XCTAssertEqual(aggregates.peakHour, 9)
        XCTAssertEqual(aggregates.hourWeekdayPeak, 40, accuracy: 0.001)
    }

    func test_contributionLevelsQuantiseAgainstThePeakAndMarkMonths() {
        XCTAssertEqual(Contributions.level(minutes: 0, isActive: false, peak: 100), 0)
        XCTAssertEqual(Contributions.level(minutes: 0, isActive: true, peak: 100), 1)
        XCTAssertEqual(Contributions.level(minutes: 20, isActive: true, peak: 100), 1)
        XCTAssertEqual(Contributions.level(minutes: 40, isActive: true, peak: 100), 2)
        XCTAssertEqual(Contributions.level(minutes: 60, isActive: true, peak: 100), 3)
        XCTAssertEqual(Contributions.level(minutes: 100, isActive: true, peak: 100), 4)

        var ledger = UsageLedger()
        ledger.recordListening(bookID: "b", seconds: 6000, at: date(14), calendar: calendar)
        ledger.recordListening(bookID: "b", seconds: 60, at: date(13), calendar: calendar)
        let grid = Contributions.make(ledger: ledger, weeks: 26, now: date(15), calendar: calendar)
        XCTAssertEqual(grid.cells.count, 26 * 7)
        XCTAssertEqual(grid.cells.first { $0.date == calendar.startOfDay(for: date(14)) }?.level, 4)
        XCTAssertEqual(grid.cells.first { $0.date == calendar.startOfDay(for: date(13)) }?.level, 1)
        XCTAssertEqual(grid.activeDays, 2)
        XCTAssertTrue(grid.cells.filter(\.isFuture).allSatisfy { $0.level == 0 })
        XCTAssertGreaterThanOrEqual(grid.monthLabels.count, 6)
        let weeks = grid.monthLabels.map(\.week)
        XCTAssertTrue(zip(weeks, weeks.dropFirst()).allSatisfy { $1 - $0 >= 3 })
    }

    func test_engineRowsReportRealTimeFactorLatencyAndFailureRate() {
        var ledger = UsageLedger()
        let kokoro = speech(words: 100, seconds: 60, engine: "kokoro", firstAudioMs: 200, render: 5)
        let supertonic = speech(words: 100, seconds: 60, engine: "supertonic", firstAudioMs: 1400, render: 20)
        ledger.recordSpeech(kokoro.0, run: kokoro.1, at: date(15), calendar: calendar)
        ledger.recordSpeech(kokoro.0, run: kokoro.1, at: date(14), calendar: calendar)
        ledger.recordSpeech(supertonic.0, run: supertonic.1, at: date(15), calendar: calendar)
        ledger.recordSpeechFailure(engine: "supertonic", at: date(15), calendar: calendar)

        let aggregates = StatsAggregates.make(ledger: ledger, range: .week, now: date(15), calendar: calendar)
        XCTAssertEqual(aggregates.engines.map(\.id), ["kokoro", "supertonic"])
        let first = aggregates.engines[0]
        XCTAssertEqual(first.usage.realTimeFactor ?? 0, 12, accuracy: 0.001)
        XCTAssertEqual(first.usage.averageFirstAudioMs ?? 0, 200, accuracy: 0.001)
        XCTAssertEqual(first.usage.firstAudioBuckets[LatencyBuckets.index(forMs: 200)], 2)
        XCTAssertEqual(first.share, 2.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(first.failureRate ?? 1, 0, accuracy: 0.0001)
        let second = aggregates.engines[1]
        XCTAssertEqual(second.usage.realTimeFactor ?? 0, 3, accuracy: 0.001)
        XCTAssertEqual(second.failureRate ?? 0, 0.5, accuracy: 0.0001)
        XCTAssertEqual(aggregates.fastestEngine?.id, "kokoro")
        XCTAssertEqual(aggregates.quickestStartEngine?.id, "kokoro")
        XCTAssertEqual(aggregates.timeline.last?.engineUses["kokoro"], 1)
    }

    func test_fastestEngineFollowsTheDataRatherThanTheName() {
        var ledger = UsageLedger()
        let kokoro = speech(words: 100, seconds: 60, engine: "kokoro", render: 30)
        let supertonic = speech(words: 100, seconds: 60, engine: "supertonic", render: 3)
        ledger.recordSpeech(kokoro.0, run: kokoro.1, at: date(15), calendar: calendar)
        ledger.recordSpeech(supertonic.0, run: supertonic.1, at: date(15), calendar: calendar)
        XCTAssertEqual(StatsAggregates.make(ledger: ledger, range: .week, now: date(15), calendar: calendar).fastestEngine?.id, "supertonic")
    }

    func test_aiAndCreationRollUpAcrossTheRange() {
        var ledger = UsageLedger()
        ledger.recordAI(AIRun(tool: "summarize", provider: "openai", ok: true, latencyMs: 1000, wordsIn: 100, wordsOut: 20), at: date(15), calendar: calendar)
        ledger.recordAI(AIRun(tool: "ask", provider: "openai", ok: true, latencyMs: 3000, wordsIn: 50, wordsOut: 10), at: date(14), calendar: calendar)
        ledger.recordAI(AIRun(tool: "ask", provider: "anthropic", ok: false, latencyMs: 0, wordsIn: 0, wordsOut: 0), at: date(14), calendar: calendar)
        ledger.recordBookGenerated(chapters: 10, audioSeconds: 3600, renderSeconds: 360, at: date(15), calendar: calendar)
        ledger.recordPodcastRender(speakers: 2, audioSeconds: 600, at: date(15), calendar: calendar)
        ledger.recordImport(kind: "pdf", at: date(15), calendar: calendar)

        let current = StatsAggregates.make(ledger: ledger, range: .week, now: date(15), calendar: calendar).current
        XCTAssertEqual(current.ai.totalRequests, 3)
        XCTAssertEqual(current.ai.averageLatencyMs ?? 0, 2000, accuracy: 0.001)
        XCTAssertEqual(current.aiSuccessRate ?? 0, 2.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(current.ai.providers["openai"], 2)
        XCTAssertEqual(current.renderSpeed ?? 0, 10, accuracy: 0.001)
        XCTAssertEqual(current.creation.chaptersGenerated, 10)
        XCTAssertEqual(current.creation.imports["pdf"], 1)
        XCTAssertEqual(current.creation.podcastRenders, 1)
    }

    func test_emptyLedgerProducesZeroedAggregatesAndAFriendlyNarrative() {
        let aggregates = StatsAggregates.make(ledger: UsageLedger(), range: .month, now: date(15), calendar: calendar)
        XCTAssertFalse(aggregates.current.hasActivity)
        XCTAssertFalse(aggregates.lifetime.hasActivity)
        XCTAssertEqual(aggregates.timeline.count, 30)
        XCTAssertEqual(aggregates.timeline.map(\.totalMinutes).reduce(0, +), 0)
        XCTAssertEqual(aggregates.hourWeekdayPeak, 0)
        XCTAssertNil(aggregates.peakHour)
        XCTAssertNil(aggregates.peakWeekday)
        XCTAssertNil(aggregates.fastestEngine)
        XCTAssertTrue(aggregates.engines.isEmpty)
        XCTAssertNil(aggregates.current.aiSuccessRate)
        XCTAssertNil(aggregates.current.renderSpeed)
        XCTAssertEqual(aggregates.currentStreak, 0)
        XCTAssertEqual(aggregates.recentWeek, Array(repeating: false, count: 7))
        XCTAssertTrue(aggregates.narrative(voiceName: { $0 }, weekdayName: { "Day \($0)" }).hasPrefix("Nothing was recorded in the past 30 days."))
        XCTAssertEqual(aggregates.contributions.activeDays, 0)
    }

    func test_narrativeMentionsVoiceDictationAndComparison() {
        var ledger = UsageLedger()
        let pair = speech(words: 100, seconds: 60)
        ledger.recordSpeech(pair.0, run: pair.1, at: date(14, hour: 9), calendar: calendar)
        ledger.recordSpeech(pair.0, run: pair.1, at: date(5, hour: 9), calendar: calendar)
        ledger.recordDictation(dictation(words: 120, seconds: 60), at: date(14, hour: 9), calendar: calendar)
        let aggregates = StatsAggregates.make(ledger: ledger, range: .week, now: date(15), calendar: calendar)
        let text = aggregates.narrative(voiceName: { _ in "Bella" }, weekdayName: { _ in "Wednesday" })
        XCTAssertTrue(text.contains("Bella was your most-used voice"))
        XCTAssertTrue(text.contains("You dictated 120 words"))
        XCTAssertTrue(text.contains("120 words per minute"))
        XCTAssertTrue(text.contains("vs previous 7 days"))
        XCTAssertTrue(text.contains("9 AM"))
    }

    func test_streakAndRecentWeekReflectTheLatestDays() {
        var ledger = UsageLedger()
        for day in [13, 14, 15] {
            let pair = speech(words: 5, seconds: 5)
            ledger.recordSpeech(pair.0, run: pair.1, at: date(day), calendar: calendar)
        }
        let aggregates = StatsAggregates.make(ledger: ledger, range: .week, now: date(15), calendar: calendar)
        XCTAssertEqual(aggregates.currentStreak, 3)
        XCTAssertEqual(aggregates.recentWeek, [false, false, false, false, true, true, true])
    }

    func test_summaryNowCountsDictationAndAIAsActivity() {
        var ledger = UsageLedger()
        ledger.recordDictation(dictation(words: 5, seconds: 2), at: date(15), calendar: calendar)
        let summary = UsageSummary.make(ledger: ledger, range: .quarter, now: date(15), calendar: calendar)
        XCTAssertFalse(summary.isEmpty)
        XCTAssertEqual(summary.totals.dictationWords, 5)
        XCTAssertEqual(summary.series.count, 90)
    }

    func test_legacyDaySplitsMergedHoursByTimeShare() {
        var ledger = UsageLedger()
        ledger.update(at: date(14), calendar: calendar) { day in
            day.hours[9] = 2400
            day.speechSeconds = 600
            day.listeningSeconds = 1800
        }
        let day = ledger.days[UsageLedger.dayKey(for: date(14), calendar: calendar)] ?? DayUsage()
        XCTAssertEqual(day.audiobookHours[9], 1800, accuracy: 0.001)
        XCTAssertEqual(day.readAloudHours[9], 600, accuracy: 0.001)
    }

    func test_newFormatDaySeparatesReadAloudFromAudiobooksExactly() {
        var ledger = UsageLedger()
        let pair = speech(words: 20, seconds: 600)
        ledger.recordSpeech(pair.0, run: pair.1, at: date(14, hour: 9), calendar: calendar)
        ledger.recordListening(bookID: "b", seconds: 1800, at: date(14, hour: 9), calendar: calendar)
        let day = ledger.days[UsageLedger.dayKey(for: date(14), calendar: calendar)] ?? DayUsage()
        XCTAssertEqual(day.listeningHours[9], 1800, accuracy: 0.0001)
        XCTAssertEqual(day.audiobookHours[9], 1800, accuracy: 0.0001)
        XCTAssertEqual(day.readAloudHours[9], 600, accuracy: 0.0001)
    }

    func test_upgradeDayMixesLegacyHoursWithNewListeningHours() {
        var ledger = UsageLedger()
        ledger.update(at: date(14), calendar: calendar) { day in
            day.hours[8] = 1200
            day.speechSeconds = 300
            day.listeningSeconds = 900
        }
        ledger.recordListening(bookID: "b", seconds: 600, at: date(14, hour: 10), calendar: calendar)
        let day = ledger.days[UsageLedger.dayKey(for: date(14), calendar: calendar)] ?? DayUsage()
        XCTAssertEqual(day.audiobookHours[8], 900, accuracy: 0.001)
        XCTAssertEqual(day.readAloudHours[8], 300, accuracy: 0.001)
        XCTAssertEqual(day.audiobookHours[10], 600, accuracy: 0.001)
        XCTAssertEqual(day.readAloudHours[10], 0, accuracy: 0.001)
        XCTAssertEqual(day.audiobookHours.reduce(0, +) + day.readAloudHours.reduce(0, +), day.hours.reduce(0, +), accuracy: 0.001)
    }

    func test_separatedHoursNeverGoNegativeAndAlwaysSumToTheMergedTotal() {
        var damaged = DayUsage()
        damaged.listeningSeconds = 100
        damaged.listeningHours[3] = 100
        XCTAssertTrue(damaged.audiobookHours.allSatisfy { $0 >= 0 })
        XCTAssertTrue(damaged.readAloudHours.allSatisfy { $0 >= 0 })

        var ledger = UsageLedger()
        let pair = speech(words: 20, seconds: 120)
        ledger.recordSpeech(pair.0, run: pair.1, at: date(14, hour: 7), calendar: calendar)
        ledger.recordListening(bookID: "b", seconds: 500, at: date(14, hour: 7), calendar: calendar)
        ledger.recordListening(bookID: "b", seconds: 250, at: date(14, hour: 20), calendar: calendar)
        let day = ledger.days[UsageLedger.dayKey(for: date(14), calendar: calendar)] ?? DayUsage()
        XCTAssertEqual(day.readAloudHours.reduce(0, +) + day.audiobookHours.reduce(0, +), day.hours.reduce(0, +), accuracy: 0.001)
    }

    func test_productMatricesStayIsolatedAndAddUpToTheMergedMatrix() {
        var ledger = UsageLedger()
        let monday = date(12, hour: 9)
        ledger.recordDictation(dictation(words: 30, seconds: 600), at: monday, calendar: calendar)
        var aggregates = StatsAggregates.make(ledger: ledger, range: .week, now: date(15), calendar: calendar)
        XCTAssertEqual(aggregates.dictationHourWeekday[0][9], 10, accuracy: 0.001)
        XCTAssertEqual(aggregates.readAloudHourWeekday.matrixPeak, 0)
        XCTAssertEqual(aggregates.audiobookHourWeekday.matrixPeak, 0)

        let pair = speech(words: 20, seconds: 300)
        ledger.recordSpeech(pair.0, run: pair.1, at: date(13, hour: 14), calendar: calendar)
        ledger.recordListening(bookID: "b", seconds: 1200, at: date(14, hour: 21), calendar: calendar)
        aggregates = StatsAggregates.make(ledger: ledger, range: .week, now: date(15), calendar: calendar)
        XCTAssertEqual(aggregates.readAloudHourWeekday[1][14], 5, accuracy: 0.001)
        XCTAssertEqual(aggregates.audiobookHourWeekday[2][21], 20, accuracy: 0.001)
        XCTAssertEqual(aggregates.dictationHourWeekday[1][14], 0)
        XCTAssertEqual(aggregates.dictationHourWeekday[2][21], 0)
        XCTAssertEqual(aggregates.readAloudHourWeekday[2][21], 0)
        XCTAssertEqual(aggregates.audiobookHourWeekday[1][14], 0)
        for weekday in 0 ..< 7 {
            for hour in 0 ..< 24 {
                let parts = aggregates.readAloudHourWeekday[weekday][hour] + aggregates.audiobookHourWeekday[weekday][hour] + aggregates.dictationHourWeekday[weekday][hour]
                XCTAssertEqual(parts, aggregates.hourWeekday[weekday][hour], accuracy: 0.001)
            }
        }
    }

    func test_listeningHoursDecodeToZerosWhenTheKeyIsMissing() throws {
        let old = Data(#"{"speechCount":2,"listeningSeconds":60,"hours":[]}"#.utf8)
        let decoded = try JSONDecoder().decode(DayUsage.self, from: old)
        XCTAssertEqual(decoded.listeningHours, Array(repeating: 0, count: 24))
        XCTAssertEqual(decoded.listeningSeconds, 60)

        var ledger = UsageLedger()
        ledger.recordListening(bookID: "b", seconds: 90, at: date(14, hour: 5), calendar: calendar)
        let day = try XCTUnwrap(ledger.days.values.first)
        let roundTripped = try JSONDecoder().decode(DayUsage.self, from: JSONEncoder().encode(day))
        XCTAssertEqual(roundTripped.listeningHours[5], 90, accuracy: 0.0001)
    }

    func test_timelineCarriesSpeechAndPodcastFieldsThroughTheQuarterWeeklyMerge() {
        var ledger = UsageLedger()
        let pair = speech(words: 10, seconds: 30)
        for day in [12, 13] {
            ledger.recordSpeech(pair.0, run: pair.1, at: date(day), calendar: calendar)
            ledger.recordPodcastScript(at: date(day), calendar: calendar)
        }
        let week = StatsAggregates.make(ledger: ledger, range: .week, now: date(15), calendar: calendar)
        XCTAssertEqual(week.timeline.map(\.speechWords).reduce(0, +), 20)
        XCTAssertEqual(week.timeline.map(\.speechCount).reduce(0, +), 2)
        XCTAssertEqual(week.timeline.map(\.podcastScripts).reduce(0, +), 2)

        let quarter = StatsAggregates.make(ledger: ledger, range: .quarter, now: date(15), calendar: calendar)
        XCTAssertLessThan(quarter.trend.count, quarter.timeline.count)
        XCTAssertEqual(quarter.trend.map(\.speechWords).reduce(0, +), 20)
        XCTAssertEqual(quarter.trend.map(\.speechCount).reduce(0, +), 2)
        XCTAssertEqual(quarter.trend.map(\.podcastScripts).reduce(0, +), 2)
    }

    func test_narrativeLinesKeepReadAloudAndAudiobooksSeparate() {
        var ledger = UsageLedger()
        let pair = speech(words: 100, seconds: 120)
        ledger.recordSpeech(pair.0, run: pair.1, at: date(14, hour: 9), calendar: calendar)
        ledger.recordListening(bookID: "b", seconds: 3600, at: date(14, hour: 20), calendar: calendar)
        ledger.recordDictation(dictation(words: 120, seconds: 60), at: date(14, hour: 9), calendar: calendar)
        let aggregates = StatsAggregates.make(ledger: ledger, range: .week, now: date(15), calendar: calendar)
        let lines = aggregates.narrativeLines(voiceName: { _ in "Bella" }, weekdayName: { _ in "Wednesday" })
        let readAloud = lines.first { $0.product == .readAloud }
        let audiobooks = lines.first { $0.product == .audiobooks }
        XCTAssertNotNil(readAloud)
        XCTAssertNotNil(audiobooks)
        XCTAssertTrue(readAloud?.text.contains("Bella was your most-used voice") ?? false)
        XCTAssertTrue(readAloud?.text.contains("2 minutes") ?? false)
        XCTAssertFalse(readAloud?.text.contains("audiobook") ?? true)
        XCTAssertTrue(audiobooks?.text.contains("listened to audiobooks for 1 hour") ?? false)
        XCTAssertNotNil(lines.first { $0.product == .dictation })
        XCTAssertEqual(aggregates.narrative(voiceName: { _ in "Bella" }, weekdayName: { _ in "Wednesday" }), lines.map(\.text).joined(separator: " "))
    }

    func test_rangesExposeShortLabelsAndThePreviousPeriodName() {
        XCTAssertEqual(StatsRange.allCases.map(\.shortTitle), ["7D", "30D", "90D", "1Y", "All"])
        XCTAssertEqual(StatsRange.week.previousPeriodName, "previous 7 days")
        XCTAssertEqual(StatsRange.week.comparisonLabel, "vs previous 7 days")
        XCTAssertNil(StatsRange.all.previousPeriodName)
    }
}
