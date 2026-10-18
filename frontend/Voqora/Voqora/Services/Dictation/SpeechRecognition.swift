import AVFoundation
import Foundation
import Speech

nonisolated enum SpeechRecognitionEvent: Equatable, Sendable {
    case level(Float)
    case transcript(String, isFinal: Bool)
    case failed

    static func from(transcript: String?, isFinal: Bool, hasError: Bool) -> SpeechRecognitionEvent? {
        guard !hasError else { return .failed }
        return transcript.map { .transcript($0, isFinal: isFinal) }
    }
}

nonisolated enum RecognitionRoute: Equatable, Sendable {
    case onDevice
    case server

    static func resolve(isAvailable: Bool, supportsOnDevice: Bool, allowsServer: Bool) throws -> RecognitionRoute {
        if supportsOnDevice {
            guard isAvailable else { throw DictationIssue.recognizerUnavailable }
            return .onDevice
        }
        guard allowsServer else { throw DictationIssue.onDeviceUnavailable }
        guard isAvailable else { throw DictationIssue.recognizerUnavailable }
        return .server
    }
}

typealias SpeechRecognitionHandler = @MainActor @Sendable (SpeechRecognitionEvent) -> Void

@MainActor
protocol SpeechRecognizing: AnyObject {
    func start(localeIdentifier: String?, allowsServer: Bool, onEvent: @escaping SpeechRecognitionHandler) throws
    func finish()
    func stop()
}

final class SystemSpeechRecognizer: SpeechRecognizing {
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognizer: SFSpeechRecognizer?
    private var task: SFSpeechRecognitionTask?
    private var generation = 0

    func start(localeIdentifier: String?, allowsServer: Bool, onEvent: @escaping SpeechRecognitionHandler) throws {
        stop()
        guard let speechRecognizer = SpeechCallbacks.recognizer(forLocaleIdentifier: localeIdentifier) else {
            throw DictationIssue.localeUnsupported
        }
        let route = try RecognitionRoute.resolve(
            isAvailable: speechRecognizer.isAvailable,
            supportsOnDevice: speechRecognizer.supportsOnDeviceRecognition,
            allowsServer: allowsServer
        )
        let audioRequest = SFSpeechAudioBufferRecognitionRequest()
        audioRequest.shouldReportPartialResults = true
        audioRequest.requiresOnDeviceRecognition = route == .onDevice
        audioRequest.addsPunctuation = true

        let token = generation
        let forward: SpeechRecognitionHandler = { [weak self] event in
            guard let self, generation == token else { return }
            onEvent(event)
        }
        engine = try SpeechCallbacks.startedEngine(feeding: audioRequest, forward: forward)
        request = audioRequest
        recognizer = speechRecognizer
        task = SpeechCallbacks.recognitionTask(recognizer: speechRecognizer, request: audioRequest, forward: forward)
        VoqoraLog.info("SpeechRecognizer", "Recognition started", ["route": route == .onDevice ? "on_device" : "server"])
    }

    func finish() {
        stopEngine()
        request?.endAudio()
    }

    func stop() {
        generation += 1
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        recognizer = nil
        stopEngine()
    }

    private func stopEngine() {
        guard let activeEngine = engine else { return }
        activeEngine.stop()
        activeEngine.inputNode.removeTap(onBus: 0)
        engine = nil
    }
}

final nonisolated class AudioTapSink: @unchecked Sendable {
    private let request: SFSpeechAudioBufferRecognitionRequest
    private let forward: SpeechRecognitionHandler

    init(request: SFSpeechAudioBufferRecognitionRequest, forward: @escaping SpeechRecognitionHandler) {
        self.request = request
        self.forward = forward
    }

    func consume(_ buffer: AVAudioPCMBuffer) {
        request.append(buffer)
        let level = AudioLevel.normalized(rms: Self.rms(of: buffer))
        Task { @MainActor [forward] in
            forward(.level(level))
        }
    }

    private static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        return AudioLevel.rms(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
}

nonisolated enum SpeechCallbacks {
    static let tapBufferSize: AVAudioFrameCount = 1024

    static func recognizer(forLocaleIdentifier identifier: String?) -> SFSpeechRecognizer? {
        guard let identifier else { return SFSpeechRecognizer() }
        return SFSpeechRecognizer(locale: Locale(identifier: identifier))
    }

    static func startedEngine(
        feeding request: SFSpeechAudioBufferRecognitionRequest,
        forward: @escaping SpeechRecognitionHandler
    ) throws -> AVAudioEngine {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw DictationIssue.audioInputUnavailable
        }
        let sink = AudioTapSink(request: request, forward: forward)
        input.installTap(onBus: 0, bufferSize: tapBufferSize, format: format) { buffer, _ in
            sink.consume(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw DictationIssue.audioInputUnavailable
        }
        return engine
    }

    static func recognitionTask(
        recognizer: SFSpeechRecognizer,
        request: SFSpeechAudioBufferRecognitionRequest,
        forward: @escaping SpeechRecognitionHandler
    ) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            guard let event = SpeechRecognitionEvent.from(
                transcript: result?.bestTranscription.formattedString,
                isFinal: result?.isFinal ?? false,
                hasError: error != nil
            ) else { return }
            Task { @MainActor in
                forward(event)
            }
        }
    }
}
