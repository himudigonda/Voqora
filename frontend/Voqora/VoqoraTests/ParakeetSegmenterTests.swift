@testable import Voqora
import XCTest

final class ParakeetSegmenterTests: XCTestCase {
    private let rate = ParakeetSegmenter.sampleRate

    private struct Signal {
        var samples: [Float] = []
        var silences: [Range<Int>] = []
        var seed: UInt32 = 12345
        let rate: Int

        mutating func noise() -> Float {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return (Float(seed >> 8) / Float(1 << 24) - 0.5) * 0.001
        }

        mutating func burst(_ seconds: Double, amplitude: Float = 0.3) {
            let start = samples.count
            for index in 0 ..< Int(seconds * Double(rate)) {
                let phase = Float(start + index) * 2 * .pi * 220 / Float(rate)
                samples.append(amplitude * sin(phase) * (0.6 + 0.4 * sin(phase / 40)))
            }
        }

        mutating func silence(_ seconds: Double) {
            let start = samples.count
            for _ in 0 ..< Int(seconds * Double(rate)) {
                samples.append(noise())
            }
            silences.append(start ..< samples.count)
        }

        mutating func tone(_ seconds: Double, amplitude: Float) {
            let start = samples.count
            for index in 0 ..< Int(seconds * Double(rate)) {
                samples.append(amplitude * sin(Float(start + index) * 2 * .pi * 220 / Float(rate)))
            }
        }

        mutating func digitalSilence(_ seconds: Double) {
            samples += [Float](repeating: 0, count: Int(seconds * Double(rate)))
        }
    }

    private func segments(of samples: [Float], chunk: Int) -> [ParakeetSegment] {
        var segmenter = ParakeetSegmenter()
        var closed: [ParakeetSegment] = []
        var index = 0
        while index < samples.count {
            let end = min(samples.count, index + chunk)
            closed += segmenter.append(Array(samples[index ..< end]))
            index = end
        }
        if let last = segmenter.finish() {
            closed.append(last)
        }
        return closed
    }

    private func assertCoversEverySampleOnce(_ segments: [ParakeetSegment], total: Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(segments.first?.range.lowerBound, 0, file: file, line: line)
        XCTAssertEqual(segments.last?.range.upperBound, total, file: file, line: line)
        for (previous, next) in zip(segments, segments.dropFirst()) {
            XCTAssertEqual(previous.range.upperBound, next.range.lowerBound, file: file, line: line)
        }
        XCTAssertEqual(segments.map(\.range.count).reduce(0, +), total, file: file, line: line)
        XCTAssertTrue(segments.allSatisfy { !$0.range.isEmpty }, file: file, line: line)
    }

    private func mixedSignal() -> Signal {
        var signal = Signal(rate: rate)
        signal.burst(2)
        signal.silence(0.2)
        signal.burst(2)
        signal.silence(0.8)
        signal.burst(2)
        signal.silence(3)
        signal.burst(2)
        signal.silence(12)
        signal.burst(2)
        return signal
    }

    func test_pausesCutInsideSilenceAndShortGapsDoNot() {
        let signal = mixedSignal()
        let closed = segments(of: signal.samples, chunk: 1000)
        assertCoversEverySampleOnce(closed, total: signal.samples.count)
        let cuts = closed.dropLast().map(\.range.upperBound)
        XCTAssertGreaterThanOrEqual(cuts.count, 3)
        for cut in cuts {
            XCTAssertTrue(signal.silences.contains { $0.contains(cut) }, "cut at \(cut) is not inside silence")
            XCTAssertFalse(signal.silences[0].contains(cut), "cut inside the 0.2 s gap")
        }
        XCTAssertTrue(closed.allSatisfy { $0.range.count <= ParakeetSegmenter.maximumSegmentSamples })
        XCTAssertTrue(closed.last?.containsSpeech ?? false)
    }

    func test_pauseOfEightTenthsClosesTheSegmentWithItsSpeech() {
        var signal = Signal(rate: rate)
        signal.burst(2)
        signal.silence(0.8)
        signal.burst(2)
        let closed = segments(of: signal.samples, chunk: 1024)
        XCTAssertEqual(closed.count, 2)
        XCTAssertTrue(closed.allSatisfy(\.containsSpeech))
        XCTAssertTrue(signal.silences[0].contains(closed[0].range.upperBound))
    }

    func test_continuousBurstIsForceCutAtOrBeforeTwentyFiveSeconds() {
        var signal = Signal(rate: rate)
        signal.burst(40)
        let closed = segments(of: signal.samples, chunk: 1024)
        assertCoversEverySampleOnce(closed, total: signal.samples.count)
        XCTAssertGreaterThanOrEqual(closed.count, 2)
        XCTAssertTrue(closed.allSatisfy { $0.range.count <= ParakeetSegmenter.maximumSegmentSamples })
        XCTAssertGreaterThanOrEqual(closed[0].range.upperBound, ParakeetSegmenter.maximumSegmentSamples - 3 * rate)
    }

    func test_forcedCutLandsInTheQuietestWindowOfTheLastThreeSeconds() {
        var signal = Signal(rate: rate)
        signal.burst(23)
        signal.silence(0.3)
        signal.burst(10)
        let closed = segments(of: signal.samples, chunk: 777)
        assertCoversEverySampleOnce(closed, total: signal.samples.count)
        XCTAssertTrue(signal.silences[0].contains(closed[0].range.upperBound))
    }

    func test_chunkSizeDoesNotChangeTheCuts() {
        let signal = mixedSignal()
        let reference = segments(of: signal.samples, chunk: 1024)
        for chunk in [7, 160, 479, 480, 481, 4800, 48000] {
            XCTAssertEqual(segments(of: signal.samples, chunk: chunk), reference, "chunk \(chunk)")
        }
    }

    func test_shortBurstBeforeAPauseKeepsTheSegmentOpen() {
        var signal = Signal(rate: rate)
        signal.burst(0.25)
        signal.silence(1.0)
        signal.burst(2)
        let closed = segments(of: signal.samples, chunk: 1024)
        assertCoversEverySampleOnce(closed, total: signal.samples.count)
        XCTAssertEqual(closed.count, 1)
    }

    func test_silenceOnlyAudioProducesNoSpeechSegments() {
        var signal = Signal(rate: rate)
        signal.silence(20)
        let closed = segments(of: signal.samples, chunk: 1024)
        assertCoversEverySampleOnce(closed, total: signal.samples.count)
        XCTAssertTrue(closed.allSatisfy { !$0.containsSpeech })
    }

    func test_quietSpeechBelowTheAdaptiveLevelIsKeptAsSpeech() {
        var signal = Signal(rate: rate)
        signal.burst(1)
        signal.tone(2, amplitude: 0.004)
        signal.digitalSilence(4)
        let closed = segments(of: signal.samples, chunk: 1024)
        assertCoversEverySampleOnce(closed, total: signal.samples.count)
        let quietMiddle = 2 * rate
        XCTAssertEqual(closed.first { $0.range.contains(quietMiddle) }?.containsSpeech, true)
    }

    func test_digitalSilenceProducesNoSpeechSegments() {
        var signal = Signal(rate: rate)
        signal.digitalSilence(20)
        let closed = segments(of: signal.samples, chunk: 1024)
        assertCoversEverySampleOnce(closed, total: signal.samples.count)
        XCTAssertFalse(closed.isEmpty)
        XCTAssertTrue(closed.allSatisfy { !$0.containsSpeech })
    }

    func test_emptyInputProducesNoSegments() {
        var segmenter = ParakeetSegmenter()
        XCTAssertTrue(segmenter.append([]).isEmpty)
        XCTAssertNil(segmenter.finish())
    }

    func test_trailingPartialFrameWithSpeechIsKept() {
        var signal = Signal(rate: rate)
        signal.silence(0.5)
        signal.samples += [Float](repeating: 0.3, count: 100)
        let closed = segments(of: signal.samples, chunk: 1024)
        assertCoversEverySampleOnce(closed, total: signal.samples.count)
        XCTAssertTrue(closed.last?.containsSpeech ?? false)
    }

    func test_sampleStoreFreesCommittedSamples() {
        var store = ParakeetSampleStore()
        store.append(Array(0 ..< 100).map(Float.init))
        XCTAssertEqual(store.take(0 ..< 40), Array(0 ..< 40).map(Float.init))
        XCTAssertEqual(store.suffix(from: 40).count, 60)
        store.discard(before: 70)
        XCTAssertEqual(store.suffix(from: 70), Array(70 ..< 100).map(Float.init))
        XCTAssertEqual(store.take(70 ..< 100).count, 30)
        XCTAssertTrue(store.suffix(from: 100).isEmpty)
    }
}
