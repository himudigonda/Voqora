import Combine
import Foundation
@testable import Voqora
import XCTest

@MainActor
final class DictationStatsObserverTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private struct SentEvent {
        let words: Int
        let seconds: Double?
        let outcome: String
        let language: String?
        let tidied: Bool
    }

    private final class FlagBox {
        var value = false
    }

    private struct Harness {
        let phase = CurrentValueSubject<DictationPhase, Never>(.idle)
        let isTidying = CurrentValueSubject<Bool, Never>(false)
        let transcripts: CurrentValueSubject<[DictationTranscript], Never>
        let store: UsageStatsStore
        let clock: ClockBox
        let sent: Sent
    }

    private final class ClockBox {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    private final class Sent {
        var events: [SentEvent] = []
    }

    private var observers: [DictationStatsObserver] = []

    private func make(
        initial: [DictationTranscript] = [],
        outcome: @escaping @MainActor () -> String? = { nil },
        tidyFailed: @escaping @MainActor () -> Bool = { false },
        cancelledDuringTidy: @escaping @MainActor () -> Bool = { false }
    ) -> Harness {
        let store = UsageStatsStore(
            storageURL: FileManager.default.temporaryDirectory.appendingPathComponent("voqora-dictation-observer-\(UUID().uuidString).json"),
            calendar: calendar
        )
        let sent = Sent()
        let harness = Harness(transcripts: CurrentValueSubject(initial), store: store, clock: ClockBox(), sent: sent)
        let clock = harness.clock
        let observer = DictationStatsObserver(
            feed: DictationStatsObserver.Feed(
                phase: harness.phase.eraseToAnyPublisher(),
                isTidying: harness.isTidying.eraseToAnyPublisher(),
                transcripts: harness.transcripts.eraseToAnyPublisher(),
                currentTranscripts: { harness.transcripts.value },
                outcome: outcome,
                tidyFailed: tidyFailed,
                cancelledDuringTidy: cancelledDuringTidy
            ),
            usage: store,
            telemetry: DictationStatsObserver.Telemetry { words, seconds, outcome, language, tidied in
                sent.events.append(SentEvent(words: words, seconds: seconds, outcome: outcome, language: language, tidied: tidied))
            },
            now: { clock.now },
            frontmostAppName: { "Notes" }
        )
        observers.append(observer)
        return harness
    }

    private func transcript(_ text: String, locale: String? = "en_US") -> DictationTranscript {
        DictationTranscript(id: UUID(), text: text, createdAt: Date(), localeIdentifier: locale)
    }

    private func today(_ harness: Harness) -> DayUsage {
        let key = UsageLedger.dayKey(for: harness.clock.now, calendar: calendar)
        return harness.store.ledger.days[key] ?? DayUsage()
    }

    func test_sessionWithTranscriptRecordsSecondsWordsAppAndLanguage() {
        let harness = make(outcome: { "pasted" })
        harness.phase.send(.preparing)
        harness.phase.send(.listening)
        harness.clock.now.addTimeInterval(6)
        harness.phase.send(.finishing)
        harness.clock.now.addTimeInterval(1)
        harness.phase.send(.inserting)
        harness.transcripts.send([transcript("send the report tomorrow morning")])
        harness.phase.send(.idle)

        let dictation = today(harness).dictation
        XCTAssertEqual(dictation.sessions, 1)
        XCTAssertEqual(dictation.words, 5)
        XCTAssertEqual(dictation.seconds, 7, accuracy: 0.001)
        XCTAssertEqual(dictation.outcomes, ["pasted": 1])
        XCTAssertEqual(dictation.languages, ["en": 1])
        XCTAssertEqual(dictation.apps, ["Notes": 1])
        XCTAssertEqual(dictation.cancelled, 0)
        XCTAssertEqual(harness.sent.events.count, 1)
        XCTAssertEqual(harness.sent.events.first?.words, 5)
        XCTAssertEqual(harness.sent.events.first?.outcome, "pasted")
        XCTAssertEqual(harness.sent.events.first?.language, "en")
        XCTAssertEqual(harness.sent.events.first?.tidied, false)
        XCTAssertEqual(harness.sent.events.first?.seconds ?? 0, 7, accuracy: 0.001)
    }

    func test_missingOutcomeFallsBackToCopied() {
        let harness = make()
        harness.phase.send(.listening)
        harness.clock.now.addTimeInterval(2)
        harness.phase.send(.inserting)
        harness.transcripts.send([transcript("one two")])
        harness.phase.send(.idle)
        XCTAssertEqual(today(harness).dictation.outcomes, ["copied": 1])
        XCTAssertEqual(harness.sent.events.first?.outcome, "copied")
    }

    func test_transcriptArrivingAfterIdleIsStillRecorded() {
        let harness = make()
        harness.phase.send(.listening)
        harness.clock.now.addTimeInterval(4)
        harness.phase.send(.inserting)
        harness.phase.send(.idle)
        XCTAssertEqual(today(harness).dictation.cancelled, 0)
        harness.transcripts.send([transcript("saved after abandon")])
        XCTAssertEqual(today(harness).dictation.sessions, 1)
        XCTAssertEqual(today(harness).dictation.cancelled, 0)
    }

    func test_idleWithoutTranscriptRecordsCancellation() {
        let harness = make()
        harness.phase.send(.listening)
        harness.clock.now.addTimeInterval(3)
        harness.phase.send(.idle)

        let dictation = today(harness).dictation
        XCTAssertEqual(dictation.cancelled, 1)
        XCTAssertEqual(dictation.sessions, 0)
        XCTAssertEqual(dictation.outcomes["cancelled"], 1)
        XCTAssertEqual(harness.sent.events.count, 1)
        XCTAssertEqual(harness.sent.events.first?.outcome, "cancelled")
        XCTAssertEqual(harness.sent.events.first?.words, 0)
    }

    func test_preparingFailureWithoutListeningRecordsNothing() {
        let harness = make()
        harness.phase.send(.preparing)
        harness.phase.send(.idle)
        XCTAssertEqual(today(harness).dictation, DictationUsage())
        XCTAssertTrue(harness.sent.events.isEmpty)
    }

    func test_repeatedListeningEmissionsKeepOneSession() {
        let harness = make()
        harness.phase.send(.listening)
        harness.clock.now.addTimeInterval(2)
        harness.phase.send(.listening)
        harness.clock.now.addTimeInterval(2)
        harness.phase.send(.listening)
        harness.phase.send(.inserting)
        harness.transcripts.send([transcript("one two three")])
        harness.phase.send(.idle)
        XCTAssertEqual(today(harness).dictation.sessions, 1)
        XCTAssertEqual(today(harness).dictation.seconds, 4, accuracy: 0.001)
    }

    func test_cancellingDuringTidyCountsAsCancelled() {
        let harness = make(cancelledDuringTidy: { true })
        harness.phase.send(.listening)
        harness.phase.send(.inserting)
        harness.isTidying.send(true)
        harness.transcripts.send([transcript("kept in history only")])
        harness.isTidying.send(false)
        harness.phase.send(.idle)

        XCTAssertEqual(today(harness).dictation.sessions, 0)
        XCTAssertEqual(harness.sent.events.map(\.outcome), ["cancelled"])
        XCTAssertEqual(harness.sent.events.map(\.tidied), [false])
    }

    func test_tidiedSessionIsMarkedAndFailedTidyIsNot() {
        let failed = FlagBox()
        let harness = make(tidyFailed: { failed.value })
        harness.phase.send(.listening)
        harness.phase.send(.inserting)
        harness.isTidying.send(true)
        harness.isTidying.send(false)
        harness.transcripts.send([transcript("tidy words here")])
        harness.phase.send(.idle)

        harness.phase.send(.listening)
        harness.phase.send(.inserting)
        harness.isTidying.send(true)
        failed.value = true
        harness.transcripts.send([transcript("another set of words")] + harness.transcripts.value)
        harness.phase.send(.idle)

        XCTAssertEqual(harness.sent.events.map(\.tidied), [true, false])
        XCTAssertEqual(today(harness).dictation.tidied, 1)
    }

    func test_transcriptsOutsideASessionAreIgnored() {
        let harness = make()
        harness.transcripts.send([transcript("typed elsewhere")])
        harness.transcripts.send([])
        XCTAssertEqual(today(harness).dictation, DictationUsage())
        XCTAssertTrue(harness.sent.events.isEmpty)
    }

    func test_languageIsReducedToTheCodeAndMissingLocaleStaysNil() {
        let harness = make()
        harness.phase.send(.listening)
        harness.phase.send(.inserting)
        harness.transcripts.send([transcript("hola amigo", locale: "es-MX")])
        harness.phase.send(.idle)
        harness.phase.send(.listening)
        harness.phase.send(.inserting)
        harness.transcripts.send([transcript("no locale here", locale: nil)] + harness.transcripts.value)
        harness.phase.send(.idle)
        XCTAssertEqual(harness.sent.events.map(\.language), ["es", nil])
    }

    func test_importRunsOnceAcrossObservers() {
        let old = [
            DictationTranscript(id: UUID(), text: "first old note", createdAt: Date(timeIntervalSince1970: 1_700_000_000), localeIdentifier: "en_US"),
            DictationTranscript(id: UUID(), text: "second", createdAt: Date(timeIntervalSince1970: 1_700_100_000), localeIdentifier: nil),
        ]
        let harness = make(initial: old)
        let total = harness.store.ledger.days.values.reduce(0) { $0 + $1.dictation.sessions }
        XCTAssertEqual(total, 2)
        XCTAssertTrue(harness.store.ledger.importedDictation)

        let again = DictationStatsObserver(
            feed: DictationStatsObserver.Feed(
                phase: harness.phase.eraseToAnyPublisher(),
                isTidying: harness.isTidying.eraseToAnyPublisher(),
                transcripts: harness.transcripts.eraseToAnyPublisher(),
                currentTranscripts: { old },
                outcome: { nil },
                tidyFailed: { false }
            ),
            usage: harness.store,
            telemetry: DictationStatsObserver.Telemetry { _, _, _, _, _ in }
        )
        observers.append(again)
        let afterSecond = harness.store.ledger.days.values.reduce(0) { $0 + $1.dictation.sessions }
        XCTAssertEqual(afterSecond, 2)
    }
}
