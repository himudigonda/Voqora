import AVFoundation
import FluidAudio
import Foundation

nonisolated struct ParakeetSegment: Equatable, Sendable {
    let range: Range<Int>
    let containsSpeech: Bool
}

nonisolated struct ParakeetSegmenter: Sendable {
    static let sampleRate = 16000
    static let frameLength = 480
    static let pauseFrames = 24
    static let cutFramesIntoPause = 12
    static let minimumSpeechFrames = 14
    static let maximumSegmentSamples = 25 * sampleRate
    static let forcedCutWindowFrames = 100
    static let silentSegmentSamples = 3 * sampleRate
    static let silentSegmentRemainderSamples = sampleRate
    static let minimumSpeechLevel: Float = 0.0015
    static let speechToFloorRatio: Float = 3
    static let noiseFloorCeiling: Float = 0.01
    static let noiseFloorGrowth: Float = 1.002
    static let audibleFloor: Float = 0.001

    private struct Frame {
        let energy: Float
        let isSpeech: Bool
    }

    private(set) var openStart = 0
    private(set) var consumed = 0
    private var frames: [Frame] = []
    private var firstFrame = 0
    private var speechFrames = 0
    private var silentRun = 0
    private var noiseFloor: Float = 0.002
    private var partialSquares = 0.0
    private var partialCount = 0

    var openHasSpeech: Bool {
        speechFrames > 0
    }

    private var speechLevel: Float {
        max(Self.minimumSpeechLevel, noiseFloor * Self.speechToFloorRatio)
    }

    mutating func append(_ samples: [Float]) -> [ParakeetSegment] {
        var closed: [ParakeetSegment] = []
        var index = 0
        while index < samples.count {
            let take = min(Self.frameLength - partialCount, samples.count - index)
            for position in index ..< index + take {
                partialSquares += Double(samples[position] * samples[position])
            }
            partialCount += take
            index += take
            consumed += take
            if partialCount == Self.frameLength {
                completeFrame(into: &closed)
            }
        }
        return closed
    }

    mutating func finish() -> ParakeetSegment? {
        guard consumed > openStart else { return nil }
        let tailEnergy = partialCount > 0 ? Float((partialSquares / Double(partialCount)).squareRoot()) : 0
        let segment = ParakeetSegment(range: openStart ..< consumed, containsSpeech: tailEnergy >= Self.audibleFloor || frames.contains { $0.energy >= Self.audibleFloor })
        openStart = consumed
        firstFrame = (consumed + Self.frameLength - 1) / Self.frameLength
        frames = []
        speechFrames = 0
        silentRun = 0
        partialSquares = 0
        partialCount = 0
        return segment
    }

    private mutating func completeFrame(into closed: inout [ParakeetSegment]) {
        let energy = Float((partialSquares / Double(Self.frameLength)).squareRoot())
        partialSquares = 0
        partialCount = 0
        noiseFloor = max(1e-5, min(Self.noiseFloorCeiling, energy, noiseFloor * Self.noiseFloorGrowth))
        let isSpeech = energy > speechLevel
        frames.append(Frame(energy: energy, isSpeech: isSpeech))
        if isSpeech {
            speechFrames += 1
            silentRun = 0
        } else {
            silentRun += 1
        }
        let openLength = consumed - openStart
        if speechFrames >= Self.minimumSpeechFrames, silentRun >= Self.pauseFrames {
            let silenceStart = firstFrame + frames.count - silentRun
            cut(at: (silenceStart + Self.cutFramesIntoPause) * Self.frameLength, containsSpeech: true, into: &closed)
        } else if speechFrames == 0, openLength >= Self.silentSegmentSamples {
            let position = consumed - Self.silentSegmentRemainderSamples
            cut(at: position, containsSpeech: hasAudibleFrame(before: position), into: &closed)
        } else if openLength >= Self.maximumSegmentSamples {
            cut(at: quietestWindowCenter(), containsSpeech: true, into: &closed)
        }
    }

    private func hasAudibleFrame(before position: Int) -> Bool {
        let closedFrames = (position + Self.frameLength - 1) / Self.frameLength - firstFrame
        return frames.prefix(max(0, closedFrames)).contains { $0.energy >= Self.audibleFloor }
    }

    private func quietestWindowCenter() -> Int {
        let windowStart = max(0, frames.count - Self.forcedCutWindowFrames)
        var quietest = windowStart
        for index in windowStart ..< frames.count where frames[index].energy < frames[quietest].energy {
            quietest = index
        }
        return (firstFrame + quietest) * Self.frameLength + Self.frameLength / 2
    }

    private mutating func cut(at position: Int, containsSpeech: Bool, into closed: inout [ParakeetSegment]) {
        closed.append(ParakeetSegment(range: openStart ..< position, containsSpeech: containsSpeech))
        openStart = position
        let nextFirstFrame = (position + Self.frameLength - 1) / Self.frameLength
        frames.removeFirst(min(frames.count, max(0, nextFirstFrame - firstFrame)))
        firstFrame = nextFirstFrame
        speechFrames = frames.count { $0.isSpeech }
        silentRun = frames.reversed().prefix { !$0.isSpeech }.count
    }
}

nonisolated struct ParakeetSampleStore: Sendable {
    private var base = 0
    private var samples: [Float] = []

    mutating func append(_ newSamples: [Float]) {
        samples.append(contentsOf: newSamples)
    }

    func suffix(from position: Int) -> [Float] {
        Array(samples[max(0, position - base)...])
    }

    mutating func take(_ range: Range<Int>) -> [Float] {
        let taken = Array(samples[(range.lowerBound - base) ..< (range.upperBound - base)])
        discard(before: range.upperBound)
        return taken
    }

    mutating func discard(before position: Int) {
        let count = min(samples.count, max(0, position - base))
        samples.removeFirst(count)
        base += count
    }
}

nonisolated protocol ParakeetTranscribing: Sendable {
    func transcribe(_ samples: [Float]) async throws -> String
}

nonisolated struct ParakeetAsrTranscriber: ParakeetTranscribing {
    static let minimumSamples = 5000

    let manager: AsrManager

    func transcribe(_ samples: [Float]) async throws -> String {
        var state = await TdtDecoderState.make(decoderLayers: manager.decoderLayerCount)
        let padded = samples.count < Self.minimumSamples ? samples + [Float](repeating: 0, count: Self.minimumSamples - samples.count) : samples
        let result = try await manager.transcribe(padded, decoderState: &state)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

final nonisolated class ParakeetAudioConverter: @unchecked Sendable {
    private let lock = NSLock()
    private let target: AVAudioFormat
    private var converter: AVAudioConverter?
    private var converterSource: AVAudioFormat?

    init?() {
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(ParakeetSegmenter.sampleRate), channels: 1, interleaved: false) else {
            return nil
        }
        self.target = target
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        lock.withLock {
            guard buffer.frameLength > 0 else { return [] }
            if converterSource != buffer.format {
                converter = AVAudioConverter(from: buffer.format, to: target)
                converterSource = buffer.format
            }
            guard let converter else { return nil }
            let ratio = target.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
            var supplied = false
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                if supplied {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                supplied = true
                inputStatus.pointee = .haveData
                return buffer
            }
            guard status != .error, error == nil else { return nil }
            return Self.samples(of: output)
        }
    }

    func flush() -> [Float] {
        lock.withLock {
            defer {
                converter = nil
                converterSource = nil
            }
            guard let converter, let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 4096) else { return [] }
            var error: NSError?
            _ = converter.convert(to: output, error: &error) { _, inputStatus in
                inputStatus.pointee = .endOfStream
                return nil
            }
            return Self.samples(of: output)
        }
    }

    func reset() {
        lock.withLock {
            converter = nil
            converterSource = nil
        }
    }

    private static func samples(of buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
}

final nonisolated class ParakeetSegmentPipeline: @unchecked Sendable {
    typealias Emit = @Sendable (SpeechRecognitionEvent) -> Void

    static let previewIntervalSamples = ParakeetSegmenter.sampleRate
    static let minimumPreviewSamples = ParakeetSegmenter.sampleRate / 2
    static let maximumConsecutiveFailures = 3

    private enum Work {
        case final(openStart: Int, samples: [Float])
        case preview(openStart: Int, samples: [Float])
    }

    private enum Next {
        case work(Work)
        case idle
        case done
    }

    private let transcriber: any ParakeetTranscribing
    private let emit: Emit
    private let lock = NSLock()
    private let wake: AsyncStream<Void>.Continuation
    private var worker: Task<Void, Never>?
    private var segmenter = ParakeetSegmenter()
    private var store = ParakeetSampleStore()
    private var finals: [(openStart: Int, samples: [Float])] = []
    private var preview: Work?
    private var lastPreview: (openStart: Int, text: String)?
    private var lastPreviewAt = 0
    private var previewShown = false
    private var isBusy = false
    private var isFinishing = false
    private var isFailed = false
    private var isCancelled = false
    private var consecutiveFailures = 0
    private var failurePending = false

    init(transcriber: any ParakeetTranscribing, emit: @escaping Emit) {
        self.transcriber = transcriber
        self.emit = emit
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        wake = continuation
        worker = Task(priority: .userInitiated) { [self] in
            await run(stream)
        }
    }

    var backlog: Int {
        lock.withLock { finals.count + (isBusy ? 1 : 0) }
    }

    func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        let hasWork = lock.withLock {
            guard isOpen, !failurePending else { return false }
            store.append(samples)
            let closed = segmenter.append(samples)
            closed.forEach(enqueue)
            return !closed.isEmpty || enqueuePreviewIfDue()
        }
        if hasWork {
            wake.yield()
        }
    }

    func finish() {
        lock.withLock {
            guard isOpen, !failurePending else { return }
            isFinishing = true
            preview = nil
            if let last = segmenter.finish() {
                enqueue(last)
            }
        }
        wake.yield()
    }

    func reportFailure() {
        lock.withLock {
            guard isOpen else { return }
            fail()
        }
        wake.yield()
    }

    func cancel() {
        lock.withLock {
            isCancelled = true
            finals = []
            preview = nil
            store = ParakeetSampleStore()
        }
        wake.finish()
        worker?.cancel()
    }

    private var isOpen: Bool {
        !isFinishing && !isFailed && !isCancelled
    }

    private func enqueue(_ segment: ParakeetSegment) {
        preview = nil
        if segment.containsSpeech {
            finals.append((openStart: segment.range.lowerBound, samples: store.take(segment.range)))
        } else {
            store.discard(before: segment.range.upperBound)
        }
    }

    private func enqueuePreviewIfDue() -> Bool {
        guard preview == nil, finals.isEmpty, !isBusy, segmenter.openHasSpeech,
              segmenter.consumed - lastPreviewAt >= Self.previewIntervalSamples else { return false }
        let samples = store.suffix(from: segmenter.openStart)
        guard samples.count >= Self.minimumPreviewSamples else { return false }
        lastPreviewAt = segmenter.consumed
        preview = .preview(openStart: segmenter.openStart, samples: samples)
        return true
    }

    private func fail() {
        isFailed = true
        finals = []
        preview = nil
        emit(.failed)
    }

    private func run(_ stream: AsyncStream<Void>) async {
        for await _ in stream {
            drain: while true {
                switch nextWork() {
                case let .work(work):
                    await perform(work)
                case .idle:
                    break drain
                case .done:
                    wake.finish()
                    return
                }
            }
        }
    }

    private func nextWork() -> Next {
        lock.withLock {
            if isCancelled || isFailed {
                return .done
            }
            if !finals.isEmpty {
                let next = finals.removeFirst()
                isBusy = true
                return .work(.final(openStart: next.openStart, samples: next.samples))
            }
            if failurePending {
                fail()
                return .done
            }
            if isFinishing {
                emit(.ended)
                return .done
            }
            if let work = preview {
                preview = nil
                isBusy = true
                return .work(work)
            }
            return .idle
        }
    }

    private func perform(_ work: Work) async {
        switch work {
        case let .final(openStart, samples):
            await performFinal(openStart: openStart, samples: samples)
        case let .preview(openStart, samples):
            await performPreview(openStart: openStart, samples: samples)
        }
    }

    private func performFinal(openStart: Int, samples: [Float]) async {
        let text: String
        do {
            text = try await transcribeWithRetry(samples)
        } catch {
            lock.withLock {
                isBusy = false
                let preview = lastPreview
                lastPreview = nil
                guard !isCancelled, !isFailed else { return }
                consecutiveFailures += 1
                let seconds = "\(Double(samples.count) / Double(ParakeetSegmenter.sampleRate))"
                VoqoraLog.warn("Parakeet", "Segment skipped after a failed retry", ["seconds": seconds, "error": "\(error)"])
                DictationTrace.event("parakeet.segment_failed", ["seconds": seconds])
                if let preview, preview.openStart == openStart {
                    previewShown = false
                    emit(.finalized(preview.text))
                }
                if consecutiveFailures >= Self.maximumConsecutiveFailures {
                    failurePending = true
                }
            }
            return
        }
        lock.withLock {
            isBusy = false
            lastPreview = nil
            consecutiveFailures = 0
            guard !isCancelled, !isFailed else { return }
            if !text.isEmpty {
                previewShown = false
                emit(.finalized(text))
            } else if previewShown {
                previewShown = false
                emit(.volatile(""))
            }
        }
    }

    private func performPreview(openStart: Int, samples: [Float]) async {
        let text = try? await transcriber.transcribe(samples)
        lock.withLock {
            isBusy = false
            guard let text, !isCancelled, !isFailed, !isFinishing, openStart == segmenter.openStart else { return }
            guard !text.isEmpty || previewShown else { return }
            previewShown = !text.isEmpty
            lastPreview = text.isEmpty ? nil : (openStart: openStart, text: text)
            emit(.volatile(text))
        }
    }

    private func transcribeWithRetry(_ samples: [Float]) async throws -> String {
        do {
            return try await transcriber.transcribe(samples)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            return try await transcriber.transcribe(samples)
        }
    }
}

final class ParakeetSpeechRecognizer: SpeechRecognizing {
    private let models: ParakeetModelStore
    private var session: MicrophoneSession?
    private var pipeline: ParakeetSegmentPipeline?
    private var converter: ParakeetAudioConverter?
    private var events: AsyncStream<SpeechRecognitionEvent>.Continuation?
    private var eventsTask: Task<Void, Never>?
    private var transcriber: (revision: Int, value: ParakeetAsrTranscriber)?
    private var generation = 0

    init(models: ParakeetModelStore? = nil) {
        self.models = models ?? .shared
    }

    func start(localeIdentifier _: String?, allowsServer _: Bool, onEvent: @escaping SpeechRecognitionHandler) async throws {
        stop()
        let token = generation
        guard models.isInstalled else { throw DictationIssue.recognizerUnavailable }
        let transcriber = try await loadedTranscriber()
        guard token == generation else { return }
        guard let converter = ParakeetAudioConverter() else { throw DictationIssue.audioInputUnavailable }
        let forward: SpeechRecognitionHandler = { [weak self] event in
            guard let self, generation == token else { return }
            onEvent(event)
        }
        let (stream, continuation) = AsyncStream<SpeechRecognitionEvent>.makeStream()
        let pipeline = ParakeetSegmentPipeline(transcriber: transcriber) { event in
            continuation.yield(event)
            if event == .ended || event == .failed {
                continuation.finish()
            }
        }
        let sink = MicrophoneTapSink(forward: forward) { buffer in
            guard let samples = converter.convert(buffer) else {
                pipeline.reportFailure()
                return
            }
            pipeline.append(samples)
        }
        let microphone = MicrophoneSession(sink: sink, onRouteChange: { converter.reset() }) { _ in
            pipeline.reportFailure()
        }
        do {
            try microphone.start()
        } catch {
            pipeline.cancel()
            continuation.finish()
            throw error
        }
        session = microphone
        self.pipeline = pipeline
        self.converter = converter
        events = continuation
        eventsTask = Task { @MainActor in
            for await event in stream {
                forward(event)
            }
        }
        VoqoraLog.info("ParakeetRecognizer", "Recognition started")
    }

    func finish() {
        session?.stop()
        session = nil
        if let samples = converter?.flush() {
            pipeline?.append(samples)
        }
        pipeline?.finish()
    }

    func stop() {
        generation += 1
        session?.stop()
        session = nil
        pipeline?.cancel()
        pipeline = nil
        converter = nil
        events?.finish()
        events = nil
        eventsTask?.cancel()
        eventsTask = nil
    }

    private func loadedTranscriber() async throws -> ParakeetAsrTranscriber {
        if let transcriber, transcriber.revision == models.revision {
            return transcriber.value
        }
        let revision = models.revision
        do {
            let loaded = try await models.loadedModels()
            let value = ParakeetAsrTranscriber(manager: AsrManager(models: loaded))
            transcriber = (revision, value)
            return value
        } catch {
            VoqoraLog.warn("ParakeetRecognizer", "Parakeet model could not be loaded", ["error": "\(error)"])
            throw DictationIssue.recognizerUnavailable
        }
    }
}
