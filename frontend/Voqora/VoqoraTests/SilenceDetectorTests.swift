@testable import Voqora
import XCTest

final class SilenceDetectorTests: XCTestCase {
    func test_silenceAfterSpeechTriggersOnceTheTimeoutElapses() {
        var detector = SilenceDetector(timeout: 2, startedAt: 0)

        XCTAssertFalse(detector.process(level: 0.8, at: 1))
        XCTAssertFalse(detector.process(level: 0.05, at: 2.5))
        XCTAssertTrue(detector.process(level: 0.05, at: 3))
    }

    func test_speechResetsTheSilenceTimer() {
        var detector = SilenceDetector(timeout: 2, startedAt: 0)

        XCTAssertFalse(detector.process(level: 0.8, at: 1))
        XCTAssertFalse(detector.process(level: 0.8, at: 3))
        XCTAssertFalse(detector.process(level: 0.05, at: 4.5))
        XCTAssertTrue(detector.process(level: 0.05, at: 5))
    }

    func test_transcriptActivityCountsAsSpeech() {
        var detector = SilenceDetector(timeout: 2, startedAt: 0)
        detector.registerActivity(at: 7)

        XCTAssertTrue(detector.hasHeardSpeech)
        XCTAssertFalse(detector.process(level: 0, at: 8.5))
        XCTAssertTrue(detector.process(level: 0, at: 9))
    }

    func test_beforeAnySpeechTheInitialGraceApplies() {
        var detector = SilenceDetector(timeout: 2, startedAt: 10, initialGrace: 6)

        XCTAssertFalse(detector.hasHeardSpeech)
        XCTAssertFalse(detector.process(level: 0, at: 15))
        XCTAssertTrue(detector.process(level: 0, at: 16))
    }

    func test_longTimeoutOutlastsTheInitialGrace() {
        var detector = SilenceDetector(timeout: 8, startedAt: 0, initialGrace: 6)

        XCTAssertFalse(detector.process(level: 0, at: 7))
        XCTAssertTrue(detector.process(level: 0, at: 8))
    }

    func test_inputsAreClampedToSafeRanges() {
        let detector = SilenceDetector(timeout: -1, startedAt: 0, threshold: 4, initialGrace: -3)

        XCTAssertEqual(detector.timeout, SilenceDetector.minimumTimeout)
        XCTAssertEqual(detector.threshold, 1)
        XCTAssertEqual(detector.initialGrace, 0)
    }

    func test_olderActivityNeverRewindsTheLatestActivity() {
        var detector = SilenceDetector(timeout: 2, startedAt: 0)
        detector.registerActivity(at: 5)
        detector.registerActivity(at: 3)

        XCTAssertFalse(detector.process(level: 0, at: 6.5))
        XCTAssertTrue(detector.process(level: 0, at: 7))
    }

    func test_rmsOfSilenceIsZero() {
        XCTAssertEqual(AudioLevel.rms([Float]()), 0)
        XCTAssertEqual(AudioLevel.rms([Float](repeating: 0, count: 16)), 0)
    }

    func test_rmsOfConstantSignalIsItsMagnitude() {
        let samples: [Float] = [0.5, -0.5, 0.5, -0.5]

        XCTAssertEqual(AudioLevel.rms(samples), 0.5, accuracy: 0.0001)
    }

    func test_normalizedLevelMapsDecibelsIntoUnitRange() {
        XCTAssertEqual(AudioLevel.normalized(rms: 1), 1, accuracy: 0.0001)
        XCTAssertEqual(AudioLevel.normalized(rms: 0.0562), 0.5, accuracy: 0.01)
        XCTAssertEqual(AudioLevel.normalized(rms: 0.000001), 0)
        XCTAssertEqual(AudioLevel.normalized(rms: 0), 0)
        XCTAssertEqual(AudioLevel.normalized(rms: .nan), 0)
        XCTAssertEqual(AudioLevel.normalized(rms: 4), 1)
    }
}
