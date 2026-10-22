import AVFoundation
import Foundation
import Speech

nonisolated struct LegacyTranscriptSegmenter: Equatable, Sendable {
    private(set) var current = ""

    mutating func ingest(_ partial: String) -> [SpeechRecognitionEvent] {
        let next = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !next.isEmpty else { return [] }
        var events: [SpeechRecognitionEvent] = []
        if Self.isRestart(previous: current, next: next) {
            events.append(.finalized(current))
        }
        current = next
        events.append(.volatile(next))
        return events
    }

    mutating func finalize(_ text: String) -> [SpeechRecognitionEvent] {
        let last = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var events: [SpeechRecognitionEvent] = []
        if last.isEmpty || Self.isRestart(previous: current, next: last) {
            if !current.isEmpty {
                events.append(.finalized(current))
            }
        }
        if !last.isEmpty {
            events.append(.finalized(last))
        }
        current = ""
        return events
    }

    mutating func flush() -> [SpeechRecognitionEvent] {
        defer { current = "" }
        return current.isEmpty ? [] : [.finalized(current)]
    }

    static let restartSimilarityThreshold = 0.4
    static let similarityPrefixLimit = 24

    static func isRestart(previous: String, next: String) -> Bool {
        let old = normalized(previous)
        let new = normalized(next)
        guard !old.isEmpty, !new.isEmpty, !new.hasPrefix(old) else { return false }
        let length = min(old.count, new.count, similarityPrefixLimit)
        let distance = levenshtein(Array(old.prefix(length)), Array(new.prefix(length)))
        if 1 - Double(distance) / Double(length) < restartSimilarityThreshold {
            return true
        }
        if old.count >= 6, new.count * 2 <= old.count {
            return true
        }
        let oldWords = words(previous).count
        return oldWords >= 4 && words(next).count * 2 <= oldWords
    }

    static func normalized(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    static func words(_ text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber && $0 != "'" }
            .map(String.init)
    }

    static func levenshtein(_ lhs: [Character], _ rhs: [Character]) -> Int {
        guard !lhs.isEmpty else { return rhs.count }
        guard !rhs.isEmpty else { return lhs.count }
        var previous = Array(0 ... rhs.count)
        for (row, left) in lhs.enumerated() {
            var current = [row + 1]
            for (column, right) in rhs.enumerated() {
                current.append(min(previous[column + 1] + 1, current[column] + 1, previous[column] + (left == right ? 0 : 1)))
            }
            previous = current
        }
        return previous[rhs.count]
    }
}

nonisolated protocol RecognitionAudioTarget: AnyObject {
    func append(_ buffer: AVAudioPCMBuffer)
    func endAudio()
}

final nonisolated class SpeechRequestTarget: RecognitionAudioTarget, @unchecked Sendable {
    let request: SFSpeechAudioBufferRecognitionRequest

    init(_ request: SFSpeechAudioBufferRecognitionRequest) {
        self.request = request
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        request.append(buffer)
    }

    func endAudio() {
        request.endAudio()
    }
}

final nonisolated class RecognitionRequestSlot: @unchecked Sendable {
    static let pendingLimitSeconds: Double = 30

    private let lock = NSLock()
    private var target: (any RecognitionAudioTarget)?
    private var token: Int?
    private var isDetached = false
    private var pending: [AVAudioPCMBuffer] = []
    private var pendingSeconds: Double = 0
    private var reportedCap = false

    var hasPending: Bool {
        lock.withLock { !pending.isEmpty }
    }

    var pendingDuration: Double {
        lock.withLock { pendingSeconds }
    }

    @discardableResult
    func replace(with next: (any RecognitionAudioTarget)?, token nextToken: Int? = nil) -> (any RecognitionAudioTarget)? {
        lock.withLock {
            let previous = target
            target = next
            token = next == nil ? nil : nextToken
            var replayed = 0
            if let next {
                pending.forEach { next.append($0) }
                replayed = pending.count
            }
            let seconds = pendingSeconds
            clearPending()
            isDetached = false
            if replayed > 0 {
                DictationTrace.event("legacy.replay", ["buffers": "\(replayed)", "seconds": String(format: "%.2f", seconds)])
            }
            return previous
        }
    }

    @discardableResult
    func detach(_ expected: Int) -> Bool {
        lock.withLock {
            guard token == expected, !isDetached else { return false }
            markDetached()
            return true
        }
    }

    func detachCurrent() -> (target: any RecognitionAudioTarget, token: Int)? {
        lock.withLock {
            guard !isDetached, let target, let token else { return nil }
            markDetached()
            return (target, token)
        }
    }

    func closeInput() -> (any RecognitionAudioTarget)? {
        lock.withLock {
            guard !isDetached else { return nil }
            let previous = target
            target = nil
            token = nil
            return previous
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            if isDetached {
                enqueue(buffer)
            } else {
                target?.append(buffer)
            }
        }
    }

    private func markDetached() {
        target = nil
        isDetached = true
        DictationTrace.event("legacy.detach", ["token": "\(token ?? -1)"])
    }

    private func clearPending() {
        pending = []
        pendingSeconds = 0
        reportedCap = false
    }

    private func enqueue(_ buffer: AVAudioPCMBuffer) {
        let seconds = Double(buffer.frameLength) / max(buffer.format.sampleRate, 1)
        pending.append(buffer)
        pendingSeconds += seconds
        var dropped = 0
        while pendingSeconds > Self.pendingLimitSeconds, pending.count > 1 {
            let oldest = pending.removeFirst()
            pendingSeconds -= Double(oldest.frameLength) / max(oldest.format.sampleRate, 1)
            dropped += 1
        }
        if dropped > 0, !reportedCap {
            reportedCap = true
            DictationTrace.event("legacy.pending_cap", ["limitSeconds": "\(Self.pendingLimitSeconds)", "dropped": "\(dropped)"])
        }
    }
}

final class LegacySpeechRecognizer: SpeechRecognizing {
    static let restartLimit = 3
    static let restartWindow: TimeInterval = 10
    static let rotationTimeout: Duration = .seconds(3)

    private let slot = RecognitionRequestSlot()
    private let downmixer = MonoDownmixer()
    private var session: MicrophoneSession?
    private var rotationTimeoutTask: Task<Void, Never>?
    private var recognizer: SFSpeechRecognizer?
    private var task: SFSpeechRecognitionTask?
    private var route = RecognitionRoute.onDevice
    private var segmenter = LegacyTranscriptSegmenter()
    private var forward: SpeechRecognitionHandler?
    private var isFinishing = false
    private var restarts: [TimeInterval] = []
    private var generation = 0
    private var taskGeneration = 0

    func start(localeIdentifier: String?, allowsServer: Bool, onEvent: @escaping SpeechRecognitionHandler) async throws {
        stop()
        guard let speechRecognizer = SpeechCallbacks.recognizer(forLocaleIdentifier: localeIdentifier) else {
            throw DictationIssue.localeUnsupported
        }
        route = try RecognitionRoute.resolve(
            isAvailable: speechRecognizer.isAvailable,
            supportsOnDevice: speechRecognizer.supportsOnDeviceRecognition,
            allowsServer: allowsServer
        )
        let token = generation
        let relay: SpeechRecognitionHandler = { [weak self] event in
            guard let self, generation == token else { return }
            onEvent(event)
        }
        forward = relay
        recognizer = speechRecognizer
        beginTask(reason: "start")
        let slot = slot
        let downmixer = downmixer
        let sink = MicrophoneTapSink(forward: relay) { buffer in
            if let mono = downmixer.convert(buffer) {
                slot.append(mono)
            }
        }
        let microphone = MicrophoneSession(
            sink: sink,
            onRouteChange: { [weak self] in
                guard let detached = slot.detachCurrent() else { return }
                detached.target.endAudio()
                DictationTrace.event("legacy.route_rotation", ["task": "\(detached.token)"])
                Task { @MainActor in
                    self?.awaitRotation(of: detached.token)
                }
            },
            onFailure: { reason in
                DictationTrace.event("legacy.capture_failed", ["reason": reason])
                sink.reportFailure()
            }
        )
        do {
            try microphone.start()
        } catch {
            stop()
            throw error
        }
        session = microphone
        DictationTrace.event("legacy.start", [
            "locale": localeIdentifier ?? "system",
            "route": route == .onDevice ? "on_device" : "server",
        ])
        VoqoraLog.info("SpeechRecognizer", "Recognition started", ["route": route == .onDevice ? "on_device" : "server"])
    }

    func finish() {
        DictationTrace.event("legacy.finish_requested", ["partial": segmenter.current, "pendingSeconds": "\(slot.pendingDuration)"])
        isFinishing = true
        session?.stop()
        session = nil
        slot.closeInput()?.endAudio()
    }

    func stop() {
        DictationTrace.event("legacy.stop")
        generation += 1
        taskGeneration += 1
        rotationTimeoutTask?.cancel()
        rotationTimeoutTask = nil
        task?.cancel()
        task = nil
        slot.replace(with: nil)?.endAudio()
        session?.stop()
        session = nil
        recognizer = nil
        forward = nil
        segmenter = LegacyTranscriptSegmenter()
        isFinishing = false
        restarts = []
    }

    private func beginTask(reason: String) {
        guard let recognizer else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = route == .onDevice
        request.addsPunctuation = true
        taskGeneration += 1
        let token = taskGeneration
        let slot = slot
        DictationTrace.event("legacy.task_begin", ["reason": reason, "task": "\(token)"])
        slot.replace(with: SpeechRequestTarget(request), token: token)?.endAudio()
        task = recognizer.recognitionTask(with: request) { result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failure = error as NSError?
            if isFinal || failure != nil {
                slot.detach(token)
            }
            Task { @MainActor [weak self] in
                self?.handle(text: text, isFinal: isFinal, failure: failure, token: token)
            }
        }
    }

    private func awaitRotation(of token: Int) {
        guard token == taskGeneration else { return }
        rotationTimeoutTask?.cancel()
        rotationTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: Self.rotationTimeout)
            guard !Task.isCancelled, let self, taskGeneration == token else { return }
            DictationTrace.event("legacy.rotation_timeout", ["task": "\(token)"])
            task?.cancel()
            taskGeneration += 1
            process(text: nil, isFinal: true, failure: nil, token: taskGeneration)
        }
    }

    private func handle(text: String?, isFinal: Bool, failure: NSError?, token: Int) {
        guard token == taskGeneration else { return }
        process(text: text, isFinal: isFinal, failure: failure, token: token)
    }

    private func process(text: String?, isFinal: Bool, failure: NSError?, token: Int) {
        let failed = failure != nil
        if let text, !isFinal {
            DictationTrace.event("legacy.partial", ["text": text, "task": "\(token)"])
            let events = segmenter.ingest(text)
            traceRestart(events)
            emit(events)
        }
        if let failure {
            DictationTrace.event("legacy.error", [
                "domain": failure.domain,
                "code": "\(failure.code)",
                "task": "\(token)",
            ])
        }
        if isFinal {
            DictationTrace.event("legacy.final", ["text": text ?? "", "task": "\(token)"])
            let events = segmenter.finalize(text ?? "")
            traceRestart(events)
            emit(events)
        } else if failed {
            emit(segmenter.flush())
        } else {
            return
        }
        rotationTimeoutTask?.cancel()
        rotationTimeoutTask = nil
        guard !isFinishing else {
            if slot.hasPending {
                drainPendingAudio()
                return
            }
            let ending: SpeechRecognitionEvent = failed && !isFinal ? .failed : .ended
            DictationTrace.event("legacy.session_ended", ["result": ending == .failed ? "failed" : "ended"])
            emit([ending])
            return
        }
        restartAfterTaskEnded(failed: failed && !isFinal)
    }

    private func drainPendingAudio() {
        DictationTrace.event("legacy.finish_drain", ["pendingSeconds": "\(slot.pendingDuration)"])
        beginTask(reason: "finish_drain")
        slot.closeInput()?.endAudio()
    }

    private func restartAfterTaskEnded(failed: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        restarts = restarts.filter { now - $0 < Self.restartWindow } + [now]
        guard !failed || restarts.count <= Self.restartLimit else {
            DictationTrace.event("legacy.session_ended", ["result": "failed", "reason": "restart_limit"])
            VoqoraLog.warn("SpeechRecognizer", "Recognition kept failing; ending the session")
            emit([.failed])
            return
        }
        VoqoraLog.info("SpeechRecognizer", "Recognition task ended mid-session; continuing in a new task", ["failed": "\(failed)"])
        beginTask(reason: failed ? "failure" : "final")
    }

    private func traceRestart(_ events: [SpeechRecognitionEvent]) {
        guard events.count > 1, case let .finalized(previous) = events[0] else { return }
        let replacement: String = switch events[events.count - 1] {
        case let .volatile(text), let .finalized(text): text
        default: ""
        }
        DictationTrace.event("legacy.restart_detected", ["previousText": previous, "newText": replacement])
    }

    private func emit(_ events: [SpeechRecognitionEvent]) {
        guard let forward else { return }
        events.forEach { forward($0) }
    }
}
