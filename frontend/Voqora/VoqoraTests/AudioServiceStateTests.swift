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
}
