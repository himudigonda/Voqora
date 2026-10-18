import Foundation
@testable import Voqora
import XCTest

final class OCRLanguagePreferenceTests: XCTestCase {
    func test_voiceLanguagesMapToVisionIdentifiers() {
        XCTAssertEqual(OCRLanguagePreference.visionLanguage(forVoice: "af_bella"), "en-US")
        XCTAssertEqual(OCRLanguagePreference.visionLanguage(forVoice: "bf_emma"), "en-GB")
        XCTAssertEqual(OCRLanguagePreference.visionLanguage(forVoice: "ef_dora"), "es-ES")
        XCTAssertEqual(OCRLanguagePreference.visionLanguage(forVoice: "ff_siwis"), "fr-FR")
        XCTAssertEqual(OCRLanguagePreference.visionLanguage(forVoice: "if_sara"), "it-IT")
        XCTAssertEqual(OCRLanguagePreference.visionLanguage(forVoice: "pf_dora"), "pt-BR")
        XCTAssertEqual(OCRLanguagePreference.visionLanguage(forVoice: "zf_xiaoxiao"), "zh-Hans")
        XCTAssertNil(OCRLanguagePreference.visionLanguage(forVoice: "hf_alpha"))
    }

    func test_preferredLanguagesKeepVoiceOrderDeduplicateAndEndWithEnglish() {
        XCTAssertEqual(
            OCRLanguagePreference.preferredLanguages(forVoices: ["ff_siwis", "ff_siwis", "ef_dora"]),
            ["fr-FR", "es-ES", "en-US"]
        )
        XCTAssertEqual(OCRLanguagePreference.preferredLanguages(forVoices: ["af_bella", "am_adam"]), ["en-US"])
        XCTAssertEqual(OCRLanguagePreference.preferredLanguages(forVoices: ["hf_alpha"]), ["en-US"])
        XCTAssertEqual(OCRLanguagePreference.preferredLanguages(forVoices: []), ["en-US"])
    }

    func test_supportedFiltersToAvailableLanguagesInPreferenceOrder() {
        XCTAssertEqual(
            OCRLanguagePreference.supported(["en-GB", "fr-FR", "en-US"], available: ["en-US", "fr-FR", "de-DE"]),
            ["fr-FR", "en-US"]
        )
        XCTAssertEqual(OCRLanguagePreference.supported(["en-US"], available: []), [])
    }
}
