import AVFoundation
import Foundation
import Speech

@available(macOS 26, *)
enum AnalyzerModelDownloads {
    private static var inFlight: Task<Void, Never>?

    static func begin(for locale: Locale) {
        guard inFlight == nil else {
            DictationTrace.event("analyzer.model_download_skipped", ["locale": locale.identifier])
            return
        }
        DictationTrace.event("analyzer.model_download_started", ["locale": locale.identifier])
        VoqoraLog.info("SpeechAnalyzer", "Downloading speech model in the background", ["locale": locale.identifier])
        inFlight = Task { @MainActor in
            defer { inFlight = nil }
            do {
                let transcriber = AnalyzerSpeechRecognizer.transcriber(for: locale)
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    try await request.downloadAndInstall()
                }
                DictationTrace.event("analyzer.model_download_finished", ["locale": locale.identifier])
                VoqoraLog.info("SpeechAnalyzer", "Speech model downloaded", ["locale": locale.identifier])
            } catch {
                DictationTrace.event("analyzer.model_download_failed", ["locale": locale.identifier, "detail": "\(error)"])
                VoqoraLog.warn("SpeechAnalyzer", "Speech model download failed", ["error": "\(error)"])
            }
        }
    }
}

@available(macOS 26, *)
final class AnalyzerSpeechRecognizer: SpeechRecognizing {
    private let locale: Locale
    private var session: MicrophoneSession?
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var feed: AnalyzerInputFeed?
    private var generation = 0

    init(locale: Locale) {
        self.locale = locale
    }

    nonisolated static func supportedLocale(for identifier: String?) async -> Locale? {
        guard SpeechTranscriber.isAvailable else { return nil }
        let requested = identifier ?? Locale.current.identifier
        for candidate in LocaleFallback.identifiers(for: requested) {
            guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: candidate)) else { continue }
            if candidate != requested {
                DictationTrace.event("locale.fallback", ["requested": requested, "used": candidate, "engine": "analyzer"])
            }
            return supported
        }
        return nil
    }

    nonisolated static func isModelInstalled(for locale: Locale) async -> Bool {
        let status = await AssetInventory.status(forModules: [transcriber(for: locale)])
        DictationTrace.event("analyzer.model_status", ["locale": locale.identifier, "status": "\(status)"])
        return status == .installed
    }

    nonisolated static func transcriber(for locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: []
        )
    }

    func start(localeIdentifier _: String?, allowsServer _: Bool, onEvent: @escaping SpeechRecognitionHandler) async throws {
        stop()
        let token = generation
        let startedAt = ContinuousClock.now
        let transcriber = Self.transcriber(for: locale)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw DictationIssue.recognizerUnavailable
        }
        guard token == generation else { return }
        let forward: SpeechRecognitionHandler = { [weak self] event in
            guard let self, generation == token else { return }
            onEvent(event)
        }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let feed = AnalyzerInputFeed(format: format, continuation: continuation)
        let sink = MicrophoneTapSink(forward: forward) { feed.append($0) }
        let microphone = MicrophoneSession(sink: sink) { reason in
            DictationTrace.event("analyzer.capture_failed", ["reason": reason])
            sink.reportFailure()
        }
        self.feed = feed
        input = continuation
        do {
            try microphone.start()
        } catch {
            stop()
            throw error
        }
        session = microphone
        DictationTrace.event("analyzer.mic_started", ["afterMs": "\(Int((ContinuousClock.now - startedAt) / .milliseconds(1)))"])
        let speechAnalyzer = SpeechAnalyzer(modules: [transcriber], options: .init(priority: .userInitiated, modelRetention: .lingering))
        analyzer = speechAnalyzer
        do {
            try await speechAnalyzer.prepareToAnalyze(in: format)
        } catch {
            guard token == generation else { return }
            DictationTrace.event("analyzer.prepare_failed", ["detail": "\(error)"])
            stop()
            throw DictationIssue.recognizerUnavailable
        }
        guard token == generation else { return }
        resultsTask = Task {
            var index = 0
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    index += 1
                    DictationTrace.event("analyzer.result", [
                        "index": "\(index)",
                        "isFinal": "\(result.isFinal)",
                        "text": text,
                        "rangeStart": String(format: "%.2f", result.range.start.seconds),
                        "rangeEnd": String(format: "%.2f", result.range.end.seconds),
                    ])
                    forward(result.isFinal ? .finalized(text) : .volatile(text))
                }
                DictationTrace.event("analyzer.results_ended", ["results": "\(index)"])
                forward(.ended)
            } catch {
                DictationTrace.event("analyzer.results_failed", ["results": "\(index)", "detail": "\(error)"])
                VoqoraLog.warn("SpeechAnalyzer", "Transcriber results failed", ["error": "\(error)"])
                forward(.failed)
            }
        }
        do {
            try await speechAnalyzer.start(inputSequence: stream)
        } catch {
            guard token == generation else { return }
            DictationTrace.event("analyzer.start_failed", ["detail": "\(error)"])
            stop()
            throw DictationIssue.recognizerUnavailable
        }
        let setup = ContinuousClock.now - startedAt
        DictationTrace.event("analyzer.start", [
            "locale": locale.identifier,
            "sampleRate": "\(format.sampleRate)",
            "channels": "\(format.channelCount)",
            "commonFormat": "\(format.commonFormat.rawValue)",
            "setupMs": "\(Int(setup / .milliseconds(1)))",
        ])
        VoqoraLog.info("SpeechAnalyzer", "Recognition started", ["locale": locale.identifier, "format": "\(format.sampleRate)"])
    }

    func finish() {
        session?.stop()
        session = nil
        feed?.finish()
        input = nil
        DictationTrace.event("analyzer.finish_requested", feed?.totals ?? [:])
        guard let analyzer else { return }
        Task {
            do {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
                DictationTrace.event("analyzer.finalize_finished")
            } catch {
                DictationTrace.event("analyzer.finalize_failed", ["detail": "\(error)"])
                VoqoraLog.warn("SpeechAnalyzer", "Finalizing failed", ["error": "\(error)"])
            }
        }
    }

    func stop() {
        generation += 1
        DictationTrace.event("analyzer.stop", feed?.totals ?? [:])
        feed = nil
        session?.stop()
        session = nil
        input?.finish()
        input = nil
        resultsTask?.cancel()
        resultsTask = nil
        if let analyzer {
            Task { await analyzer.cancelAndFinishNow() }
        }
        analyzer = nil
    }
}

@available(macOS 26, *)
final nonisolated class AnalyzerInputFeed: @unchecked Sendable {
    private let format: AVAudioFormat
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private var converter: AVAudioConverter?
    private var converterSource: AVAudioFormat?
    private var carriedTail: AVAudioPCMBuffer?
    private let convertLock = NSLock()
    private var reportedFailure = false
    private var conversionFailed = false
    private let counterLock = NSLock()
    private var buffers = 0
    private var inputFrames: UInt64 = 0
    private var outputFrames: UInt64 = 0
    private var failedBuffers = 0
    private var droppedBuffers = 0

    init(format: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation) {
        self.format = format
        self.continuation = continuation
    }

    var totals: [String: String] {
        counterLock.withLock { totalsLocked }
    }

    func finish() {
        let tail = convertLock.withLock { drainTail() }
        if let tail {
            traceTail(tail)
            continuation.yield(AnalyzerInput(buffer: tail))
        }
        continuation.finish()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        let (converted, tail) = convertLock.withLock {
            let converted = convertLocked(buffer)
            defer { carriedTail = nil }
            return (converted, carriedTail)
        }
        if let tail {
            traceTail(tail)
            continuation.yield(AnalyzerInput(buffer: tail))
        }
        record(input: buffer, output: converted)
        guard let converted else {
            if conversionFailed {
                reportFailureOnce(from: buffer.format)
            }
            return
        }
        continuation.yield(AnalyzerInput(buffer: converted))
    }

    private var totalsLocked: [String: String] {
        [
            "buffers": "\(buffers)",
            "inputFrames": "\(inputFrames)",
            "outputFrames": "\(outputFrames)",
            "failedBuffers": "\(failedBuffers)",
            "droppedBuffers": "\(droppedBuffers)",
        ]
    }

    private func record(input: AVAudioPCMBuffer, output: AVAudioPCMBuffer?) {
        let snapshot: [String: String]? = counterLock.withLock {
            buffers += 1
            inputFrames += UInt64(input.frameLength)
            outputFrames += UInt64(output?.frameLength ?? 0)
            if output == nil {
                if conversionFailed {
                    failedBuffers += 1
                } else {
                    droppedBuffers += 1
                }
            }
            return buffers.isMultiple(of: 50) ? totalsLocked : nil
        }
        if let snapshot {
            DictationTrace.event("analyzer.buffers", snapshot)
        }
    }

    private func reportFailureOnce(from source: AVAudioFormat) {
        guard !reportedFailure else { return }
        reportedFailure = true
        let detail = "\(source.sampleRate) Hz, \(source.channelCount) ch -> \(format.sampleRate) Hz"
        DictationTrace.event("analyzer.converter_failed", ["format": detail])
        Task { @MainActor in
            VoqoraLog.warn("SpeechAnalyzer", "Microphone audio could not be converted for the speech model", ["format": detail])
        }
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        convertLock.withLock { convertLocked(buffer) }
    }

    private func traceTail(_ tail: AVAudioPCMBuffer) {
        DictationTrace.event("analyzer.tail_flushed", ["frames": "\(tail.frameLength)"])
    }

    private func drainTail() -> AVAudioPCMBuffer? {
        guard let converter, let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else { return nil }
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            inputStatus.pointee = .endOfStream
            return nil
        }
        guard status != .error, error == nil, output.frameLength > 0 else { return nil }
        return output
    }

    private func convertLocked(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        conversionFailed = false
        guard buffer.frameLength > 0 else { return nil }
        if converterSource != buffer.format {
            carriedTail = drainTail()
            converter = AVAudioConverter(from: buffer.format, to: format)
            converter?.downmix = true
            converterSource = buffer.format
        }
        guard let converter else {
            conversionFailed = true
            return nil
        }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
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
        guard status != .error, error == nil else {
            conversionFailed = true
            return nil
        }
        guard output.frameLength > 0 else { return nil }
        return output
    }
}
