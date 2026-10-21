@testable import Voqora
import XCTest

final class ProcessingTimeEstimateTests: XCTestCase {
    func test_kokoroKeepsTheBackendEstimate() {
        XCTAssertEqual(ProcessingTimeEstimate.seconds(forVoice: "af_bella", audioSeconds: 3600, baselineSeconds: 900), 900)
    }

    func test_supertonicFallsBackToTheKokoroEstimate() {
        XCTAssertEqual(ProcessingTimeEstimate.seconds(forVoice: "supertonic:M1", audioSeconds: 3600, baselineSeconds: 900), 900)
    }

    func test_mingScalesWithAudioLengthPlusColdStart() {
        XCTAssertEqual(ProcessingTimeEstimate.seconds(forVoice: "ming:US_James", audioSeconds: 1000, baselineSeconds: 5), 3260, accuracy: 0.001)
        XCTAssertEqual(ProcessingTimeEstimate.seconds(forVoice: "ming:custom:abc", audioSeconds: 0, baselineSeconds: 5), 60, accuracy: 0.001)
    }

    func test_mingIgnoresNegativeAudioLength() {
        XCTAssertEqual(ProcessingTimeEstimate.seconds(forVoice: "ming:US_James", audioSeconds: -20, baselineSeconds: 5), 60, accuracy: 0.001)
    }

    func test_onlyMingShowsTheSlowerThanRealTimeNote() {
        XCTAssertEqual(ProcessingTimeEstimate.note(forVoice: "ming:US_James"), "Ming renders slower than real time.")
        XCTAssertNil(ProcessingTimeEstimate.note(forVoice: "af_bella"))
        XCTAssertNil(ProcessingTimeEstimate.note(forVoice: "supertonic:F2"))
    }
}
