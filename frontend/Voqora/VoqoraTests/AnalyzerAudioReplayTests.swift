import AVFoundation
import Speech
@testable import Voqora
import XCTest

final class AnalyzerAudioReplayTests: XCTestCase {
    func test_recordedAudioThroughSpeechAnalyzerKeepsEverySentence() async throws {
        guard #available(macOS 26, *) else { throw XCTSkip("SpeechAnalyzer needs macOS 26") }
        guard let locale = await AnalyzerSpeechRecognizer.supportedLocale(for: "en_US") else {
            throw XCTSkip("SpeechTranscriber is unavailable on this Mac")
        }
        let transcriber = AnalyzerSpeechRecognizer.transcriber(for: locale)
        if try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) != nil {
            throw XCTSkip("The en-US speech model is not installed")
        }
        let bestFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        let format = try XCTUnwrap(bestFormat)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let feed = AnalyzerInputFeed(format: format, continuation: continuation)
        let collector = Task { () throws -> DictationStateMachine in
            var machine = DictationStateMachine()
            _ = machine.handle(.toggle)
            _ = machine.handle(.ready)
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                _ = machine.handle(result.isFinal ? .segmentFinalized(text) : .volatileChanged(text))
            }
            return machine
        }
        try await analyzer.start(inputSequence: stream)

        let file = try AVAudioFile(forReading: DictationFixtures.url("multi-paragraph-49s", "m4a"))
        let chunk = AVAudioFrameCount(file.processingFormat.sampleRate / 10)
        while file.framePosition < file.length {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk))
            try file.read(into: buffer, frameCount: chunk)
            feed.append(buffer)
        }
        continuation.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()

        var machine = try await collector.value
        _ = machine.handle(.toggle)
        guard case let .insert(text) = machine.handle(.recognitionEnded) else {
            return XCTFail("Nothing was inserted")
        }
        let score = try TranscriptScoring.score(reference: DictationFixtures.reference("multi-paragraph-49s"), hypothesis: text)
        XCTAssertEqual(score.droppedSentences, 0)
        XCTAssertEqual(score.repeatedInsertions, 0)
        XCTAssertLessThanOrEqual(score.wordErrorRate, 0.06)
    }

    func test_inputFeedResamplesWithoutLosingAudio() throws {
        guard #available(macOS 26, *) else { throw XCTSkip("SpeechAnalyzer needs macOS 26") }
        let source = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false))
        let target = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false))
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let feed = AnalyzerInputFeed(format: target, continuation: continuation)
        var produced: AVAudioFrameCount = 0
        for _ in 0 ..< 470 {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 1024))
            buffer.frameLength = 1024
            for index in 0 ..< 1024 {
                buffer.floatChannelData?[0][index] = sin(Float(index) * 0.05) * 0.5
            }
            produced += feed.convert(buffer)?.frameLength ?? 0
        }
        continuation.finish()
        _ = stream

        let expected = Double(470 * 1024) / 3
        XCTAssertEqual(Double(produced), expected, accuracy: 64)
    }
}
