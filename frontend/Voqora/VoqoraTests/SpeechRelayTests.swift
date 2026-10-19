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

@MainActor
private final class ActivitySpeakerSpy: SpeechActivityReporting {
    var isBackendOnline = true
    var selectedVoice = "af_heart"
    var speechSpeed = 1.0
    var isSpeechActive = false
    let interrupts = SpeechInterruptSignal()
    private(set) var spoken: [String] = []
    private(set) var stopCount = 0

    func speak(text: String, voice _: String?) async {
        interrupts.fire()
        spoken.append(text)
        isSpeechActive = true
    }

    func togglePlayback() {}

    func stopPlayback() {
        interrupts.fire()
        stopCount += 1
        isSpeechActive = false
    }

    func showTransientError(_: String) {}
}

@MainActor
final class SpeechRelayQueueTests: XCTestCase {
    private func command(_ text: String, _ mode: RelaySpeakMode, client: String? = nil) -> IntegrationEvent {
        .speak(RelaySpeakCommand(id: text, text: text, voice: nil, client: client, mode: mode))
    }

    private func makePlayer(_ speaker: ActivitySpeakerSpy, announcements: AnnouncementLog? = nil) -> SpeechRelayPlayer {
        SpeechRelayPlayer(speaker: speaker, announce: { announcements?.values.append($0) }, interrupts: speaker.interrupts, sleep: { _ in await Task.yield() })
    }

    func test_queuedSpeechWaitsForTheCurrentSpeechAndPlaysInOrder() async {
        let speaker = ActivitySpeakerSpy()
        let player = makePlayer(speaker)

        player.handle(command("A", .replace))
        await yieldUntil { speaker.spoken == ["A"] }
        player.handle(command("B", .queue))
        player.handle(command("C", .queue))
        for _ in 0 ..< 50 {
            await Task.yield()
        }
        XCTAssertEqual(speaker.spoken, ["A"])
        XCTAssertEqual(player.queuedCount, 2)

        speaker.isSpeechActive = false
        await yieldUntil { speaker.spoken == ["A", "B"] }
        for _ in 0 ..< 50 {
            await Task.yield()
        }
        XCTAssertEqual(speaker.spoken, ["A", "B"])

        speaker.isSpeechActive = false
        await yieldUntil { speaker.spoken == ["A", "B", "C"] }
        XCTAssertEqual(speaker.spoken, ["A", "B", "C"])
        XCTAssertEqual(player.queuedCount, 0)
    }

    func test_queuedSpeechStartsAtOnceWhenNothingIsPlaying() async {
        let speaker = ActivitySpeakerSpy()
        let player = makePlayer(speaker)

        player.handle(command("A", .queue))
        await yieldUntil { speaker.spoken == ["A"] }

        XCTAssertEqual(speaker.spoken, ["A"])
        XCTAssertEqual(speaker.stopCount, 0)
    }

    func test_stopClearsTheQueue() async {
        let speaker = ActivitySpeakerSpy()
        let player = makePlayer(speaker)

        player.handle(command("A", .replace))
        await yieldUntil { speaker.spoken == ["A"] }
        player.handle(command("B", .queue))
        player.handle(.stop(id: "s"))
        for _ in 0 ..< 100 {
            await Task.yield()
        }

        XCTAssertEqual(speaker.spoken, ["A"])
        XCTAssertEqual(speaker.stopCount, 1)
        XCTAssertEqual(player.queuedCount, 0)
    }

    func test_userStopClearsTheQueue() async {
        let speaker = ActivitySpeakerSpy()
        let player = makePlayer(speaker)

        player.handle(command("A", .replace))
        await yieldUntil { speaker.spoken == ["A"] }
        player.handle(command("B", .queue))
        player.handle(command("C", .queue))
        XCTAssertEqual(player.queuedCount, 2)

        speaker.stopPlayback()
        for _ in 0 ..< 100 {
            await Task.yield()
        }

        XCTAssertEqual(player.queuedCount, 0)
        XCTAssertEqual(speaker.spoken, ["A"])
    }

    func test_userSpeechClearsQueuedRelayParts() async {
        let speaker = ActivitySpeakerSpy()
        let player = makePlayer(speaker)

        player.handle(command("A", .replace))
        await yieldUntil { speaker.spoken == ["A"] }
        player.handle(command("B", .queue))
        XCTAssertEqual(player.queuedCount, 1)

        speaker.interrupts.fire()
        speaker.isSpeechActive = false
        for _ in 0 ..< 100 {
            await Task.yield()
        }

        XCTAssertEqual(player.queuedCount, 0)
        XCTAssertEqual(speaker.spoken, ["A"])
    }

    func test_relayedSpeechKeepsItsOwnQueue() async {
        let speaker = ActivitySpeakerSpy()
        let player = makePlayer(speaker)

        player.handle(command("A", .replace))
        await yieldUntil { speaker.spoken == ["A"] }
        player.handle(command("B", .queue))
        player.handle(command("C", .queue))
        speaker.isSpeechActive = false
        await yieldUntil { speaker.spoken == ["A", "B"] }

        XCTAssertEqual(player.queuedCount, 1)
    }

    func test_replaceDropsQueuedSpeech() async {
        let speaker = ActivitySpeakerSpy()
        let player = makePlayer(speaker)

        player.handle(command("A", .replace))
        await yieldUntil { speaker.spoken == ["A"] }
        player.handle(command("B", .queue))
        player.handle(command("C", .replace))
        await yieldUntil { speaker.spoken == ["A", "C"] }
        speaker.isSpeechActive = false
        for _ in 0 ..< 100 {
            await Task.yield()
        }

        XCTAssertEqual(speaker.spoken, ["A", "C"])
        XCTAssertEqual(player.queuedCount, 0)
    }

    func test_queuedClientIsAnnouncedWhenItsSpeechStarts() async {
        let speaker = ActivitySpeakerSpy()
        let announcements = AnnouncementLog()
        let player = makePlayer(speaker, announcements: announcements)

        player.handle(command("A", .replace))
        await yieldUntil { speaker.spoken == ["A"] }
        player.handle(command("B", .queue, client: "Raycast"))
        for _ in 0 ..< 50 {
            await Task.yield()
        }
        XCTAssertTrue(announcements.values.isEmpty)

        speaker.isSpeechActive = false
        await yieldUntil { speaker.spoken == ["A", "B"] }
        XCTAssertEqual(announcements.values, ["Spoken by Raycast"])
    }
}

@MainActor
private final class AnnouncementLog {
    var values: [String] = []
}

final class RelaySpeakModeParsingTests: XCTestCase {
    func test_modeDefaultsToReplaceAndAcceptsQueue() {
        XCTAssertEqual(
            IntegrationEventParser.event(fromLine: #"data: {"type":"speak","id":"a","text":"Hi","mode":"queue"}"#),
            .speak(RelaySpeakCommand(id: "a", text: "Hi", voice: nil, client: nil, mode: .queue))
        )
        XCTAssertEqual(
            IntegrationEventParser.event(fromLine: #"data: {"type":"speak","id":"a","text":"Hi","mode":"replace"}"#),
            .speak(RelaySpeakCommand(id: "a", text: "Hi", voice: nil, client: nil, mode: .replace))
        )
        XCTAssertEqual(
            IntegrationEventParser.event(fromLine: #"data: {"type":"speak","id":"a","text":"Hi","mode":"later"}"#),
            .speak(RelaySpeakCommand(id: "a", text: "Hi", voice: nil, client: nil, mode: .replace))
        )
    }
}
