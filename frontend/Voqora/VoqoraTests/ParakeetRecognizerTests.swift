import AVFoundation
import FluidAudio
@testable import Voqora
import XCTest

final class ParakeetFakeTranscriber: ParakeetTranscribing, @unchecked Sendable {
    private let lock = NSLock()
    private var failuresRemaining: Int
    private let failingCalls: Set<Int>
    private var calls = 0
    private let delay: Duration

    init(failures: Int = 0, failingCalls: Set<Int> = [], delay: Duration = .zero) {
        failuresRemaining = failures
        self.failingCalls = failingCalls
        self.delay = delay
    }

    var callCount: Int {
        lock.withLock { calls }
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        let (call, shouldFail) = lock.withLock { () -> (Int, Bool) in
            calls += 1
            let fail = failuresRemaining > 0 || failingCalls.contains(calls)
            if failuresRemaining > 0 {
                failuresRemaining -= 1
            }
            return (calls, fail)
        }
        if delay > .zero {
            try await Task.sleep(for: delay)
        }
        if shouldFail {
            throw ASRError.processingFailed("scripted")
        }
        return "segment \(call) of \(samples.count)"
    }
}

@MainActor
enum ParakeetReplay {
    struct Outcome {
        let transcript: String
        let events: [SpeechRecognitionEvent]
        let audioSeconds: Double
        let wallSeconds: Double
        let peakFootprintMB: Double
    }

    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    static func installedTranscriber(_ model: LocalSpeechModel = .parakeet) async throws -> ParakeetAsrTranscriber {
        let store = LocalSpeechModelStore.store(for: model)
        guard store.isInstalled else { throw XCTSkip("The \(model.title) model is not installed") }
        let models = try await store.loadedModels()
        return ParakeetAsrTranscriber(manager: AsrManager(models: models))
    }

    static func run(url: URL, transcriber: any ParakeetTranscribing, maximumBacklog: Int = 3) async throws -> Outcome {
        let file = try AVAudioFile(forReading: url)
        let converter = try XCTUnwrap(ParakeetAudioConverter())
        let (stream, continuation) = AsyncStream<SpeechRecognitionEvent>.makeStream()
        let pipeline = ParakeetSegmentPipeline(transcriber: transcriber) { event in
            continuation.yield(event)
            if event == .ended || event == .failed {
                continuation.finish()
            }
        }
        let started = Date()
        var peak = footprintMB()
        let chunk = AVAudioFrameCount(file.processingFormat.sampleRate)
        while file.framePosition < file.length {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk))
            try file.read(into: buffer, frameCount: chunk)
            let samples = try XCTUnwrap(converter.convert(buffer))
            pipeline.append(samples)
            peak = max(peak, footprintMB())
            while pipeline.backlog > maximumBacklog {
                try await Task.sleep(for: .milliseconds(20))
            }
            await Task.yield()
        }
        pipeline.append(converter.flush())
        pipeline.finish()

        var ledger = DictationLedger()
        var events: [SpeechRecognitionEvent] = []
        for await event in stream {
            events.append(event)
            switch event {
            case let .volatile(text): ledger.revise(text)
            case let .finalized(text): ledger.commit(text)
            case .ended: ledger.sealAfterRecognitionEnded()
            case .level, .failed: break
            }
        }
        return Outcome(
            transcript: ledger.text,
            events: events,
            audioSeconds: Double(file.length) / file.processingFormat.sampleRate,
            wallSeconds: Date().timeIntervalSince(started),
            peakFootprintMB: max(peak, footprintMB())
        )
    }
}

@MainActor
final class ParakeetRecognizerTests: XCTestCase {
    private func speechSignal() -> [Float] {
        var samples: [Float] = []
        for index in 0 ..< 4 {
            let burst = (0 ..< 32000).map { 0.3 * sin(Float($0) * 2 * .pi * 220 / 16000) * (index.isMultiple(of: 2) ? 1 : 0.5) }
            samples += burst + [Float](repeating: 0, count: 16000)
        }
        return samples
    }

    private func finalizedTexts(_ events: [SpeechRecognitionEvent]) -> [String] {
        events.compactMap { event -> String? in
            guard case let .finalized(text) = event else { return nil }
            return text
        }
    }

    private func collect(_ transcriber: some ParakeetTranscribing) async -> [SpeechRecognitionEvent] {
        let (stream, continuation) = AsyncStream<SpeechRecognitionEvent>.makeStream()
        let pipeline = ParakeetSegmentPipeline(transcriber: transcriber) { event in
            continuation.yield(event)
            if event == .ended || event == .failed {
                continuation.finish()
            }
        }
        pipeline.append(speechSignal())
        pipeline.finish()
        var events: [SpeechRecognitionEvent] = []
        for await event in stream {
            events.append(event)
        }
        return events
    }

    private func collectWhileLoading(_ load: Task<any ParakeetTranscribing, Error>, release: () -> Void) async -> [SpeechRecognitionEvent] {
        let (stream, continuation) = AsyncStream<SpeechRecognitionEvent>.makeStream()
        let pipeline = ParakeetSegmentPipeline(transcriber: DeferredParakeetTranscriber(load: load)) { event in
            continuation.yield(event)
            if event == .ended || event == .failed {
                continuation.finish()
            }
        }
        pipeline.append(speechSignal())
        pipeline.finish()
        release()
        Task {
            if case .failure = await load.result {
                pipeline.failToLoad()
            }
        }
        var events: [SpeechRecognitionEvent] = []
        for await event in stream {
            events.append(event)
        }
        return events
    }

    func test_speechCapturedBeforeTheModelLoadsIsTranscribedOnceItDoes() async {
        let fake = ParakeetFakeTranscriber()
        let (gate, open) = AsyncStream<Void>.makeStream()
        let load = Task<any ParakeetTranscribing, Error> {
            for await _ in gate {
                break
            }
            return fake
        }
        let events = await collectWhileLoading(load) { open.yield() }

        XCTAssertEqual(finalizedTexts(events).count, 4)
        XCTAssertEqual(events.last, .ended)
        XCTAssertFalse(events.contains(.failed))
    }

    func test_aModelThatFailsToLoadEndsTheSessionWithFailedEvenAfterFinish() async {
        let load = Task<any ParakeetTranscribing, Error> {
            throw ASRError.processingFailed("compile failed")
        }
        let events = await collectWhileLoading(load) {}

        XCTAssertTrue(finalizedTexts(events).isEmpty)
        XCTAssertEqual(events.last, .failed)
        XCTAssertFalse(events.contains(.ended))
    }

    func test_finalsArriveOnceInOrderAndEndedComesLast() async {
        let events = await collect(ParakeetFakeTranscriber())
        let finals = events.compactMap { event -> Int? in
            guard case let .finalized(text) = event else { return nil }
            return text.split(separator: " ").dropFirst().first.flatMap { Int($0) }
        }
        XCTAssertEqual(finals.count, 4)
        XCTAssertEqual(finals, finals.sorted())
        XCTAssertEqual(events.last, .ended)
        XCTAssertEqual(events.filter { $0 == .ended }.count, 1)
        XCTAssertFalse(events.contains(.failed))
    }

    func test_segmentsAreTranscribedOnceEach() async {
        let transcriber = ParakeetFakeTranscriber()
        let events = await collect(transcriber)
        let finals = events.filter {
            if case .finalized = $0 {
                true
            } else {
                false
            }
        }
        XCTAssertEqual(finals.count, 4)
        XCTAssertEqual(transcriber.callCount, 4)
    }

    func test_oneTransientFailureIsRetriedAndNothingIsLost() async {
        let events = await collect(ParakeetFakeTranscriber(failures: 1))
        XCTAssertEqual(events.filter {
            if case .finalized = $0 {
                true
            } else {
                false
            }
        }.count, 4)
        XCTAssertEqual(events.last, .ended)
    }

    func test_aFailedSegmentIsSkippedAndTheOthersAreStillDelivered() async {
        let transcriber = ParakeetFakeTranscriber(failingCalls: [2, 3])
        let events = await collect(transcriber)
        XCTAssertEqual(finalizedTexts(events).map { $0.split(separator: " ")[1] }, ["1", "4", "5"])
        XCTAssertFalse(events.contains(.failed))
        XCTAssertEqual(events.last, .ended)
        XCTAssertEqual(transcriber.callCount, 5)
    }

    func test_aSkippedSegmentCommitsItsLastPreview() async {
        let transcriber = ParakeetFakeTranscriber(failingCalls: [2, 3])
        let (stream, continuation) = AsyncStream<SpeechRecognitionEvent>.makeStream()
        let pipeline = ParakeetSegmentPipeline(transcriber: transcriber) { event in
            continuation.yield(event)
            if event == .ended || event == .failed {
                continuation.finish()
            }
        }
        var iterator = stream.makeAsyncIterator()
        pipeline.append(Array(speechSignal().prefix(32000)))
        let first = await iterator.next()
        guard case let .volatile(preview)? = first else {
            return XCTFail("the preview was not emitted: \(String(describing: first))")
        }
        pipeline.append([Float](repeating: 0, count: 16000))
        pipeline.finish()
        var rest: [SpeechRecognitionEvent] = []
        while let event = await iterator.next() {
            rest.append(event)
        }
        XCTAssertEqual(finalizedTexts(rest), [preview])
        XCTAssertFalse(rest.contains(.failed))
        XCTAssertEqual(rest.last, .ended)
        XCTAssertEqual(transcriber.callCount, 3)
    }

    func test_twoFailuresInARowDoNotEndTheSession() async {
        let transcriber = ParakeetFakeTranscriber(failingCalls: [2, 3, 4, 5])
        let events = await collect(transcriber)
        XCTAssertEqual(finalizedTexts(events).count, 2)
        XCTAssertFalse(events.contains(.failed))
        XCTAssertEqual(events.last, .ended)
    }

    func test_threeFailuresInARowEndTheSessionWithFailedAndNoEnded() async {
        let transcriber = ParakeetFakeTranscriber(failingCalls: [2, 3, 4, 5, 6, 7])
        let events = await collect(transcriber)
        XCTAssertEqual(finalizedTexts(events).count, 1)
        XCTAssertEqual(events.last, .failed)
        XCTAssertFalse(events.contains(.ended))
        XCTAssertEqual(transcriber.callCount, 7)
    }

    func test_alwaysFailingTranscriberTriesEveryQueuedSegmentBeforeFailing() async {
        let transcriber = ParakeetFakeTranscriber(failures: .max)
        let events = await collect(transcriber)
        XCTAssertEqual(events, [.failed])
        XCTAssertEqual(transcriber.callCount, 8)
    }

    func test_cancelDeliversNothingAfterwards() async throws {
        let (stream, continuation) = AsyncStream<SpeechRecognitionEvent>.makeStream()
        let pipeline = ParakeetSegmentPipeline(transcriber: ParakeetFakeTranscriber(delay: .milliseconds(200))) { event in
            continuation.yield(event)
        }
        pipeline.append(speechSignal())
        pipeline.finish()
        pipeline.cancel()
        try await Task.sleep(for: .milliseconds(700))
        continuation.finish()
        var events: [SpeechRecognitionEvent] = []
        for await event in stream {
            events.append(event)
        }
        XCTAssertTrue(events.isEmpty)
    }

    func test_conversionFailureIsReportedAsFailed() async {
        let (stream, continuation) = AsyncStream<SpeechRecognitionEvent>.makeStream()
        let pipeline = ParakeetSegmentPipeline(transcriber: ParakeetFakeTranscriber()) { event in
            continuation.yield(event)
            continuation.finish()
        }
        pipeline.reportFailure()
        pipeline.append([0.1, 0.2])
        pipeline.finish()
        var events: [SpeechRecognitionEvent] = []
        for await event in stream {
            events.append(event)
        }
        XCTAssertEqual(events, [.failed])
    }

    func test_converterResamplesToSixteenKilohertzWithoutLosingAudio() throws {
        let source = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false))
        let converter = try XCTUnwrap(ParakeetAudioConverter())
        var produced = 0
        for _ in 0 ..< 470 {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 1024))
            buffer.frameLength = 1024
            for channel in 0 ..< 2 {
                for index in 0 ..< 1024 {
                    buffer.floatChannelData?[channel][index] = sin(Float(index) * 0.05) * 0.5
                }
            }
            produced += try XCTUnwrap(converter.convert(buffer)).count
        }
        produced += converter.flush().count
        XCTAssertEqual(Double(produced), Double(470 * 1024) / 3, accuracy: 96)
    }

    func test_downloadsModelOnlyWhenAskedTo() async throws {
        guard ProcessInfo.processInfo.environment["VOQORA_PARAKEET_DOWNLOAD"] == "1" else {
            throw XCTSkip("Set TEST_RUNNER_VOQORA_PARAKEET_DOWNLOAD=1 to download the Parakeet model")
        }
        let store = LocalSpeechModelStore.parakeet
        await store.download()
        XCTAssertEqual(store.state, .installed)
    }

    func test_startWithoutModelThrowsRecognizerUnavailable() async throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("parakeet-missing-\(UUID().uuidString)")
        let recognizer = ParakeetSpeechRecognizer(models: LocalSpeechModelStore(directory: missing))
        do {
            try await recognizer.start(localeIdentifier: nil, allowsServer: false) { _ in }
            XCTFail("start should throw")
        } catch {
            XCTAssertEqual(error as? DictationIssue, .recognizerUnavailable)
        }
    }

    func test_recordedAudioThroughSegmentsKeepsEverySentence() async throws {
        let transcriber = try await ParakeetReplay.installedTranscriber()
        let url = try DictationFixtures.url("multi-paragraph-49s", "m4a")
        let outcome = try await ParakeetReplay.run(url: url, transcriber: transcriber)

        XCTAssertEqual(outcome.events.last, .ended)
        XCTAssertFalse(outcome.events.contains(.failed))
        let score = try TranscriptScoring.score(reference: DictationFixtures.reference("multi-paragraph-49s"), hypothesis: outcome.transcript)
        XCTAssertEqual(score.droppedSentences, 0, outcome.transcript)
        XCTAssertEqual(score.repeatedInsertions, 0, outcome.transcript)
        XCTAssertLessThanOrEqual(score.wordErrorRate, 0.06, outcome.transcript)
    }

    func test_recordedAudioThroughBarkKeepsEverySentence() async throws {
        for model in [LocalSpeechModel.bark, .barkClean] {
            let transcriber = try await ParakeetReplay.installedTranscriber(model)
            let url = try DictationFixtures.url("multi-paragraph-49s", "m4a")
            let outcome = try await ParakeetReplay.run(url: url, transcriber: transcriber)

            XCTAssertEqual(outcome.events.last, .ended, model.title)
            XCTAssertFalse(outcome.transcript.contains("<unk>"), model.title)
            let score = try TranscriptScoring.score(reference: DictationFixtures.reference("multi-paragraph-49s"), hypothesis: outcome.transcript)
            XCTAssertEqual(score.droppedSentences, 0, "\(model.title): \(outcome.transcript)")
            XCTAssertEqual(score.repeatedInsertions, 0, "\(model.title): \(outcome.transcript)")
            XCTAssertLessThanOrEqual(score.wordErrorRate, 0.06, "\(model.title): \(outcome.transcript)")
        }
    }

    func test_transcriberDropsTheUnknownToken() {
        XCTAssertEqual(ParakeetAsrTranscriber.cleaned(" He said <unk>hello<unk> to me. "), "He said hello to me.")
        XCTAssertEqual(ParakeetAsrTranscriber.cleaned("a <unk> b"), "a b")
        XCTAssertEqual(ParakeetAsrTranscriber.cleaned("a <unk> <unk> b"), "a b")
    }
}
