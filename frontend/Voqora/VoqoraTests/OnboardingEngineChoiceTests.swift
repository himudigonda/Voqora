@testable import Voqora
import XCTest

@MainActor
final class OnboardingEngineChoiceTests: XCTestCase {
    private let engines = [SpeechEngineTests.kokoro, SpeechEngineTests.ming(), SpeechEngineTests.supertonic()]

    func testKeepsVoiceThatAlreadyBelongsToTheEngine() {
        XCTAssertEqual(OnboardingEngineChoice.voice(switching: "ming:CN_Xiaoyu", to: SpeechEngineID.ming, in: engines), "ming:CN_Xiaoyu")
        XCTAssertEqual(OnboardingEngineChoice.voice(switching: "af_sky", to: SpeechEngineID.kokoro, in: engines), "af_sky")
    }

    func testSwitchingToKokoroPicksTheDefaultVoice() {
        XCTAssertEqual(OnboardingEngineChoice.voice(switching: "ming:US_James", to: SpeechEngineID.kokoro, in: engines), "af_bella")
    }

    func testSwitchingToMingPrefersABuiltInEnglishVoice() {
        XCTAssertEqual(OnboardingEngineChoice.voice(switching: "af_bella", to: SpeechEngineID.ming, in: engines), "ming:US_James")
    }

    func testSwitchingToAnEngineThatIsNotInstalledReturnsNil() {
        let notInstalled = [SpeechEngineTests.kokoro, SpeechEngineTests.ming(installed: false)]
        XCTAssertNil(OnboardingEngineChoice.voice(switching: "af_bella", to: SpeechEngineID.ming, in: notInstalled))
    }

    func testSwitchingToSupertonicFallsBackToFirstVoice() {
        XCTAssertEqual(OnboardingEngineChoice.voice(switching: "af_bella", to: SpeechEngineID.supertonic, in: engines), "supertonic:M1")
    }
}
