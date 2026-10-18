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
final class SpeechRelayPlayer {
    private let speaker: any SpeechInputSpeaking
    private let announce: @MainActor (String) -> Void

    init(speaker: any SpeechInputSpeaking, announce: @escaping @MainActor (String) -> Void) {
        self.speaker = speaker
        self.announce = announce
    }

    func handle(_ event: IntegrationEvent) {
        switch event {
        case .ready:
            break
        case let .speak(command):
            VoqoraLog.info("SpeechRelay", "Speaking local API request", [
                "chars": "\(command.text.count)",
                "namedVoice": command.voice == nil ? "false" : "true",
            ])
            if let client = command.client {
                announce(Self.announcement(for: client))
            }
            let speaker = speaker
            Task { await speaker.speak(text: command.text, voice: command.voice) }
        case .stop:
            VoqoraLog.info("SpeechRelay", "Stopping speech for local API request")
            speaker.stopPlayback()
        }
    }

    static func announcement(for client: String) -> String {
        "Spoken by \(client)"
    }
}
