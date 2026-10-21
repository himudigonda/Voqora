import AppKit
import AVFoundation
import Foundation
import Speech

nonisolated enum SpeechRecognitionEvent: Equatable, Sendable {
    case level(Float)
    case volatile(String)
    case finalized(String)
    case ended
    case failed
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
    func start(localeIdentifier: String?, allowsServer: Bool, onEvent: @escaping SpeechRecognitionHandler) async throws
    func finish()
    func stop()
}

final class SystemSpeechRecognizer: SpeechRecognizing {
    private var active: (any SpeechRecognizing)?
    private var generation = 0
    private let defaults: UserDefaults
    private let parakeetInstalled: @MainActor () -> Bool

    init(defaults: UserDefaults = .standard, parakeetInstalled: @escaping @MainActor () -> Bool = { ParakeetModelStore.shared.isInstalled }) {
        self.defaults = defaults
        self.parakeetInstalled = parakeetInstalled
    }

    func start(localeIdentifier: String?, allowsServer: Bool, onEvent: @escaping SpeechRecognitionHandler) async throws {
        stop()
        let token = generation
        let preferred = DictationPreferences(defaults: defaults).engine
        if DictationEngineChoice.effective(preferred: preferred, parakeetInstalled: parakeetInstalled()) == .parakeet {
            let parakeet = ParakeetSpeechRecognizer()
            active = parakeet
            try await parakeet.start(localeIdentifier: localeIdentifier, allowsServer: allowsServer, onEvent: onEvent)
            if token != generation {
                parakeet.stop()
            }
            return
        }
        if preferred == .parakeet {
            DictationTrace.event("engine.fallback", ["from": "parakeet", "to": "apple", "reason": "model_not_installed"])
        }
        let engine = await Self.engine(forLocaleIdentifier: localeIdentifier)
        guard token == generation else { return }
        active = engine
        do {
            try await engine.start(localeIdentifier: localeIdentifier, allowsServer: allowsServer, onEvent: onEvent)
        } catch {
            guard token == generation else { return }
            guard Self.shouldFallBackToLegacy(after: error, from: engine) else { throw error }
            DictationTrace.event("analyzer.fallback_legacy", ["detail": "\(error)"])
            VoqoraLog.warn("SpeechRecognizer", "SpeechAnalyzer failed to start; using the legacy recognizer", ["error": "\(error)"])
            engine.stop()
            let legacy = LegacySpeechRecognizer()
            active = legacy
            try await legacy.start(localeIdentifier: localeIdentifier, allowsServer: allowsServer, onEvent: onEvent)
            if token != generation {
                legacy.stop()
            }
            return
        }
        guard token == generation else {
            engine.stop()
            return
        }
    }

    func finish() {
        active?.finish()
    }

    func stop() {
        generation += 1
        active?.stop()
        active = nil
    }

    private static func shouldFallBackToLegacy(after error: Error, from engine: any SpeechRecognizing) -> Bool {
        guard #available(macOS 26, *), engine is AnalyzerSpeechRecognizer else { return false }
        if let issue = error as? DictationIssue, issue == .audioInputUnavailable {
            return false
        }
        return true
    }

    private static func engine(forLocaleIdentifier identifier: String?) async -> any SpeechRecognizing {
        if #available(macOS 26, *), let locale = await AnalyzerSpeechRecognizer.supportedLocale(for: identifier) {
            if await AnalyzerSpeechRecognizer.isModelInstalled(for: locale) {
                return AnalyzerSpeechRecognizer(locale: locale)
            }
            DictationTrace.event("analyzer.model_missing", ["locale": locale.identifier])
            AnalyzerModelDownloads.begin(for: locale)
        }
        return LegacySpeechRecognizer()
    }
}

final nonisolated class MicrophoneTapSink: @unchecked Sendable {
    private let consume: @Sendable (AVAudioPCMBuffer) -> Void
    private let forward: SpeechRecognitionHandler

    init(forward: @escaping SpeechRecognitionHandler, consume: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
        self.forward = forward
        self.consume = consume
    }

    func receive(_ buffer: AVAudioPCMBuffer) {
        consume(buffer)
        let level = AudioLevel.normalized(rms: MicrophoneMetering.loudestChannelRMS(of: buffer))
        Task { @MainActor [forward] in
            forward(.level(level))
        }
    }

    func reportFailure() {
        Task { @MainActor [forward] in
            forward(.failed)
        }
    }
}

nonisolated enum MicrophoneMetering {
    static func loudestChannelRMS(of buffer: AVAudioPCMBuffer) -> Float {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0 else { return 0 }
        let isInterleaved = buffer.format.isInterleaved
        if let data = buffer.floatChannelData {
            return loudest(channels: channels, frames: frames) { channel, frame in
                isInterleaved ? data[0][frame * channels + channel] : data[channel][frame]
            }
        }
        if let data = buffer.int16ChannelData {
            return loudest(channels: channels, frames: frames) { channel, frame in
                Float(isInterleaved ? data[0][frame * channels + channel] : data[channel][frame]) / 32768
            }
        }
        return 0
    }

    private static func loudest(channels: Int, frames: Int, sample: (Int, Int) -> Float) -> Float {
        var loudest: Float = 0
        for channel in 0 ..< channels {
            var sumOfSquares: Float = 0
            for frame in 0 ..< frames {
                let value = sample(channel, frame)
                sumOfSquares += value * value
            }
            loudest = max(loudest, (sumOfSquares / Float(frames)).squareRoot())
        }
        return loudest
    }
}

final nonisolated class MonoDownmixer: @unchecked Sendable {
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var source: AVAudioFormat?

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0 else { return nil }
        return lock.withLock { convertLocked(buffer) }
    }

    private func convertLocked(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: buffer.format.sampleRate,
            channels: 1,
            interleaved: false
        ) else { return nil }
        if converter == nil || source != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
            converter?.downmix = true
            source = buffer.format
        }
        guard let converter,
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: buffer.frameLength)
        else { return nil }
        do {
            try converter.convert(to: output, from: buffer)
        } catch {
            DictationTrace.event("capture.mono_failed", ["detail": "\(error)"])
            return nil
        }
        return output.frameLength > 0 ? output : nil
    }
}

nonisolated struct CaptureWatchdog: Sendable {
    enum Decision: Equatable, Sendable {
        case healthy
        case restart
        case fail
    }

    let timeout: TimeInterval
    private var lastBufferAt: TimeInterval
    private var hasRestarted = false

    init(timeout: TimeInterval = 2, startedAt: TimeInterval) {
        self.timeout = timeout
        lastBufferAt = startedAt
    }

    mutating func bufferArrived(at now: TimeInterval) {
        lastBufferAt = now
        hasRestarted = false
    }

    mutating func evaluate(at now: TimeInterval) -> Decision {
        guard now - lastBufferAt >= timeout else { return .healthy }
        guard !hasRestarted else { return .fail }
        hasRestarted = true
        lastBufferAt = now
        return .restart
    }
}

nonisolated enum MicrophoneCapture {
    static let tapBufferSize: AVAudioFrameCount = 1024

    static func startedEngine(sink: MicrophoneTapSink) throws -> AVAudioEngine {
        let engine = AVAudioEngine()
        try installAndStart(engine) { buffer in sink.receive(buffer) }
        return engine
    }

    static func installAndStart(_ engine: AVAudioEngine, onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw DictationIssue.audioInputUnavailable
        }
        input.installTap(onBus: 0, bufferSize: tapBufferSize, format: nil) { buffer, _ in
            onBuffer(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw DictationIssue.audioInputUnavailable
        }
    }

    static func stop(_ engine: AVAudioEngine?) {
        guard let engine else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
    }
}

final nonisolated class MicrophoneSession: @unchecked Sendable {
    typealias Clock = @Sendable () -> TimeInterval

    static let watchdogTimeout: TimeInterval = 2
    static let defaultClock: Clock = { ProcessInfo.processInfo.systemUptime }

    private let sink: MicrophoneTapSink
    private let clock: Clock
    private let onRouteChange: (@Sendable () -> Void)?
    private let onFailure: @Sendable (String) -> Void
    private let control = DispatchQueue(label: "com.voqora.microphone-session")
    private let stateLock = NSLock()
    private let watchdogLock = NSLock()
    private var engine: AVAudioEngine?
    private var watchdog: CaptureWatchdog
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var timer: (any DispatchSourceTimer)?
    private var isSuspended = false

    init(
        sink: MicrophoneTapSink,
        clock: @escaping Clock = MicrophoneSession.defaultClock,
        onRouteChange: (@Sendable () -> Void)? = nil,
        onFailure: @escaping @Sendable (String) -> Void
    ) {
        self.sink = sink
        self.clock = clock
        self.onRouteChange = onRouteChange
        self.onFailure = onFailure
        watchdog = CaptureWatchdog(timeout: Self.watchdogTimeout, startedAt: clock())
    }

    func start() throws {
        try stateLock.withLock {
            guard engine == nil else { return }
            let engine = AVAudioEngine()
            try MicrophoneCapture.installAndStart(engine) { [weak self] buffer in
                self?.noteBuffer()
                self?.sink.receive(buffer)
            }
            self.engine = engine
            isSuspended = false
            resetWatchdog()
            addObservers(for: engine)
            startTimer()
        }
    }

    func stop() {
        stateLock.withLock { teardownLocked() }
    }

    func evaluateWatchdog() {
        let decision: CaptureWatchdog.Decision = stateLock.withLock {
            guard engine != nil, !isSuspended else { return .healthy }
            return watchdogLock.withLock { watchdog.evaluate(at: clock()) }
        }
        switch decision {
        case .healthy:
            break
        case .restart:
            DictationTrace.event("capture.watchdog", ["action": "restart"])
            restart(reason: "watchdog")
        case .fail:
            DictationTrace.event("capture.watchdog", ["action": "fail"])
            fail(reason: "watchdog")
        }
    }

    private func noteBuffer() {
        let now = clock()
        watchdogLock.withLock { watchdog.bufferArrived(at: now) }
    }

    private func resetWatchdog() {
        let now = clock()
        watchdogLock.withLock { watchdog = CaptureWatchdog(timeout: Self.watchdogTimeout, startedAt: now) }
    }

    private func addObservers(for engine: AVAudioEngine) {
        let center = NotificationCenter.default
        observers.append((center, center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            self?.control.async { self?.configurationChanged() }
        }))
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append((workspace, workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { [weak self] _ in
            self?.control.async { self?.suspend() }
        }))
        observers.append((workspace, workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.control.async { self?.resume() }
        }))
    }

    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: control)
        timer.schedule(deadline: .now() + .milliseconds(500), repeating: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            self?.evaluateWatchdog()
        }
        self.timer = timer
        timer.resume()
    }

    private func teardownLocked() {
        timer?.cancel()
        timer = nil
        observers.forEach { $0.center.removeObserver($0.token) }
        observers = []
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        isSuspended = false
    }

    private func configurationChanged() {
        let suspended = stateLock.withLock { isSuspended }
        guard !suspended else { return }
        DictationTrace.event("capture.route_change")
        restart(reason: "route_change")
    }

    private func suspend() {
        stateLock.withLock {
            guard let engine, !isSuspended else { return }
            isSuspended = true
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        DictationTrace.event("capture.sleep")
    }

    private func resume() {
        let wasSuspended = stateLock.withLock {
            let value = isSuspended
            isSuspended = false
            return value && engine != nil
        }
        guard wasSuspended else { return }
        DictationTrace.event("capture.wake")
        restart(reason: "wake")
    }

    private func restart(reason: String) {
        let failure: String? = stateLock.withLock {
            guard let engine else { return nil }
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            onRouteChange?()
            do {
                try MicrophoneCapture.installAndStart(engine) { [weak self] buffer in
                    self?.noteBuffer()
                    self?.sink.receive(buffer)
                }
            } catch {
                DictationTrace.event("capture.restart_failed", ["reason": reason, "detail": "\(error)"])
                teardownLocked()
                return reason
            }
            resetWatchdog()
            let format = engine.inputNode.outputFormat(forBus: 0)
            DictationTrace.event("capture.restarted", [
                "reason": reason,
                "sampleRate": "\(format.sampleRate)",
                "channels": "\(format.channelCount)",
            ])
            return nil
        }
        if let failure {
            VoqoraLog.warn("Microphone", "Capture could not be restarted", ["reason": failure])
            onFailure(failure)
        }
    }

    private func fail(reason: String) {
        let wasRunning = stateLock.withLock {
            let running = engine != nil
            teardownLocked()
            return running
        }
        guard wasRunning else { return }
        VoqoraLog.warn("Microphone", "Capture stopped delivering audio", ["reason": reason])
        onFailure(reason)
    }
}

nonisolated enum LocaleFallback {
    static func identifiers(for identifier: String) -> [String] {
        var candidates = [identifier]
        if let language = Locale(identifier: identifier).language.languageCode?.identifier {
            candidates.append(language)
            if language == "en" {
                candidates.append("en-US")
            }
        }
        var seen = Set<String>()
        return candidates.filter { seen.insert($0.replacingOccurrences(of: "_", with: "-").lowercased()).inserted }
    }
}

nonisolated enum SpeechCallbacks {
    static func recognizer(forLocaleIdentifier identifier: String?) -> SFSpeechRecognizer? {
        if identifier == nil, let recognizer = SFSpeechRecognizer() {
            return recognizer
        }
        let requested = identifier ?? Locale.current.identifier
        for candidate in LocaleFallback.identifiers(for: requested) {
            guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: candidate)) else { continue }
            if candidate != requested {
                DictationTrace.event("locale.fallback", ["requested": requested, "used": candidate, "engine": "legacy"])
            }
            return recognizer
        }
        return nil
    }
}
