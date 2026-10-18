import Foundation
@testable import Voqora
import XCTest

private final class DelayLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []

    var values: [Double] {
        lock.withLock { storage }
    }

    func record(_ value: Double) {
        lock.withLock { storage.append(value) }
    }
}

private struct SpokenRequest: Equatable {
    let text: String
    let voice: String?
}

private typealias EventContinuation = AsyncThrowingStream<IntegrationEvent, Error>.Continuation

@MainActor
private final class RelaySpeakerSpy: SpeechInputSpeaking {
    var isBackendOnline = true
    var selectedVoice = "af_heart"
    var speechSpeed = 1.0
    private(set) var spoken: [SpokenRequest] = []
    private(set) var stopCount = 0

    func speak(text: String, voice: String?) async {
        spoken.append(SpokenRequest(text: text, voice: voice))
    }

    func togglePlayback() {}

    func stopPlayback() {
        stopCount += 1
    }

    func showTransientError(_: String) {}
}

final class RelayBackoffTests: XCTestCase {
    func test_delaysDoubleUpToTheCap() {
        let backoff = RelayBackoff(initialSeconds: 1, maximumSeconds: 30)

        XCTAssertEqual(backoff.delaySeconds(afterFailures: 0), 1)
        XCTAssertEqual(backoff.delaySeconds(afterFailures: 1), 1)
        XCTAssertEqual(backoff.delaySeconds(afterFailures: 2), 2)
        XCTAssertEqual(backoff.delaySeconds(afterFailures: 4), 8)
        XCTAssertEqual(backoff.delaySeconds(afterFailures: 6), 30)
        XCTAssertEqual(backoff.delaySeconds(afterFailures: 500), 30)
    }
}

@MainActor
final class SpeechRelaySubscriberTests: XCTestCase {
    func test_reconnectsWithBackoffAndResetsAfterReady() async {
        let delays = DelayLog()
        var attempts = 0
        var liveStreams: [EventContinuation] = []
        var handled: [IntegrationEvent] = []
        let delivered = expectation(description: "events delivered")
        let subscriber = SpeechRelaySubscriber(
            connect: {
                attempts += 1
                let attempt = attempts
                return AsyncThrowingStream { continuation in
                    if attempt < 3 {
                        continuation.finish(throwing: URLError(.networkConnectionLost))
                    } else {
                        continuation.yield(.ready)
                        continuation.yield(.stop(id: "s"))
                        liveStreams.append(continuation)
                    }
                }
            },
            handle: { event in
                handled.append(event)
                if handled.count == 2 {
                    delivered.fulfill()
                }
            },
            backoff: RelayBackoff(initialSeconds: 1, maximumSeconds: 30),
            sleep: { delays.record($0) }
        )

        subscriber.start()
        XCTAssertTrue(subscriber.isRunning)
        await fulfillment(of: [delivered], timeout: 2)
        subscriber.stop()

        XCTAssertFalse(subscriber.isRunning)
        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(delays.values, [1, 2])
        XCTAssertEqual(handled, [.ready, .stop(id: "s")])
        XCTAssertEqual(subscriber.consecutiveFailures, 0)
        liveStreams.forEach { $0.finish() }
    }

    func test_cleanEndWithoutReadyCountsAsAFailure() async {
        let delays = DelayLog()
        var attempts = 0
        var liveStreams: [EventContinuation] = []
        let thirdAttempt = expectation(description: "third attempt")
        let subscriber = SpeechRelaySubscriber(
            connect: {
                attempts += 1
                if attempts == 3 {
                    thirdAttempt.fulfill()
                    return AsyncThrowingStream { liveStreams.append($0) }
                }
                return AsyncThrowingStream { $0.finish() }
            },
            handle: { _ in },
            sleep: { delays.record($0) }
        )

        subscriber.start()
        await fulfillment(of: [thirdAttempt], timeout: 2)
        subscriber.stop()

        XCTAssertEqual(delays.values, [1, 2])
        liveStreams.forEach { $0.finish() }
    }

    func test_startTwiceKeepsOneConnection() async {
        var attempts = 0
        var liveStreams: [EventContinuation] = []
        let connected = expectation(description: "connected")
        let subscriber = SpeechRelaySubscriber(
            connect: {
                attempts += 1
                connected.fulfill()
                return AsyncThrowingStream { liveStreams.append($0) }
            },
            handle: { _ in },
            sleep: { _ in }
        )

        subscriber.start()
        subscriber.start()
        await fulfillment(of: [connected], timeout: 2)
        subscriber.stop()

        XCTAssertEqual(attempts, 1)
        liveStreams.forEach { $0.finish() }
    }
}

@MainActor
final class SpeechRelayPlayerTests: XCTestCase {
    func test_speakEventsUseTheNormalSpeechPathAndAnnounceTheClient() async {
        let speaker = RelaySpeakerSpy()
        var announcements: [String] = []
        let player = SpeechRelayPlayer(speaker: speaker) { announcements.append($0) }

        player.handle(.speak(RelaySpeakCommand(id: "1", text: "Hello", voice: nil, client: "Claude Code")))
        player.handle(.speak(RelaySpeakCommand(id: "2", text: "Bonjour", voice: "ff_siwis", client: nil)))
        await yieldUntil { speaker.spoken.count == 2 }

        XCTAssertEqual(speaker.spoken, [
            SpokenRequest(text: "Hello", voice: nil),
            SpokenRequest(text: "Bonjour", voice: "ff_siwis"),
        ])
        XCTAssertEqual(announcements, ["Spoken by Claude Code"])
    }

    func test_stopEventsStopPlaybackAndReadyIsIgnored() {
        let speaker = RelaySpeakerSpy()
        let player = SpeechRelayPlayer(speaker: speaker) { _ in }

        player.handle(.ready)
        player.handle(.stop(id: "s"))

        XCTAssertEqual(speaker.stopCount, 1)
        XCTAssertTrue(speaker.spoken.isEmpty)
    }
}
