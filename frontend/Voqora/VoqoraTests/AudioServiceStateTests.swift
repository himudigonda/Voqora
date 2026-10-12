@testable import Voqora
import XCTest

@MainActor
final class AudioServiceStateTests: XCTestCase {
    func test_prepareForStreamDoesNotClaimPlaybackBeforeAudioArrives() {
        let audio = AudioService(startingEngine: false)

        audio.prepareForStream()

        XCTAssertFalse(audio.isPlaying)
        XCTAssertEqual(audio.duration, 0)
    }

    func test_playbackRate_defaultsToNormalSpeed() {
        let audio = AudioService(startingEngine: false)
        XCTAssertEqual(audio.playbackRate, 1.0)
    }

    func test_setPlaybackRate_appliesWithinRange() {
        let audio = AudioService(startingEngine: false)
        audio.setPlaybackRate(2.0)
        XCTAssertEqual(audio.playbackRate, 2.0)
    }

    func test_setPlaybackRate_clampsOutOfRangeValues() {
        let audio = AudioService(startingEngine: false)
        audio.setPlaybackRate(10.0)
        XCTAssertEqual(audio.playbackRate, 2.5, "rate must clamp to the documented upper bound")

        audio.setPlaybackRate(0.1)
        XCTAssertEqual(audio.playbackRate, 0.5, "rate must clamp to the documented lower bound")
    }

    func test_stop_resetsPlaybackRateToNormalSpeed() {
        let audio = AudioService(startingEngine: false)
        audio.setPlaybackRate(1.75)
        audio.stop()
        XCTAssertEqual(audio.playbackRate, 1.0, "an audiobook's chosen speed must never bleed into the next TTS clip")
    }

    func test_stopMidStream_trimsDurationToRenderedAudio() {
        let audio = AudioService(startingEngine: false)
        audio.prepareForStream()
        audio.setEstimatedDuration(textLength: 1200, speed: 1)
        audio.playChunk(Data(count: 44) + Data(count: 48000), volume: 1)

        audio.stop()

        XCTAssertEqual(audio.duration, 1.0, accuracy: 0.01)
    }

    func test_isSlowEngineCall_thresholdIs100ms() {
        XCTAssertFalse(AudioService.isSlowEngineCall(milliseconds: 99))
        XCTAssertFalse(AudioService.isSlowEngineCall(milliseconds: 100))
        XCTAssertTrue(AudioService.isSlowEngineCall(milliseconds: 101))
    }

    func test_stopBeforeAnyAudio_leavesNothingToPlay() {
        let audio = AudioService(startingEngine: false)
        audio.prepareForStream()
        audio.setEstimatedDuration(textLength: 1200, speed: 1)

        audio.stop()

        XCTAssertEqual(audio.duration, 0)
    }
}
