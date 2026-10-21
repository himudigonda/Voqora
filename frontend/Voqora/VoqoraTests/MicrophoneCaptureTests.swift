import AVFoundation
import Speech
@testable import Voqora
import XCTest

final class MicrophoneCaptureTests: XCTestCase {
    private func stereoBuffer(left: Float, right: Float, frames: AVAudioFrameCount = 1024, sampleRate: Double = 48000) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for index in 0 ..< Int(frames) {
            buffer.floatChannelData?[0][index] = left
            buffer.floatChannelData?[1][index] = right
        }
        return buffer
    }

    func test_levelUsesTheLoudestChannel() throws {
        let buffer = try stereoBuffer(left: 0, right: 0.5)

        XCTAssertEqual(MicrophoneMetering.loudestChannelRMS(of: buffer), 0.5, accuracy: 0.001)
    }

    func test_levelOfSilenceIsZero() throws {
        XCTAssertEqual(try MicrophoneMetering.loudestChannelRMS(of: stereoBuffer(left: 0, right: 0)), 0)
    }

    func test_levelHandlesInterleavedBuffers() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: true))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256))
        buffer.frameLength = 256
        let data = try XCTUnwrap(buffer.floatChannelData?[0])
        for frame in 0 ..< 256 {
            data[frame * 2] = 0
            data[frame * 2 + 1] = 0.25
        }

        XCTAssertEqual(MicrophoneMetering.loudestChannelRMS(of: buffer), 0.25, accuracy: 0.001)
    }

    func test_monoConversionKeepsASignalThatOnlyTheSecondChannelCarries() throws {
        let buffer = try stereoBuffer(left: 0, right: 0.5)
        let mono = try XCTUnwrap(MonoDownmixer().convert(buffer))

        XCTAssertEqual(mono.format.channelCount, 1)
        XCTAssertEqual(mono.format.commonFormat, .pcmFormatFloat32)
        XCTAssertEqual(mono.format.sampleRate, 48000)
        XCTAssertEqual(mono.frameLength, 1024)
        XCTAssertGreaterThan(MicrophoneMetering.loudestChannelRMS(of: mono), 0.1)
    }

    func test_monoConversionKeepsTheBufferOwnSampleRate() throws {
        let buffer = try stereoBuffer(left: 0.3, right: 0.3, sampleRate: 44100)
        let mono = try XCTUnwrap(MonoDownmixer().convert(buffer))

        XCTAssertEqual(mono.format.sampleRate, 44100)
    }

    func test_converterTailFlushKeepsTheTotalFrameCount() async throws {
        guard #available(macOS 26, *) else { throw XCTSkip("SpeechAnalyzer needs macOS 26") }
        let source = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false))
        let target = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false))
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let feed = AnalyzerInputFeed(format: target, continuation: continuation)
        for _ in 0 ..< 470 {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 1024))
            buffer.frameLength = 1024
            for index in 0 ..< 1024 {
                let sample = sin(Float(index) * 0.05) * 0.5
                buffer.floatChannelData?[0][index] = sample
                buffer.floatChannelData?[1][index] = sample
            }
            feed.append(buffer)
        }
        feed.finish()

        let collected = await drain(stream)
        let expected = Double(470 * 1024) / 3
        XCTAssertEqual(Double(collected), expected, accuracy: 64)
    }

    func test_feedFinishWithoutAudioFinishesTheStream() async throws {
        guard #available(macOS 26, *) else { throw XCTSkip("SpeechAnalyzer needs macOS 26") }
        let target = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false))
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let feed = AnalyzerInputFeed(format: target, continuation: continuation)
        feed.finish()

        let drained = await drain(stream)
        XCTAssertEqual(drained, 0)
    }

    func test_watchdogStaysHealthyWhileBuffersArrive() {
        var watchdog = CaptureWatchdog(timeout: 2, startedAt: 100)
        for second in stride(from: 100.0, through: 110, by: 0.5) {
            watchdog.bufferArrived(at: second)
            XCTAssertEqual(watchdog.evaluate(at: second + 0.4), .healthy)
        }
    }

    func test_watchdogRestartsOnceThenFails() {
        var watchdog = CaptureWatchdog(timeout: 2, startedAt: 100)

        XCTAssertEqual(watchdog.evaluate(at: 101.9), .healthy)
        XCTAssertEqual(watchdog.evaluate(at: 102), .restart)
        XCTAssertEqual(watchdog.evaluate(at: 103.9), .healthy)
        XCTAssertEqual(watchdog.evaluate(at: 104), .fail)
    }

    func test_watchdogRearmsAfterAnotherBufferArrives() {
        var watchdog = CaptureWatchdog(timeout: 2, startedAt: 100)

        XCTAssertEqual(watchdog.evaluate(at: 102), .restart)
        watchdog.bufferArrived(at: 102.5)
        XCTAssertEqual(watchdog.evaluate(at: 104.4), .healthy)
        XCTAssertEqual(watchdog.evaluate(at: 104.5), .restart)
    }

    func test_sessionStopIsIdempotentWithoutStart() {
        let sink = MicrophoneTapSink(forward: { _ in }, consume: { _ in })
        let session = MicrophoneSession(sink: sink) { _ in }

        session.stop()
        session.stop()
    }

    func test_sessionWatchdogUsesTheInjectedClockAndStaysQuietWhenNotCapturing() {
        let sink = MicrophoneTapSink(forward: { _ in }, consume: { _ in })
        let failures = LockedCounter()
        let session = MicrophoneSession(sink: sink, clock: { 1000 }) { _ in failures.increment() }

        session.evaluateWatchdog()

        XCTAssertEqual(failures.value, 0)
    }

    @available(macOS 26, *)
    private func drain(_ stream: AsyncStream<AnalyzerInput>) async -> AVAudioFrameCount {
        var frames: AVAudioFrameCount = 0
        for await input in stream {
            frames += input.buffer.frameLength
        }
        return frames
    }
}

final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
    }
}
