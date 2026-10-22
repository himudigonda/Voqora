import Foundation
@testable import Voqora
import XCTest

@MainActor
final class VoicesRemakeTests: XCTestCase {
    private func engine(_ id: String, name: String, installed: Bool, voices: [SpeechEngineVoice] = []) -> SpeechEngine {
        SpeechEngine(id: id, name: name, installed: installed, voices: voices)
    }

    func test_avatarInitialsUseUpToTwoWords() {
        XCTAssertEqual(VoiceAvatarStyle.initials("Bella"), "B")
        XCTAssertEqual(VoiceAvatarStyle.initials("late night narrator"), "LN")
        XCTAssertEqual(VoiceAvatarStyle.initials("  "), "")
    }

    func test_avatarHueIsStableAndCaseInsensitive() {
        XCTAssertEqual(VoiceAvatarStyle.hue(for: "Bella"), VoiceAvatarStyle.hue(for: "bella"))
        XCTAssertNotEqual(VoiceAvatarStyle.hue(for: "Bella"), VoiceAvatarStyle.hue(for: "Adam"))
        XCTAssertTrue((0 ..< 1).contains(VoiceAvatarStyle.hue(for: "Anything")))
    }

    func test_catalogGroupsKokoroByLanguageWithEnglishFirst() {
        let sections = VoiceCatalogBuilder.sections(engines: [], filter: .kokoro, query: "")
        XCTAssertEqual(sections.first?.title, "English")
        XCTAssertTrue(sections.map(\.title).contains("Spanish"))
        let english = sections.first?.entries ?? []
        XCTAssertTrue(english.contains { $0.id == "af_bella" && $0.detail == "English (US) · Female" })
        XCTAssertTrue(english.contains { $0.id == "bm_george" && $0.detail == "English (UK) · Male" })
    }

    func test_catalogFiltersByLanguageAndQuery() {
        let spanish = VoiceCatalogBuilder.sections(engines: [], filter: .kokoro, language: "Spanish", query: "")
        XCTAssertEqual(spanish.map(\.title), ["Spanish"])
        let searched = VoiceCatalogBuilder.sections(engines: [], filter: .all, query: "fenrir")
        XCTAssertEqual(searched.flatMap(\.entries).map(\.id), ["am_fenrir"])
        XCTAssertTrue(VoiceCatalogBuilder.sections(engines: [], filter: .all, query: "zzzz").isEmpty)
    }

    func test_catalogShowsInstalledEngineVoicesButNotCustomOnes() {
        let built = SpeechEngineVoice(id: "ming:en-1", name: "Aria", gender: "female", lang: "en")
        let custom = SpeechEngineVoice(id: "ming:custom:ab", name: "Mine", gender: "unknown", lang: "en", custom: true)
        let engines = [engine("ming", name: "Ming", installed: true, voices: [built, custom])]
        let entries = VoiceCatalogBuilder.sections(engines: engines, filter: .ming, query: "").flatMap(\.entries)
        XCTAssertEqual(entries.map(\.id), ["ming:en-1"])
        XCTAssertEqual(entries.first?.engineName, "Ming")
        XCTAssertTrue(entries.first?.detail.hasSuffix("Female") ?? false)
    }

    func test_catalogHidesVoicesOfEnginesThatAreNotInstalledAndOffersInstall() {
        let voice = SpeechEngineVoice(id: "supertonic:F1", name: "F1", gender: "female", lang: "en")
        let engines = [engine("supertonic", name: "Supertonic", installed: false, voices: [voice])]
        XCTAssertTrue(VoiceCatalogBuilder.sections(engines: engines, filter: .supertonic, query: "").isEmpty)
        XCTAssertEqual(VoiceCatalogBuilder.installableEngines(engines: engines, filter: .all).map(\.id), ["supertonic"])
        XCTAssertTrue(VoiceCatalogBuilder.installableEngines(engines: engines, filter: .ming).isEmpty)
    }

    func test_catalogLanguagesFollowTheEngineFilter() {
        let all = VoiceCatalogBuilder.languages(engines: [], filter: .all)
        XCTAssertEqual(all.first, "English")
        XCTAssertTrue(all.contains("Hindi"))
        XCTAssertTrue(VoiceCatalogBuilder.languages(engines: [], filter: .ming).isEmpty)
    }

    func test_kokoroGenderComesFromTheVoicePrefix() {
        XCTAssertEqual(VoiceCatalogBuilder.gender(forKokoroVoice: "af_bella"), "Female")
        XCTAssertEqual(VoiceCatalogBuilder.gender(forKokoroVoice: "am_adam"), "Male")
        XCTAssertEqual(VoiceCatalogBuilder.gender(forKokoroVoice: "x"), "")
    }

    func test_myVoicesTellsDesignedFromClonedByDescription() {
        let designed = SpeechEngineVoice(id: "ming:custom:1", name: "Warm", gender: "", lang: "en", description: " A warm baritone ", custom: true)
        let cloned = SpeechEngineVoice(id: "ming:custom:2", name: "Me", gender: "", lang: "en", description: "", custom: true)
        XCTAssertEqual(MyVoiceItems.kind(of: designed), .designed)
        XCTAssertEqual(MyVoiceItems.supporting(for: designed), "A warm baritone")
        XCTAssertEqual(MyVoiceItems.kind(of: cloned), .cloned)
        XCTAssertEqual(MyVoiceItems.supporting(for: cloned), "Cloned · \(MingVoiceLanguage.label("en"))")
    }

    func test_myVoicesListsBlendsBeforeMingVoicesAndSkipsBuiltIns() {
        let blend = VoiceBlend(
            id: "blend:6f1c2b9e-1a2b-4c3d-8e9f-0a1b2c3d4e5f",
            name: "Duo",
            lang: "en-us",
            version: 1,
            components: [
                VoiceBlendComponent(voice: "af_bella", weight: 0.5, normalizedWeight: 0.5),
                VoiceBlendComponent(voice: "af_sarah", weight: 0.5, normalizedWeight: 0.5),
            ],
            createdAt: "",
            updatedAt: ""
        )
        let builtIn = SpeechEngineVoice(id: "ming:en-1", name: "Aria", gender: "female", lang: "en")
        let custom = SpeechEngineVoice(id: "ming:custom:1", name: "Warm", gender: "", lang: "en", description: "Warm", custom: true)

        let items = MyVoiceItems.make(blends: [blend], mingVoices: [builtIn, custom])

        XCTAssertEqual(items.map(\.name), ["Duo", "Warm"])
        XCTAssertEqual(items.map(\.kind), [.blend, .designed])
        XCTAssertEqual(items.first?.supporting, "Bella 50% · Sarah 50%")
        XCTAssertEqual(MyVoiceItems.deletionWarning(for: items[0]), "Anything set to Duo switches to Bella, including audiobooks still being narrated.")
        XCTAssertEqual(MyVoiceItems.deletionWarning(for: items[1]), "Anything set to Warm switches to Bella.")
    }

    func test_voicesPagesUseThePlainNames() {
        XCTAssertEqual(VoicesPage.catalog.title, "Browse Voices")
        XCTAssertEqual(VoicesPage.myVoices.title, "My Voices")
        XCTAssertEqual(VoicesPage.allCases.map(\.drawerTitle), ["Browse Voices", "My Voices", "Pronunciations"])
    }

    func test_dictationAccessGapsListOnlyWhatIsMissing() {
        XCTAssertTrue(DictationAccessGaps.make(microphone: .granted, speechRecognition: .notDetermined, accessibilityGranted: true).isEmpty)
        let gaps = DictationAccessGaps.make(microphone: .denied, speechRecognition: .denied, accessibilityGranted: false)
        XCTAssertEqual(gaps.map(\.pane), [.microphone, .speechRecognition, .accessibility])
    }

    func test_dictationStateLabelsAndKeycaps() {
        XCTAssertEqual(DictationStateLabel.title(for: .idle, isTidying: false), "Ready")
        XCTAssertEqual(DictationStateLabel.title(for: .listening, isTidying: false), "Listening")
        XCTAssertEqual(DictationStateLabel.title(for: .inserting, isTidying: true), "Tidying…")
        XCTAssertEqual(DictationStateLabel.keycaps(from: "⌘⇧9"), ["⌘", "⇧", "9"])
        XCTAssertTrue(DictationStateLabel.keycaps(from: nil).isEmpty)
    }

    func test_dictationPlaceholderWaitsForTheMicrophoneWhilePreparing() {
        XCTAssertEqual(DictationStateLabel.placeholder(for: .preparing, shortcut: "⌥Space"), "Loading speech recognition. Start speaking when this says Listening.")
        XCTAssertEqual(DictationStateLabel.placeholder(for: .listening, shortcut: "⌥Space"), "Start speaking. Press ⌥Space when you're done.")
        XCTAssertEqual(DictationStateLabel.placeholder(for: .listening, shortcut: "⌥Space", isWarmingUp: true), "Keep talking. The speech model is still loading, so your words will appear in a moment.")
    }
}
