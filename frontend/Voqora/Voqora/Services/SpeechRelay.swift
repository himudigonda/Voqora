import Foundation

nonisolated struct RelayBackoff: Equatable, Sendable {
    let initialSeconds: Double
    let maximumSeconds: Double

    static let standard = RelayBackoff(initialSeconds: 1, maximumSeconds: 30)

    func delaySeconds(afterFailures failures: Int) -> Double {
        guard failures > 0 else { return initialSeconds }
        let exponent = Double(min(failures - 1, 16))
        return min(maximumSeconds, initialSeconds * pow(2, exponent))
    }
}

@MainActor
final class SpeechRelaySubscriber {
    typealias Connect = @MainActor () -> AsyncThrowingStream<IntegrationEvent, Error>
    typealias Sleep = @Sendable (Double) async -> Void

    private let connect: Connect
    private let handle: @MainActor (IntegrationEvent) -> Void
    private let backoff: RelayBackoff
    private let sleep: Sleep
    private var task: Task<Void, Never>?
    private(set) var consecutiveFailures = 0

    init(
        connect: @escaping Connect,
        handle: @escaping @MainActor (IntegrationEvent) -> Void,
        backoff: RelayBackoff = .standard,
        sleep: Sleep? = nil
    ) {
        self.connect = connect
        self.handle = handle
        self.backoff = backoff
        self.sleep = sleep ?? { seconds in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    }

    var isRunning: Bool {
        task != nil
    }

    func start() {
        guard task == nil else { return }
        consecutiveFailures = 0
        VoqoraLog.info("SpeechRelay", "Listening for local API speech")
        task = Task { [weak self] in
            await self?.run()
        }
    }

    func stop() {
        guard let task else { return }
        task.cancel()
        self.task = nil
        VoqoraLog.info("SpeechRelay", "Stopped listening for local API speech")
    }

    private func run() async {
        while !Task.isCancelled {
            var connected = false
            do {
                for try await event in connect() {
                    guard !Task.isCancelled else { return }
                    if event == .ready {
                        connected = true
                        consecutiveFailures = 0
                    }
                    handle(event)
                }
            } catch {
                guard !Task.isCancelled else { return }
                VoqoraLog.warn("SpeechRelay", "Speech relay connection dropped", [
                    "failureCode": "speech_relay_disconnected",
                    "attempt": "\(consecutiveFailures + 1)",
                ])
            }
            guard !Task.isCancelled else { return }
            consecutiveFailures = connected ? 0 : consecutiveFailures + 1
            await sleep(backoff.delaySeconds(afterFailures: consecutiveFailures))
        }
    }
}

@MainActor
final class SpeechInterruptSignal {
    private var observers: [@MainActor () -> Void] = []

    func observe(_ observer: @escaping @MainActor () -> Void) {
        observers.append(observer)
    }

    func fire() {
        for observer in observers {
            observer()
        }
    }
}

@MainActor
protocol SpeechActivityReporting: SpeechInputSpeaking {
    var isSpeechActive: Bool { get }
}

extension DashboardViewModel: SpeechActivityReporting {
    var isSpeechActive: Bool {
        switch status {
        case .thinking, .speaking, .paused: true
        case .ready, .error: false
        }
    }
}

@MainActor
final class SpeechRelayPlayer {
    typealias Sleep = @Sendable (Double) async -> Void

    static let pollSeconds = 0.2
    static let settleSeconds = 0.3

    private let speaker: any SpeechInputSpeaking
    private let announce: @MainActor (String) -> Void
    private let sleep: Sleep
    private var pending: [RelaySpeakCommand] = []
    private var drainTask: Task<Void, Never>?
    private var isStartingRelayedSpeech = false

    init(
        speaker: any SpeechInputSpeaking,
        announce: @escaping @MainActor (String) -> Void,
        interrupts: SpeechInterruptSignal? = nil,
        sleep: Sleep? = nil
    ) {
        self.speaker = speaker
        self.announce = announce
        self.sleep = sleep ?? { seconds in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
        interrupts?.observe { [weak self] in
            self?.handleLocalInterrupt()
        }
    }

    var queuedCount: Int {
        pending.count
    }

    private var isSpeechActive: Bool {
        (speaker as? any SpeechActivityReporting)?.isSpeechActive ?? false
    }

    func handle(_ event: IntegrationEvent) {
        switch event {
        case .ready:
            break
        case let .speak(command):
            switch command.mode {
            case .replace:
                clearQueue()
                Task { await begin(command) }
            case .queue:
                pending.append(command)
                startDrainingIfNeeded()
            }
        case .stop:
            VoqoraLog.info("SpeechRelay", "Stopping speech for local API request")
            clearQueue()
            speaker.stopPlayback()
        }
    }

    private func handleLocalInterrupt() {
        guard !isStartingRelayedSpeech else { return }
        clearQueue()
    }

    private func clearQueue() {
        pending.removeAll()
        drainTask?.cancel()
        drainTask = nil
    }

    private func startDrainingIfNeeded() {
        guard drainTask == nil else { return }
        drainTask = Task { [weak self] in
            await self?.drain()
        }
    }

    private func drain() async {
        await sleep(Self.settleSeconds)
        while !Task.isCancelled, !pending.isEmpty {
            while !Task.isCancelled, isSpeechActive {
                await sleep(Self.pollSeconds)
            }
            guard !Task.isCancelled, !pending.isEmpty else { return }
            await begin(pending.removeFirst())
            await sleep(Self.settleSeconds)
        }
        if !Task.isCancelled {
            drainTask = nil
        }
    }

    private func begin(_ command: RelaySpeakCommand) async {
        VoqoraLog.info("SpeechRelay", "Speaking local API request", [
            "chars": "\(command.text.count)",
            "namedVoice": command.voice == nil ? "false" : "true",
            "queued": command.mode == .queue ? "true" : "false",
        ])
        if let client = command.client {
            announce(Self.announcement(for: client))
        }
        UsageStatsStore.shared.recordRelay(client: command.client ?? "")
        MetricsService.shared.trackRelayRequest(client: command.client)
        isStartingRelayedSpeech = true
        defer { isStartingRelayedSpeech = false }
        await SpeechSource.$current.withValue(.relay) {
            await speaker.speak(text: command.text, voice: command.voice)
        }
    }

    static func announcement(for client: String) -> String {
        "Spoken by \(client)"
    }
}
