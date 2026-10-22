@testable import Voqora
import XCTest

final class VoicePickerCatalogTests: XCTestCase {
    private let engines = [
        SpeechEngine(
            id: SpeechEngineID.ming, name: "Ming", installed: true,
            voices: [
                SpeechEngineVoice(id: "ming:US_James", name: "James", gender: "male", lang: "en"),
                SpeechEngineVoice(id: "ming:custom:abc", name: "Studio Me", gender: "", lang: "en", custom: true),
            ]
        ),
        SpeechEngine(
            id: SpeechEngineID.supertonic, name: "Supertonic", installed: true,
            voices: [SpeechEngineVoice(id: "supertonic:F1", name: "F1", gender: "female", lang: "en")]
        ),
    ]

    private func blend(_ name: String, lang: String) -> VoiceBlend {
        VoiceBlend(
            id: "blend:\(UUID().uuidString.lowercased())", name: name, lang: lang, version: 1,
            components: [], createdAt: "", updatedAt: ""
        )
    }

    private func ids(_ sections: [VoicePickerSection]) -> [String] {
        sections.flatMap(\.entries).map(\.id)
    }

    func test_everythingScopeListsBlendsKokoroSupertonicAndMing() {
        let mine = blend("Warm", lang: "en-us")

        let sections = VoicePickerCatalog.sections(blends: [mine], engines: engines, query: "", scope: .everything)

        XCTAssertEqual(sections.first?.title, "My Voices")
        let all = ids(sections)
        XCTAssertTrue(all.contains(mine.id))
        XCTAssertTrue(all.contains("af_bella"))
        XCTAssertTrue(all.contains("supertonic:F1"))
        XCTAssertTrue(all.contains("ming:US_James"))
        XCTAssertTrue(sections.contains { $0.title == "Ming · My voices" })
    }

    func test_podcastScopeIsKokoroAndBlendsInTheChosenLanguage() {
        let english = blend("Warm", lang: "en-us")
        let french = blend("Chic", lang: "fr-fr")

        let sections = VoicePickerCatalog.sections(blends: [english, french], engines: engines, query: "", scope: .podcast(.french))
        let all = ids(sections)

        XCTAssertTrue(all.contains("ff_siwis"))
        XCTAssertTrue(all.contains(french.id))
        XCTAssertFalse(all.contains(english.id))
        XCTAssertFalse(all.contains("af_bella"))
        XCTAssertFalse(all.contains { SpeechEngineID.isDownloadableEngineVoice($0) })
    }

    func test_podcastScopeWithoutLanguageKeepsEveryKokoroVoice() {
        let all = ids(VoicePickerCatalog.sections(blends: [], engines: engines, query: "", scope: .podcast(nil)))

        XCTAssertEqual(Set(all), Set(DashboardViewModel.voiceCatalog.map(\.id)))
    }

    func test_queryMatchesNameEngineAndGroup() {
        let byName = VoicePickerCatalog.sections(blends: [], engines: engines, query: "adam", scope: .everything)
        XCTAssertEqual(ids(byName), ["am_adam"])

        let byEngine = VoicePickerCatalog.sections(blends: [], engines: engines, query: "supertonic", scope: .everything)
        XCTAssertEqual(ids(byEngine), ["supertonic:F1"])

        XCTAssertTrue(VoicePickerCatalog.sections(blends: [], engines: engines, query: "zzzz", scope: .everything).isEmpty)
    }

    func test_descriptorNamesTheEngineAndLanguage() {
        let kokoro = VoicePickerCatalog.descriptor(forVoice: "af_bella", blends: [])
        XCTAssertEqual(kokoro.name, "Bella")
        XCTAssertEqual(kokoro.engineName, "Kokoro")
        XCTAssertEqual(kokoro.languageLabel, "English (US)")

        XCTAssertEqual(VoicePickerCatalog.descriptor(forVoice: "ming:US_James", blends: []).engineName, "Ming")
        XCTAssertEqual(VoicePickerCatalog.descriptor(forVoice: "supertonic:F1", blends: []).engineName, "Supertonic")

        let mine = blend("Warm", lang: "en-us")
        let blendDescriptor = VoicePickerCatalog.descriptor(forVoice: mine.id, blends: [mine])
        XCTAssertEqual(blendDescriptor.name, "Warm")
        XCTAssertEqual(blendDescriptor.engineName, "Blend")
        XCTAssertEqual(blendDescriptor.languageLabel, "English (US)")
    }
}
