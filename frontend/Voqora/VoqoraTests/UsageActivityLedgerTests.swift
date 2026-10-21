@testable import Voqora
import XCTest

@MainActor
final class UsageActivityLedgerTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Phoenix")!
        return calendar
    }

    private func date(_ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
    }

    private func day(_ ledger: UsageLedger, _ day: Int = 15) -> DayUsage {
        ledger.days["2026-10-\(day)"] ?? DayUsage()
    }

    func test_recordSpeechWithRunTracksSourceEngineAndLatency() {
        var ledger = UsageLedger()
        let run = SpeechRun(engine: "kokoro", source: .clipboard, firstAudioMs: 300, renderSeconds: 2)
        ledger.recordSpeech(SpeechSample(text: "one two three", voice: "af_bella", speed: 1, audioSeconds: 6), run: run, at: date(15), calendar: calendar)
        let secondRun = SpeechRun(engine: "kokoro", source: .clipboard, firstAudioMs: nil, renderSeconds: 1)
        ledger.recordSpeech(SpeechSample(text: "four", voice: "af_bella", speed: 1, audioSeconds: 2), run: secondRun, at: date(15), calendar: calendar)

        let usage = day(ledger).speech
        XCTAssertEqual(usage.sources["clipboard"], 2)
        let engine = usage.engines["kokoro"]
        XCTAssertEqual(engine?.uses, 2)
        XCTAssertEqual(engine?.words, 4)
        XCTAssertEqual(engine?.audioSeconds, 8)
        XCTAssertEqual(engine?.renderSeconds, 3)
        XCTAssertEqual(engine?.firstAudioCount, 1)
        XCTAssertEqual(engine?.averageFirstAudioMs, 300)
        XCTAssertEqual(engine?.firstAudioBuckets[1], 1)
        XCTAssertEqual(engine?.realTimeFactor ?? 0, 8.0 / 3.0, accuracy: 0.0001)
    }

    func test_recordSpeechWithoutRunLeavesDetailUntouched() {
        var ledger = UsageLedger()
        ledger.recordSpeech(SpeechSample(text: "a b", voice: "af_bella", speed: 1, audioSeconds: 1), at: date(15), calendar: calendar)
        XCTAssertEqual(day(ledger).speech, SpeechDetail())
        XCTAssertEqual(day(ledger).speechCount, 1)
    }

    func test_recordSpeechFailureCountsPerEngineAndDay() {
        var ledger = UsageLedger()
        ledger.recordSpeechFailure(engine: "ming", at: date(15), calendar: calendar)
        ledger.recordSpeechFailure(engine: "ming", at: date(15), calendar: calendar)
        XCTAssertEqual(day(ledger).speech.failures, 2)
        XCTAssertEqual(day(ledger).speech.engines["ming"]?.failures, 2)
    }

    func test_recordRelayTrimsAndNamesBlankClients() {
        var ledger = UsageLedger()
        ledger.recordRelay(client: "  Claude Desktop ", at: date(15), calendar: calendar)
        ledger.recordRelay(client: "   ", at: date(15), calendar: calendar)
        ledger.recordRelay(client: String(repeating: "x", count: 80), at: date(15), calendar: calendar)
        let clients = day(ledger).speech.relayClients
        XCTAssertEqual(clients["Claude Desktop"], 1)
        XCTAssertEqual(clients["Unnamed"], 1)
        XCTAssertEqual(clients[String(repeating: "x", count: 48)], 1)
    }

    func test_recordDictationAggregatesSessionDetail() {
        var ledger = UsageLedger()
        let session = DictationSession(text: "hello brave new world", seconds: 8, outcome: "pasted", language: "en", app: "Notes", tidied: true)
        ledger.recordDictation(session, at: date(15, hour: 9), calendar: calendar)
        let usage = day(ledger).dictation
        XCTAssertEqual(usage.sessions, 1)
        XCTAssertEqual(usage.words, 4)
        XCTAssertEqual(usage.chars, 21)
        XCTAssertEqual(usage.seconds, 8)
        XCTAssertEqual(usage.timedWords, 4)
        XCTAssertEqual(usage.tidied, 1)
        XCTAssertEqual(usage.outcomes["pasted"], 1)
        XCTAssertEqual(usage.languages["en"], 1)
        XCTAssertEqual(usage.apps["Notes"], 1)
        XCTAssertEqual(usage.hours[9], 8)
        XCTAssertEqual(usage.wordsPerMinute ?? 0, 30, accuracy: 0.0001)
    }

    func test_recordDictationWithoutTimingFallsBackToOneSecond() {
        var ledger = UsageLedger()
        ledger.recordDictation(DictationSession(text: "two words", seconds: nil, outcome: "copied", language: nil, app: nil, tidied: false), at: date(15, hour: 3), calendar: calendar)
        let usage = day(ledger).dictation
        XCTAssertEqual(usage.seconds, 0)
        XCTAssertEqual(usage.timedWords, 0)
        XCTAssertEqual(usage.hours[3], 1)
        XCTAssertNil(usage.wordsPerMinute)
    }

    func test_recordDictationWithEmptyTextCountsAsCancelled() {
        var ledger = UsageLedger()
        ledger.recordDictation(DictationSession(text: "  ", seconds: 3, outcome: "empty", language: nil, app: nil, tidied: false), at: date(15), calendar: calendar)
        let usage = day(ledger).dictation
        XCTAssertEqual(usage.sessions, 0)
        XCTAssertEqual(usage.cancelled, 1)
        XCTAssertEqual(usage.outcomes["empty"], 1)
    }

    func test_recordDictationCancelledCountsOutcome() {
        var ledger = UsageLedger()
        ledger.recordDictationCancelled(at: date(15), calendar: calendar)
        XCTAssertEqual(day(ledger).dictation.cancelled, 1)
        XCTAssertEqual(day(ledger).dictation.outcomes["cancelled"], 1)
    }

    func test_recordAICountsSuccessAndFailureSeparately() {
        var ledger = UsageLedger()
        ledger.recordAI(AIRun(tool: "summarize", provider: "openai", ok: true, latencyMs: 1200, wordsIn: 10, wordsOut: 5), at: date(15), calendar: calendar)
        ledger.recordAI(AIRun(tool: "summarize", provider: "openai", ok: true, latencyMs: 800, wordsIn: 0, wordsOut: 0), at: date(15), calendar: calendar)
        ledger.recordAI(AIRun(tool: "ask", provider: "anthropic", ok: false, latencyMs: 5000, wordsIn: 0, wordsOut: 0), at: date(15), calendar: calendar)
        let ai = day(ledger).ai
        XCTAssertEqual(ai.requests, ["summarize": 2, "ask": 1])
        XCTAssertEqual(ai.failures, ["ask": 1])
        XCTAssertEqual(ai.providers, ["openai": 2, "anthropic": 1])
        XCTAssertEqual(ai.totalRequests, 3)
        XCTAssertEqual(ai.totalFailures, 1)
        XCTAssertEqual(ai.latencyCount, 2)
        XCTAssertEqual(ai.averageLatencyMs, 1000)
        XCTAssertEqual(ai.wordsIn, 10)
        XCTAssertEqual(ai.wordsOut, 5)
    }

    func test_creationRecordersAccumulate() {
        var ledger = UsageLedger()
        ledger.recordBookGenerated(chapters: 12, audioSeconds: 3600, renderSeconds: 900, at: date(15), calendar: calendar)
        ledger.recordBookGenerated(chapters: -3, audioSeconds: -1, renderSeconds: -1, at: date(15), calendar: calendar)
        ledger.recordBookFinished(at: date(15), calendar: calendar)
        ledger.recordPodcastScript(at: date(15), calendar: calendar)
        ledger.recordPodcastRender(speakers: 2, audioSeconds: 600, at: date(15), calendar: calendar)
        ledger.recordM4BExport(at: date(15), calendar: calendar)
        ledger.recordImport(kind: "pdf", at: date(15), calendar: calendar)
        ledger.recordImport(kind: "pdf", at: date(15), calendar: calendar)
        ledger.recordImport(kind: "web", at: date(15), calendar: calendar)
        let creation = day(ledger).creation
        XCTAssertEqual(creation.booksGenerated, 2)
        XCTAssertEqual(creation.chaptersGenerated, 12)
        XCTAssertEqual(creation.bookAudioSeconds, 3600)
        XCTAssertEqual(creation.bookRenderSeconds, 900)
        XCTAssertEqual(creation.booksFinished, 1)
        XCTAssertEqual(creation.podcastScripts, 1)
        XCTAssertEqual(creation.podcastRenders, 1)
        XCTAssertEqual(creation.podcastSpeakers, 2)
        XCTAssertEqual(creation.podcastAudioSeconds, 600)
        XCTAssertEqual(creation.m4bExports, 1)
        XCTAssertEqual(creation.imports, ["pdf": 2, "web": 1])
    }

    func test_importDictationHistoryRunsOnceAndKeepsLanguageOnly() {
        var ledger = UsageLedger()
        let transcripts = [
            DictationTranscript(id: UUID(), text: "hello there", createdAt: date(14), localeIdentifier: "en_US"),
            DictationTranscript(id: UUID(), text: "bonjour", createdAt: date(15), localeIdentifier: "fr-CA"),
        ]
        ledger.importDictationHistory(transcripts, calendar: calendar)
        ledger.importDictationHistory(transcripts, calendar: calendar)
        XCTAssertTrue(ledger.importedDictation)
        XCTAssertEqual(day(ledger, 14).dictation.sessions, 1)
        XCTAssertEqual(day(ledger, 14).dictation.languages, ["en": 1])
        XCTAssertEqual(day(ledger, 15).dictation.languages, ["fr": 1])
        XCTAssertEqual(day(ledger, 15).dictation.outcomes["imported"], 1)
    }

    func test_oldLedgerJSONWithoutNewKeysDecodesWithEmptyDetail() throws {
        let json = """
        {
          "firstRecorded": "2026-10-01T12:00:00Z",
          "importedHistory": true,
          "days": {
            "2026-10-01": {
              "speechCount": 3, "speechWords": 40, "speechChars": 200, "speechSeconds": 30.5,
              "listeningSeconds": 12, "exports": 1, "documentsAdded": 2, "pagesAdded": 9, "launches": 1,
              "hours": [0,0,0,0,0,0,0,0,0,0,0,0,5,0,0,0,0,0,0,0,0,0,0,0],
              "voices": {"af_bella": {"uses": 3, "words": 40, "seconds": 30.5}},
              "speeds": {"1.00": 3},
              "books": {"b1": 12}
            }
          }
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let ledger = try decoder.decode(UsageLedger.self, from: Data(json.utf8))
        let usage = try XCTUnwrap(ledger.days["2026-10-01"])
        XCTAssertEqual(usage.speechCount, 3)
        XCTAssertEqual(usage.speech, SpeechDetail())
        XCTAssertEqual(usage.dictation, DictationUsage())
        XCTAssertEqual(usage.creation, CreationUsage())
        XCTAssertEqual(usage.ai, AIActivity())
        XCTAssertFalse(ledger.importedDictation)
        XCTAssertEqual(usage.dictation.hours.count, 24)
        XCTAssertEqual(usage.dictation.lengths.count, DictationLengthBuckets.labels.count)
    }

    func test_newDetailRoundTripsThroughCodable() throws {
        var ledger = UsageLedger()
        let run = SpeechRun(engine: "kokoro", source: .app, firstAudioMs: 100, renderSeconds: 1)
        let session = DictationSession(text: "x y z", seconds: 3, outcome: "pasted", language: "en", app: nil, tidied: false)
        ledger.recordSpeech(SpeechSample(text: "a b", voice: "af_bella", speed: 1, audioSeconds: 2), run: run, at: date(15), calendar: calendar)
        ledger.recordDictation(session, at: date(15), calendar: calendar)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(UsageLedger.self, from: encoder.encode(ledger))
        XCTAssertEqual(decoded, ledger)
    }

    func test_corruptBucketArraysFallBackToZeros() throws {
        let json = #"{"firstAudioBuckets":[1,2],"uses":4}"#
        let usage = try JSONDecoder().decode(EngineUsage.self, from: Data(json.utf8))
        XCTAssertEqual(usage.uses, 4)
        XCTAssertEqual(usage.firstAudioBuckets, Array(repeating: 0, count: LatencyBuckets.labels.count))
    }

    func test_latencyBucketEdges() {
        XCTAssertEqual(LatencyBuckets.index(forMs: 0), 0)
        XCTAssertEqual(LatencyBuckets.index(forMs: 249.9), 0)
        XCTAssertEqual(LatencyBuckets.index(forMs: 250), 1)
        XCTAssertEqual(LatencyBuckets.index(forMs: 499), 1)
        XCTAssertEqual(LatencyBuckets.index(forMs: 500), 2)
        XCTAssertEqual(LatencyBuckets.index(forMs: 1999), 3)
        XCTAssertEqual(LatencyBuckets.index(forMs: 2000), 4)
        XCTAssertEqual(LatencyBuckets.index(forMs: 3999), 4)
        XCTAssertEqual(LatencyBuckets.index(forMs: 4000), 5)
        XCTAssertEqual(LatencyBuckets.index(forMs: 1_000_000), 5)
        XCTAssertEqual(LatencyBuckets.labels.count, LatencyBuckets.edgesMs.count + 1)
    }

    func test_dictationLengthBucketEdges() {
        XCTAssertEqual(DictationLengthBuckets.index(forWords: 0), 0)
        XCTAssertEqual(DictationLengthBuckets.index(forWords: 9), 0)
        XCTAssertEqual(DictationLengthBuckets.index(forWords: 10), 1)
        XCTAssertEqual(DictationLengthBuckets.index(forWords: 24), 1)
        XCTAssertEqual(DictationLengthBuckets.index(forWords: 25), 2)
        XCTAssertEqual(DictationLengthBuckets.index(forWords: 49), 2)
        XCTAssertEqual(DictationLengthBuckets.index(forWords: 50), 3)
        XCTAssertEqual(DictationLengthBuckets.index(forWords: 99), 3)
        XCTAssertEqual(DictationLengthBuckets.index(forWords: 100), 4)
        XCTAssertEqual(DictationLengthBuckets.index(forWords: 249), 4)
        XCTAssertEqual(DictationLengthBuckets.index(forWords: 250), 5)
        XCTAssertEqual(DictationLengthBuckets.labels.count, DictationLengthBuckets.edges.count + 1)
    }

    func test_mergeOperatorsSumEveryField() {
        var left = EngineUsage()
        left.uses = 1
        left.words = 2
        left.audioSeconds = 3
        left.renderSeconds = 1
        left.firstAudioCount = 1
        left.firstAudioMsTotal = 100
        left.firstAudioBuckets[0] = 1
        left.failures = 1
        var right = left
        right.firstAudioBuckets = Array(repeating: 0, count: LatencyBuckets.labels.count)
        right.firstAudioBuckets[5] = 2
        let engines = left + right
        XCTAssertEqual(engines.uses, 2)
        XCTAssertEqual(engines.words, 4)
        XCTAssertEqual(engines.audioSeconds, 6)
        XCTAssertEqual(engines.renderSeconds, 2)
        XCTAssertEqual(engines.firstAudioCount, 2)
        XCTAssertEqual(engines.firstAudioMsTotal, 200)
        XCTAssertEqual(engines.firstAudioBuckets[0], 1)
        XCTAssertEqual(engines.firstAudioBuckets[5], 2)
        XCTAssertEqual(engines.failures, 2)

        var speechLeft = SpeechDetail()
        speechLeft.sources = ["app": 1]
        speechLeft.engines = ["kokoro": left]
        speechLeft.relayClients = ["Cursor": 1]
        speechLeft.failures = 1
        var speechRight = SpeechDetail()
        speechRight.sources = ["app": 2, "ai": 1]
        speechRight.engines = ["kokoro": right, "ming": right]
        speechRight.relayClients = ["Cursor": 2]
        speechRight.failures = 2
        let speech = speechLeft + speechRight
        XCTAssertEqual(speech.sources, ["app": 3, "ai": 1])
        XCTAssertEqual(speech.engines["kokoro"]?.uses, 2)
        XCTAssertEqual(speech.engines["ming"]?.uses, 1)
        XCTAssertEqual(speech.relayClients, ["Cursor": 3])
        XCTAssertEqual(speech.failures, 3)

        var dictationLeft = DictationUsage()
        dictationLeft.sessions = 1
        dictationLeft.words = 10
        dictationLeft.hours[2] = 4
        dictationLeft.lengths[1] = 1
        dictationLeft.outcomes = ["pasted": 1]
        dictationLeft.apps = ["Notes": 1]
        var dictationRight = dictationLeft
        dictationRight.outcomes = ["copied": 1, "pasted": 1]
        let dictation = dictationLeft + dictationRight
        XCTAssertEqual(dictation.sessions, 2)
        XCTAssertEqual(dictation.words, 20)
        XCTAssertEqual(dictation.hours[2], 8)
        XCTAssertEqual(dictation.lengths[1], 2)
        XCTAssertEqual(dictation.outcomes, ["pasted": 2, "copied": 1])
        XCTAssertEqual(dictation.apps, ["Notes": 2])

        var creationLeft = CreationUsage()
        creationLeft.booksGenerated = 1
        creationLeft.imports = ["pdf": 1]
        var creationRight = creationLeft
        creationRight.imports = ["epub": 2, "pdf": 1]
        let creation = creationLeft + creationRight
        XCTAssertEqual(creation.booksGenerated, 2)
        XCTAssertEqual(creation.imports, ["pdf": 2, "epub": 2])

        var aiLeft = AIActivity()
        aiLeft.requests = ["ask": 1]
        aiLeft.latencyMsTotal = 100
        aiLeft.latencyCount = 1
        var aiRight = aiLeft
        aiRight.requests = ["ask": 1, "quiz": 1]
        let ai = aiLeft + aiRight
        XCTAssertEqual(ai.requests, ["ask": 2, "quiz": 1])
        XCTAssertEqual(ai.latencyMsTotal, 200)
        XCTAssertEqual(ai.latencyCount, 2)
    }

    func test_storeMethodsPersistThroughSaveAndReload() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voqora-activity-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = UsageStatsStore(storageURL: url, calendar: calendar)
        let when = date(15)
        store.recordRelay(client: "Cursor", at: when)
        store.recordSpeechFailure(engine: "kokoro", at: when)
        store.recordPodcastScript(at: when)
        store.recordAI(AIRun(tool: "tidy", provider: "openai", ok: true, latencyMs: 10, wordsIn: 0, wordsOut: 0), at: when)
        store.recordImport(kind: "inbox", at: when)
        store.saveNow()

        let reloaded = UsageStatsStore(storageURL: url, calendar: calendar)
        let usage = try XCTUnwrap(reloaded.ledger.days["2026-10-15"])
        XCTAssertEqual(usage.speech.relayClients["Cursor"], 1)
        XCTAssertEqual(usage.speech.failures, 1)
        XCTAssertEqual(usage.creation.podcastScripts, 1)
        XCTAssertEqual(usage.ai.requests["tidy"], 1)
        XCTAssertEqual(usage.creation.imports["inbox"], 1)
    }
}
