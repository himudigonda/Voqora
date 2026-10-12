import Combine
@testable import Voqora
import XCTest

@MainActor
final class AudioServiceRenderTests: XCTestCase {
    private let sampleRate = 24000.0
    private let block = 1024.0 / 24000.0

    private func makeAudio(idleDelay: Duration = .seconds(30)) -> AudioService {
        AudioService(startingEngine: false, offlineRendering: true, engineIdleSuspendDelay: idleDelay)
    }

    private func pcm(seconds: Double, amplitude: Double) -> Data {
        let frames = Int(seconds * sampleRate)
        var data = Data(capacity: frames * 2)
        for index in 0 ..< frames {
            let value = Int16((amplitude * sin(2 * .pi * 150 * Double(index) / sampleRate) * 32767).rounded())
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    private func startStream(_ audio: AudioService, _ body: Data, estimatedSeconds: Double? = nil) {
        audio.prepareForStream()
        if let estimatedSeconds {
            audio.setEstimatedDuration(textLength: Int(estimatedSeconds * 12), speed: 1)
        }
        audio.playChunk(Data(count: 44) + body, volume: audio.volume)
    }

    private func peak(_ samples: [Float]) -> Float {
        samples.reduce(0) { max($0, abs($1)) }
    }

    private func audibleFrames(_ samples: [Float]) -> Int {
        samples.filter { abs($0) > 0.01 }.count
    }

    func test_offlineSeam_rendersStreamedAudio() async throws {
        let audio = makeAudio()
        startStream(audio, pcm(seconds: 1, amplitude: 0.8))

        let output = try await audio.renderForTesting(seconds: 0.5)

        XCTAssertGreaterThan(peak(output), 0.5)
    }

    func test_offlineSeam_completionHandlersReachMainActor() async throws {
        let audio = makeAudio()
        startStream(audio, pcm(seconds: 0.5, amplitude: 0.8))
        audio.finishStream()

        _ = try await audio.renderForTesting(seconds: 1)

        XCTAssertTrue(audio.playbackCompleted)
    }

    func test_seek_doesNotReplayAudioFromBeforeTheSeek() async throws {
        let audio = makeAudio()
        startStream(audio, pcm(seconds: 1, amplitude: 0.8) + pcm(seconds: 1, amplitude: 0))
        audio.finishStream()
        _ = try await audio.renderForTesting(seconds: 0.25)

        audio.seek(toSeconds: 1.5)
        let output = try await audio.renderForTesting(seconds: 2 * block)

        XCTAssertLessThan(peak(output), 0.01)
    }

    func test_seekAtDoubleSpeed_doesNotReplayAudioFromBeforeTheSeek() async throws {
        let audio = makeAudio()
        startStream(audio, pcm(seconds: 1, amplitude: 0.8) + pcm(seconds: 1, amplitude: 0))
        audio.setPlaybackRate(2.0)
        audio.finishStream()
        _ = try await audio.renderForTesting(seconds: 0.2)

        audio.seek(toSeconds: 1.5)
        let output = try await audio.renderForTesting(seconds: 2 * block)

        XCTAssertLessThan(peak(output), 0.01)
    }

    func test_stopThenPlay_startsCleanFromZero() async throws {
        let audio = makeAudio()
        startStream(audio, pcm(seconds: 1, amplitude: 0) + pcm(seconds: 1, amplitude: 0.8))
        audio.finishStream()
        _ = try await audio.renderForTesting(seconds: 1.2)

        audio.stop()
        audio.resume()
        let output = try await audio.renderForTesting(seconds: 2 * block)

        XCTAssertLessThan(peak(output), 0.01)
    }

    func test_rapidSeekSpam_finishesExactlyOnceAtTheEnd() async throws {
        let audio = makeAudio()
        var completions = 0
        let subscription = audio.$playbackCompleted.sink {
            if $0 {
                completions += 1
            }
        }
        defer { subscription.cancel() }
        startStream(audio, pcm(seconds: 2, amplitude: 0.8))
        audio.finishStream()

        for index in 0 ..< 50 {
            audio.seek(toSeconds: Double(index % 10) * 0.1)
            _ = try await audio.renderForTesting(seconds: block)
            XCTAssertFalse(audio.playbackCompleted)
        }
        _ = try await audio.renderForTesting(seconds: 3)

        XCTAssertTrue(audio.playbackCompleted)
        XCTAssertEqual(completions, 1)
    }

    func test_streamUnderrun_positionStopsAtLastScheduledAudio() async throws {
        let audio = makeAudio()
        startStream(audio, pcm(seconds: 1, amplitude: 0.8), estimatedSeconds: 50)

        _ = try await audio.renderForTesting(seconds: 3)

        XCTAssertLessThanOrEqual(audio.currentTime, 1.05)
    }

    func test_streamUnderrun_positionResumesFromRealAudioAfterRefill() async throws {
        let audio = makeAudio()
        startStream(audio, pcm(seconds: 1, amplitude: 0.8), estimatedSeconds: 50)
        _ = try await audio.renderForTesting(seconds: 3)

        audio.playChunk(pcm(seconds: 1, amplitude: 0.8), volume: audio.volume)
        _ = try await audio.renderForTesting(seconds: 0.5)

        XCTAssertEqual(audio.currentTime, 1.5, accuracy: 0.1)
    }

    func test_streamUnderrun_atDoubleSpeed_doesNotCutTheEndOff() async throws {
        let audio = makeAudio()
        startStream(audio, pcm(seconds: 1, amplitude: 0.8), estimatedSeconds: 50)
        audio.setPlaybackRate(2.0)
        _ = try await audio.renderForTesting(seconds: 2)

        audio.playChunk(pcm(seconds: 1, amplitude: 0.8), volume: audio.volume)
        audio.finishStream()
        let output = try await audio.renderForTesting(seconds: 0.2)

        XCTAssertFalse(audio.playbackCompleted)
        XCTAssertGreaterThan(peak(output), 0.5)
        XCTAssertEqual(audio.currentTime, 1.4, accuracy: 0.2)
    }

    func test_orphanedBuffers_stillFinishFromTheTimerFallback() async throws {
        let audio = makeAudio()
        startStream(audio, pcm(seconds: 0.5, amplitude: 0.8), estimatedSeconds: 50)
        audio.finishStream()
        audio.orphanScheduledBuffersForTesting()

        _ = try await audio.renderForTesting(seconds: 2)

        XCTAssertTrue(audio.playbackCompleted)
    }

    func test_configurationChangeWhilePlaying_resumesFromCurrentPosition() async throws {
        let audio = makeAudio()
        startStream(audio, pcm(seconds: 2, amplitude: 0.8))
        audio.finishStream()
        _ = try await audio.renderForTesting(seconds: 0.5)

        audio.simulateConfigurationChangeForTesting(dropsScheduledBuffers: true)
        let output = try await audio.renderForTesting(seconds: 0.25)

        XCTAssertGreaterThan(peak(output), 0.5)
        XCTAssertGreaterThanOrEqual(audio.currentTime, 0.75)
        XCTAssertLessThan(audio.currentTime, 1.0)
    }

    func test_configurationChangeWhilePaused_nextResumePlays() async throws {
        let audio = makeAudio()
        startStream(audio, pcm(seconds: 2, amplitude: 0.8))
        audio.finishStream()
        _ = try await audio.renderForTesting(seconds: 0.5)
        audio.pause()

        audio.simulateConfigurationChangeForTesting(dropsScheduledBuffers: true)
        audio.resume()
        let output = try await audio.renderForTesting(seconds: 0.25)

        XCTAssertGreaterThan(peak(output), 0.5)
    }

    func test_configurationChangeMidStream_doesNotDuplicateAudio() async throws {
        let audio = makeAudio()
        startStream(audio, pcm(seconds: 1, amplitude: 0.8), estimatedSeconds: 50)
        let before = try await audio.renderForTesting(seconds: 0.5)

        audio.simulateConfigurationChangeForTesting(dropsScheduledBuffers: true)
        audio.playChunk(pcm(seconds: 1, amplitude: 0.8), volume: audio.volume)
        audio.finishStream()
        let after = try await audio.renderForTesting(seconds: 3)

        XCTAssertEqual(audibleFrames(before) + audibleFrames(after), 48000, accuracy: 4096)
    }

    func test_pause_keepsEngineRunning() async throws {
        let audio = makeAudio()
        startStream(audio, pcm(seconds: 2, amplitude: 0.8))
        _ = try await audio.renderForTesting(seconds: 0.2)

        audio.pause()

        XCTAssertTrue(audio.engineIsRunningForTesting)
    }

    func test_engineSuspendsAfterIdleDelay() async throws {
        let audio = makeAudio(idleDelay: .milliseconds(50))
        startStream(audio, pcm(seconds: 2, amplitude: 0.8))
        _ = try await audio.renderForTesting(seconds: 0.2)

        audio.pause()
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertFalse(audio.engineIsRunningForTesting)
    }

    func test_resumeAfterIdleSuspend_playsAudio() async throws {
        let audio = makeAudio(idleDelay: .milliseconds(50))
        startStream(audio, pcm(seconds: 2, amplitude: 0.8))
        _ = try await audio.renderForTesting(seconds: 0.2)
        audio.pause()
        try await Task.sleep(for: .milliseconds(300))

        audio.resume()
        let output = try await audio.renderForTesting(seconds: 0.25)

        XCTAssertTrue(audio.engineIsRunningForTesting)
        XCTAssertGreaterThan(peak(output), 0.5)
    }

    func test_idleSuspendCancelledByResume() async throws {
        let audio = makeAudio(idleDelay: .milliseconds(100))
        startStream(audio, pcm(seconds: 5, amplitude: 0.8))
        _ = try await audio.renderForTesting(seconds: 0.2)

        audio.pause()
        audio.resume()
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertTrue(audio.engineIsRunningForTesting)
        XCTAssertTrue(audio.isPlaying)
    }

    func test_volumeBoost_doesNotExceedFullScale() async throws {
        let audio = makeAudio()
        audio.setVolume(1.5)
        try await Task.sleep(for: .milliseconds(150))
        startStream(audio, pcm(seconds: 1, amplitude: 0.99))

        let output = try await audio.renderForTesting(seconds: 1)

        XCTAssertLessThanOrEqual(peak(output), 1.001)
    }

    func test_unityVolume_isNotAttenuated() async throws {
        let audio = makeAudio()
        startStream(audio, pcm(seconds: 1, amplitude: 0.5))

        let output = try await audio.renderForTesting(seconds: 1)

        XCTAssertEqual(peak(output), 0.5, accuracy: 0.01)
    }
}
