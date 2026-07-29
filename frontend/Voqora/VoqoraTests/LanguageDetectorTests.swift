@testable import Voqora
import XCTest

/// Tests for auto language detection → voice selection (LanguageDetector) and the
/// DashboardViewModel language-code helpers that back it. NLLanguageRecognizer
/// runs fully on-device, so these execute in the unit-test target without network.
final class LanguageDetectorTests: XCTestCase {
    // MARK: - DashboardViewModel language-code helpers

    func test_langCode_matches_backend_prefix_map() {
        XCTAssertEqual(DashboardViewModel.langCode(forVoice: "af_bella"), "en-us")
        XCTAssertEqual(DashboardViewModel.langCode(forVoice: "bm_george"), "en-gb")
        XCTAssertEqual(DashboardViewModel.langCode(forVoice: "ef_dora"), "es")
        XCTAssertEqual(DashboardViewModel.langCode(forVoice: "ff_siwis"), "fr-fr")
        XCTAssertEqual(DashboardViewModel.langCode(forVoice: "if_sara"), "it")
        XCTAssertEqual(DashboardViewModel.langCode(forVoice: "pf_dora"), "pt-br")
        XCTAssertEqual(DashboardViewModel.langCode(forVoice: "hf_alpha"), "hi")
        XCTAssertEqual(DashboardViewModel.langCode(forVoice: "zf_xiaoxiao"), "cmn")
    }

    func test_langCode_unknown_defaults_to_en_us() {
        XCTAssertEqual(DashboardViewModel.langCode(forVoice: "qx_nope"), "en-us")
        XCTAssertEqual(DashboardViewModel.langCode(forVoice: ""), "en-us")
    }

    func test_defaultVoice_forLang_returns_first_catalog_voice() {
        XCTAssertEqual(DashboardViewModel.defaultVoice(forLang: "es"), "ef_dora")
        XCTAssertEqual(DashboardViewModel.defaultVoice(forLang: "fr-fr"), "ff_siwis")
        XCTAssertEqual(DashboardViewModel.defaultVoice(forLang: "hi"), "hf_alpha")
        XCTAssertEqual(DashboardViewModel.defaultVoice(forLang: "cmn"), "zf_xiaoxiao")
        XCTAssertEqual(DashboardViewModel.defaultVoice(forLang: "en-us"), "af_bella")
        XCTAssertNil(DashboardViewModel.defaultVoice(forLang: "ja")) // unsupported
    }

    // MARK: - voiceForText routing

    func test_spanish_text_routes_to_spanish_voice() {
        let v = LanguageDetector.voiceForText(
            "Hola, bienvenido a Voqora. Esta aplicación funciona en tu Mac sin conexión.",
            fallback: "af_bella"
        )
        XCTAssertEqual(DashboardViewModel.langCode(forVoice: v), "es", "got \(v)")
    }

    func test_french_text_routes_to_french_voice() {
        let v = LanguageDetector.voiceForText(
            "Bonjour et bienvenue dans Voqora. Cette application fonctionne sur votre Mac.",
            fallback: "af_bella"
        )
        XCTAssertEqual(DashboardViewModel.langCode(forVoice: v), "fr-fr", "got \(v)")
    }

    func test_hindi_text_routes_to_hindi_voice() {
        let v = LanguageDetector.voiceForText(
            "नमस्ते और सुपरसे में आपका स्वागत है। यह आपके मैक पर ऑफ़लाइन काम करता है।",
            fallback: "af_bella"
        )
        XCTAssertEqual(DashboardViewModel.langCode(forVoice: v), "hi", "got \(v)")
    }

    func test_english_text_keeps_user_voice() {
        // English text must NOT switch the user's chosen English voice.
        let v = LanguageDetector.voiceForText(
            "Welcome to Voqora, the fastest on-device text to speech for your Mac.",
            fallback: "am_michael"
        )
        XCTAssertEqual(v, "am_michael")
    }

    func test_english_text_does_not_switch_uk_to_us() {
        // British voice + English text → keep British (no en-gb ⇄ en-us flip-flop).
        let v = LanguageDetector.voiceForText(
            "Good afternoon, this is a thoroughly British sentence about the weather.",
            fallback: "bf_emma"
        )
        XCTAssertEqual(v, "bf_emma")
    }

    func test_unsupported_language_falls_back() {
        // Japanese is unsupported → keep the user's voice (no mispronunciation attempt).
        let v = LanguageDetector.voiceForText(
            "こんにちは、これはテストです。今日はいい天気ですね。",
            fallback: "af_bella"
        )
        XCTAssertEqual(v, "af_bella")
    }

    func test_too_short_text_falls_back() {
        XCTAssertEqual(LanguageDetector.voiceForText("Hi", fallback: "af_bella"), "af_bella")
        XCTAssertEqual(LanguageDetector.voiceForText("", fallback: "ff_siwis"), "ff_siwis")
    }

    func test_returned_voice_is_always_a_valid_catalog_voice() {
        let ids = Set(DashboardViewModel.voiceCatalog.map(\.id))
        for text in ["Hola mundo cómo estás hoy", "Bonjour tout le monde",
                     "This is english text here", "xyz123"]
        {
            let v = LanguageDetector.voiceForText(text, fallback: "af_bella")
            XCTAssertTrue(ids.contains(v), "\(v) not in catalog")
        }
    }
}
