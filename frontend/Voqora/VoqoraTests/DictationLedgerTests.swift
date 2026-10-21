@testable import Voqora
import XCTest

final class DictationLedgerTests: XCTestCase {
    func test_volatileRevisionsReplaceOnlyTheUncommittedTail() {
        var ledger = DictationLedger()
        ledger.commit("The meeting starts at nine.")
        ledger.revise("Please")
        ledger.revise("Please bring the")
        ledger.revise("Please bring the forecast")

        XCTAssertEqual(ledger.committed, "The meeting starts at nine.")
        XCTAssertEqual(ledger.text, "The meeting starts at nine. Please bring the forecast")
    }

    func test_committedTextIsAppendOnly() {
        var ledger = DictationLedger()
        var previous = ""
        for index in 0 ..< 500 {
            ledger.revise("draft \(index)")
            if index.isMultiple(of: 3) {
                ledger.commit("Sentence \(index).")
            }
            XCTAssertTrue(ledger.committed.hasPrefix(previous))
            previous = ledger.committed
        }
        XCTAssertEqual(ledger.committedSegments, 167)
    }

    func test_repeatedPhrasesAreKeptVerbatim() {
        var ledger = DictationLedger()
        ledger.commit("Please make a note of that.")
        ledger.commit("Please make a note of that.")
        ledger.commit("Yes, yes, that is correct.")

        XCTAssertEqual(ledger.text, "Please make a note of that. Please make a note of that. Yes, yes, that is correct.")
    }

    func test_emptySegmentsCommitNothingButClearTheTail() {
        var ledger = DictationLedger()
        ledger.revise("maybe")
        ledger.commit("   ")

        XCTAssertEqual(ledger.committed, "")
        XCTAssertEqual(ledger.committedSegments, 0)
    }

    func test_interruptionSealsTheTail() {
        var ledger = DictationLedger()
        ledger.commit("First.")
        ledger.revise("second half")
        ledger.sealAfterInterruption()

        XCTAssertEqual(ledger.committed, "First. second half")
        XCTAssertEqual(ledger.volatile, "")
    }

    func test_partialFinalKeepsTheUncoveredTailVisibleUntilTheNextRevision() {
        var ledger = DictationLedger()
        ledger.revise("we need to decide on the vendor")
        ledger.commit("We need to decide.")

        XCTAssertEqual(ledger.text, "We need to decide. on the vendor")
        ledger.revise("On the vendor")
        XCTAssertEqual(ledger.text, "We need to decide. On the vendor")
    }

    func test_interruptionRightAfterAPartialFinalKeepsTheTail() {
        var ledger = DictationLedger()
        ledger.revise("we need to decide on the vendor")
        ledger.commit("We need to decide.")
        ledger.sealAfterInterruption()

        XCTAssertEqual(ledger.committed, "We need to decide. on the vendor")
    }

    func test_recognitionEndDropsAStaleTailButKeepsUnfinalizedText() {
        var shorterFinal = DictationLedger()
        shorterFinal.revise("going to go now")
        shorterFinal.commit("Gonna go now.")
        shorterFinal.sealAfterRecognitionEnded()
        XCTAssertEqual(shorterFinal.committed, "Gonna go now.")

        var neverFinalized = DictationLedger()
        neverFinalized.commit("First.")
        neverFinalized.revise("still volatile")
        neverFinalized.sealAfterRecognitionEnded()
        XCTAssertEqual(neverFinalized.committed, "First. still volatile")
    }

    func test_joiningRespectsPunctuationAndUnspacedScripts() {
        XCTAssertEqual(DictationLedger.joined("Hello", ", world"), "Hello, world")
        XCTAssertEqual(DictationLedger.joined("Hello.", "World"), "Hello. World")
        XCTAssertEqual(DictationLedger.joined("今日は", "晴れです。"), "今日は晴れです。")
        XCTAssertEqual(DictationLedger.joined("", "Start"), "Start")
    }
}

final class LegacyTranscriptSegmenterTests: XCTestCase {
    private func replay(_ partials: [String], final: String) -> String {
        var segmenter = LegacyTranscriptSegmenter()
        var ledger = DictationLedger()
        let apply: (SpeechRecognitionEvent) -> Void = { event in
            switch event {
            case let .volatile(text): ledger.revise(text)
            case let .finalized(text): ledger.commit(text)
            default: break
            }
        }
        partials.forEach { segmenter.ingest($0).forEach(apply) }
        segmenter.finalize(final).forEach(apply)
        return ledger.text
    }

    func test_resultThatRestartsAfterAPauseCommitsTheEarlierSentence() {
        let text = replay([
            "The quarterly",
            "The quarterly planning meeting starts at nine",
            "The quarterly planning meeting starts at nine tomorrow.",
            "We",
            "We agreed that",
            "We agreed that the release will slip.",
        ], final: "We agreed that the release will slip.")

        XCTAssertEqual(text, "The quarterly planning meeting starts at nine tomorrow. We agreed that the release will slip.")
    }

    func test_ordinaryRevisionsAreNotTreatedAsRestarts() {
        XCTAssertFalse(LegacyTranscriptSegmenter.isRestart(previous: "I scream for", next: "Ice cream for"))
        XCTAssertFalse(LegacyTranscriptSegmenter.isRestart(previous: "There are a lot", next: "Their a lot"))
        XCTAssertFalse(LegacyTranscriptSegmenter.isRestart(previous: "Hello", next: "Hi"))
        XCTAssertTrue(LegacyTranscriptSegmenter.isRestart(previous: "The payment flow still has three open defects", next: "Marketing"))
        XCTAssertTrue(LegacyTranscriptSegmenter.isRestart(previous: "The payment flow still has", next: "The"))
    }

    func test_finalResultCarryingOnlyTheLastUtteranceKeepsEverythingBefore() {
        let text = replay(["Remember the milk and the eggs", "Also"], final: "Also call mom.")

        XCTAssertEqual(text, "Remember the milk and the eggs Also call mom.")
    }

    func test_emptyFinalCommitsTheLastHypothesis() {
        XCTAssertEqual(replay(["Draft one", "Draft one two"], final: ""), "Draft one two")
    }

    func test_recordedLegacyPauseResetsKeepEverySentence() throws {
        let events = try DictationFixtures.url("multi-paragraph-49s.legacy-events", "json")
        let recorded = try JSONDecoder().decode([RecordedRecognitionEvent].self, from: Data(contentsOf: events))
        let partials = recorded.filter { !$0.final }.map(\.text)
        let text = replay(partials, final: recorded.last { $0.final }?.text ?? "")
        let score = try TranscriptScoring.score(reference: DictationFixtures.reference("multi-paragraph-49s"), hypothesis: text)
        let lastResultOnly = try TranscriptScoring.score(
            reference: DictationFixtures.reference("multi-paragraph-49s"),
            hypothesis: recorded.last?.text ?? ""
        )

        XCTAssertGreaterThanOrEqual(lastResultOnly.droppedSentences, 10)
        XCTAssertEqual(score.droppedSentences, 0)
        XCTAssertEqual(score.deletions, 0)
        XCTAssertEqual(score.repeatedInsertions, 0)
        XCTAssertLessThanOrEqual(score.wordErrorRate, 0.04)
    }

    func test_flushCommitsWhatWasHeardWhenATaskDies() {
        var segmenter = LegacyTranscriptSegmenter()
        _ = segmenter.ingest("Half a thought")

        XCTAssertEqual(segmenter.flush(), [.finalized("Half a thought")])
        XCTAssertEqual(segmenter.flush(), [])
    }
}

final class DictationReplayTests: XCTestCase {
    private struct Replay {
        let inserted: String?
        let finals: [String]
        let committedShrank: Bool
        let liveTranscriptShrinks: Int
    }

    private func replay(_ events: [RecordedRecognitionEvent]) -> Replay {
        var machine = DictationStateMachine()
        _ = machine.handle(.toggle)
        _ = machine.handle(.ready)
        var finals: [String] = []
        var committed = ""
        var shrank = false
        var shrinks = 0
        var visibleWords = 0
        for event in events {
            if event.final {
                finals.append(event.text)
                _ = machine.handle(.segmentFinalized(event.text))
            } else {
                _ = machine.handle(.volatileChanged(event.text))
            }
            if !machine.ledger.committed.hasPrefix(committed) {
                shrank = true
            }
            committed = machine.ledger.committed
            let words = TranscriptScoring.words(machine.transcript).count
            if words < visibleWords - 3 {
                shrinks += 1
            }
            visibleWords = words
        }
        _ = machine.handle(.toggle)
        guard case let .insert(text) = machine.handle(.recognitionEnded) else {
            return Replay(inserted: nil, finals: finals, committedShrank: shrank, liveTranscriptShrinks: shrinks)
        }
        return Replay(inserted: text, finals: finals, committedShrank: shrank, liveTranscriptShrinks: shrinks)
    }

    private func assertNothingLost(
        _ fixture: String,
        maximumWordErrorRate: Double,
        recognizerDeletions: Int = 0,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let reference = try DictationFixtures.reference(fixture)
        let result = try replay(DictationFixtures.events(fixture))
        let inserted = try XCTUnwrap(result.inserted, file: file, line: line)

        XCTAssertFalse(result.committedShrank, "committed text was rewritten", file: file, line: line)
        XCTAssertEqual(result.liveTranscriptShrinks, 0, "live transcript lost words mid-session", file: file, line: line)
        XCTAssertEqual(inserted, result.finals.reduce("") { DictationLedger.joined($0, $1.trimmingCharacters(in: .whitespaces)) },
                       "inserted text must be every finalized segment exactly once, in order", file: file, line: line)

        let score = TranscriptScoring.score(reference: reference, hypothesis: inserted)
        XCTAssertEqual(score.droppedSentences, 0, file: file, line: line)
        XCTAssertLessThanOrEqual(score.deletions, recognizerDeletions, file: file, line: line)
        XCTAssertEqual(score.repeatedInsertions, 0, file: file, line: line)
        XCTAssertLessThanOrEqual(score.wordErrorRate, maximumWordErrorRate, file: file, line: line)
    }

    func test_tenMinuteSessionKeepsEverySentence() throws {
        try assertNothingLost("long-session-10min", maximumWordErrorRate: 0.01)
    }

    func test_multiParagraphSessionKeepsEverySentence() throws {
        try assertNothingLost("multi-paragraph-49s", maximumWordErrorRate: 0.04, recognizerDeletions: 1)
    }

    func test_fixtureDetectsTheLastResultWinsRegression() throws {
        let reference = try DictationFixtures.reference("long-session-10min")
        let lastResult = try DictationFixtures.events("long-session-10min").last?.text ?? ""
        let score = TranscriptScoring.score(reference: reference, hypothesis: lastResult)

        XCTAssertGreaterThan(score.droppedSentences, 140)
    }

    func test_recordingsStartAgainAfterEachFinalizedSegment() throws {
        let events = try DictationFixtures.events("long-session-10min")
        let finals = events.filter(\.final)

        XCTAssertGreaterThan(finals.count, 100)
        XCTAssertGreaterThan(events.count, finals.count * 3)
    }
}
