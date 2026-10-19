@testable import Voqora
import XCTest

final class PronunciationPlaybackTests: XCTestCase {
    func test_playsTheOriginalSentenceSoTheBackendAppliesRulesOnce() {
        let result = PronunciationTestResult(text: "I love GIF.", spoken: "I love jif.", replacements: 1, version: 3)

        XCTAssertEqual(PronunciationTestCard.playbackText(for: result), "I love GIF.")
    }

    func test_playsNothingWhenEverythingIsSkipped() {
        let result = PronunciationTestResult(text: "Um.", spoken: "", replacements: 1, version: 3)

        XCTAssertNil(PronunciationTestCard.playbackText(for: result))
    }
}
