import Foundation
@testable import Voqora
import XCTest

@MainActor
final class SpeechEngineTests: XCTestCase {
    nonisolated static let engineJSON = """
    {"engine":"kokoro","model":"","voices":["af_bella"],"voice_catalog":[],"languages":[],"blends":[],
     "engines":[
       {"id":"kokoro","name":"Kokoro","installed":true,"downloading":false,"progress":1.0,"size_bytes":0,
        "license":"Apache 2.0","languages":["en-us","es"],
        "voices":[{"id":"af_bella","name":"Bella","gender":"female","lang":"en-us"}],"error":null},
       {"id":"supertonic","name":"Supertonic","installed":false,"downloading":true,"progress":0.4203,
        "size_bytes":401291807,"license":"Code MIT, model weights OpenRAIL-M","languages":["en","ko","ja"],
        "voices":[{"id":"supertonic:M1","name":"Male 1","gender":"male","lang":"multi"},
                  {"id":"supertonic:F1","name":"Female 1","gender":"female","lang":"multi"}],
        "error":null}
     ]}
    """

    static func supertonic(installed: Bool = true, downloading: Bool = false, progress: Double = 1, error: String? = nil) -> SpeechEngine {
        SpeechEngine(
            id: SpeechEngineID.supertonic,
            name: "Supertonic",
            installed: installed,
            downloading: downloading,
            progress: progress,
            sizeBytes: 401_291_807,
            license: "Code MIT, model weights OpenRAIL-M",
            languages: ["en", "ko"],
            voices: [
                SpeechEngineVoice(id: "supertonic:M1", name: "Male 1", gender: "male"),
                SpeechEngineVoice(id: "supertonic:F1", name: "Female 1", gender: "female"),
            ],
            error: error
        )
    }

    nonisolated static let mingJSON = """
    {"id":"ming","name":"Ming","installed":true,"downloading":false,"progress":1.0,"size_bytes":8000000000,
     "license":"MIT","languages":["en","zh","ja","ko","de","fr","es"],
     "notice":"Renders slower than real time on most Macs. Best for audiobooks and exports.",
     "capabilities":["emotion","style","pace","pitch","dialect","design","clone","tags"],
     "voices":[
       {"id":"ming:US_James","name":"James","gender":"male","lang":"en","description":"American accent; narration",
        "emotions":["neutral","happy"],"custom":false},
       {"id":"ming:custom:ab12","name":"My Narrator","gender":"female","lang":"zh","custom":true}
     ],"error":null}
    """

    static func ming(installed: Bool = true) -> SpeechEngine {
        SpeechEngine(
            id: SpeechEngineID.ming,
            name: "Ming",
            installed: installed,
            progress: installed ? 1 : 0,
            sizeBytes: 8_000_000_000,
            license: "MIT",
            languages: ["en", "zh"],
            voices: [
                SpeechEngineVoice(id: "ming:US_James", name: "James", gender: "male", lang: "en", emotions: ["neutral", "happy"]),
                SpeechEngineVoice(id: "ming:CN_Xiaoyu", name: "Xiaoyu", gender: "female", lang: "zh"),
                SpeechEngineVoice(id: "ming:custom:ab12", name: "My Narrator", gender: "female", lang: "en", custom: true),
            ],
            notice: "Renders slower than real time on most Macs.",
            capabilities: ["emotion", "style"]
        )
    }

    static let kokoro = SpeechEngine(id: SpeechEngineID.kokoro, name: "Kokoro", installed: true, progress: 1)

    func test_engineListDecodesTheEngineEndpoint() throws {
        let list = try JSONDecoder().decode(SpeechEngineList.self, from: Data(Self.engineJSON.utf8))

        XCTAssertEqual(list.engines.map(\.id), ["kokoro", "supertonic"])
        let supertonic = try XCTUnwrap(list.engines.last)
        XCTAssertFalse(supertonic.installed)
        XCTAssertTrue(supertonic.downloading)
        XCTAssertEqual(supertonic.progress, 0.4203, accuracy: 0.0001)
        XCTAssertEqual(supertonic.sizeBytes, 401_291_807)
        XCTAssertEqual(supertonic.license, "Code MIT, model weights OpenRAIL-M")
        XCTAssertEqual(supertonic.languages, ["en", "ko", "ja"])
        XCTAssertEqual(supertonic.voices.map(\.id), ["supertonic:M1", "supertonic:F1"])
        XCTAssertNil(supertonic.error)
    }

    func test_olderBackendsWithoutAnEnginesKeyDecodeToNoEngines() throws {
        let json = #"{"engine":"kokoro","model":"","voices":[]}"#
        let list = try JSONDecoder().decode(SpeechEngineList.self, from: Data(json.utf8))

        XCTAssertTrue(list.engines.isEmpty)
    }

    func test_aMalformedEngineIsSkippedWithoutDroppingTheRest() throws {
        let json = #"{"engines":[{"id":"x"},{"id":"kokoro","name":"Kokoro","installed":true}]}"#
        let list = try JSONDecoder().decode(SpeechEngineList.self, from: Data(json.utf8))

        XCTAssertEqual(list.engines.map(\.id), ["kokoro"])
    }

    func test_missingOptionalFieldsFallBackToDefaults() throws {
        let json = #"{"id":"supertonic","name":"Supertonic","installed":false}"#
        let engine = try JSONDecoder().decode(SpeechEngine.self, from: Data(json.utf8))

        XCTAssertFalse(engine.downloading)
        XCTAssertEqual(engine.progress, 0)
        XCTAssertEqual(engine.sizeBytes, 0)
        XCTAssertNil(engine.sizeDescription)
        XCTAssertTrue(engine.voices.isEmpty)
    }

    func test_progressIsClampedForDisplay() {
        XCTAssertEqual(Self.supertonic(progress: 1.7).clampedProgress, 1)
        XCTAssertEqual(Self.supertonic(progress: -0.2).clampedProgress, 0)
        XCTAssertEqual(SpeechEngineRowText.percent(0.4203), "42%")
        XCTAssertEqual(SpeechEngineRowText.percent(3), "100%")
    }

    func test_onlyKokoroIsBuiltIn() {
        XCTAssertTrue(Self.kokoro.isBuiltIn)
        XCTAssertFalse(Self.supertonic().isBuiltIn)
    }

    func test_voiceIdsAreNamespacedPerEngine() {
        XCTAssertEqual(SpeechEngineID.engine(forVoice: "supertonic:M1"), "supertonic")
        XCTAssertEqual(SpeechEngineID.engine(forVoice: "af_bella"), "kokoro")
        XCTAssertEqual(SpeechEngineID.engine(forVoice: "blend:3f2b8c1e-4d5a-4b6c-9e7f-0a1b2c3d4e5f"), "kokoro")
        XCTAssertFalse(SpeechEngineID.isSupertonicVoice("M1"))
    }

    func test_requestedEngineFollowsASupertonicVoice() {
        XCTAssertEqual(SpeechEngineID.resolvedEngine(voice: "supertonic:F1", requested: "kokoro"), "supertonic")
        XCTAssertEqual(SpeechEngineID.resolvedEngine(voice: "supertonic:F1", requested: nil), "supertonic")
        XCTAssertEqual(SpeechEngineID.resolvedEngine(voice: "af_bella", requested: "kokoro"), "kokoro")
        XCTAssertNil(SpeechEngineID.resolvedEngine(voice: "af_bella", requested: nil))
        XCTAssertEqual(SpeechEngineID.resolvedEngine(voice: nil, requested: "kokoro"), "kokoro")
    }

    func test_installedVoicesAppearOnlyOnceTheEngineIsInstalled() {
        let installed = [Self.kokoro, Self.supertonic()]
        let missing = [Self.kokoro, Self.supertonic(installed: false, progress: 0)]
        let downloading = [Self.kokoro, Self.supertonic(installed: false, downloading: true, progress: 0.5)]

        XCTAssertEqual(SpeechEngineCatalog.installedVoices(for: "supertonic", in: installed).map(\.id), ["supertonic:M1", "supertonic:F1"])
        XCTAssertTrue(SpeechEngineCatalog.installedVoices(for: "supertonic", in: missing).isEmpty)
        XCTAssertTrue(SpeechEngineCatalog.installedVoices(for: "supertonic", in: downloading).isEmpty)
        XCTAssertTrue(SpeechEngineCatalog.installedVoices(for: "supertonic", in: []).isEmpty)
    }

    func test_aSupertonicVoiceFallsBackWhenItsEngineIsGone() {
        let installed = [Self.kokoro, Self.supertonic()]
        let removed = [Self.kokoro, Self.supertonic(installed: false, progress: 0)]

        XCTAssertEqual(SpeechEngineCatalog.resolve(voice: "supertonic:M1", in: installed), "supertonic:M1")
        XCTAssertEqual(SpeechEngineCatalog.resolve(voice: "supertonic:M1", in: removed), "af_bella")
        XCTAssertEqual(SpeechEngineCatalog.resolve(voice: "supertonic:M9", in: installed), "af_bella")
        XCTAssertEqual(SpeechEngineCatalog.resolve(voice: "bf_emma", in: removed), "bf_emma")
        XCTAssertEqual(SpeechEngineCatalog.resolve(voice: "blend:3f2b8c1e-4d5a-4b6c-9e7f-0a1b2c3d4e5f", in: removed), "blend:3f2b8c1e-4d5a-4b6c-9e7f-0a1b2c3d4e5f")
    }

    func test_supertonicVoicesGetReadableNames() {
        XCTAssertNil(SpeechEngineCatalog.displayName(forVoice: "af_bella"))
        XCTAssertEqual(SpeechEngineCatalog.displayName(forVoice: "supertonic:M1"), "Supertonic M1")
        XCTAssertEqual(SpeechEngineCatalog.displayName(forVoice: "supertonic:M1", in: [Self.supertonic()]), "Supertonic Male 1")
        XCTAssertEqual(SpeechEngineCatalog.displayName(forVoice: "supertonic:"), "Supertonic")
        XCTAssertTrue(["Supertonic F2", "Supertonic Female 2"].contains(DashboardViewModel.voiceName(for: "supertonic:F2")))
        XCTAssertEqual(DashboardViewModel.voiceName(for: "af_bella"), "Bella")
    }

    func test_rowTextDescribesEachEngine() {
        let kokoro = SpeechEngine(
            id: "kokoro", name: "Kokoro", installed: true, languages: ["en-us", "es"],
            voices: [SpeechEngineVoice(id: "af_bella", name: "Bella", gender: "female")]
        )

        XCTAssertEqual(SpeechEngineRowText.subtitle(for: kokoro), "Included with Voqora. Fast, with 1 voices in 2 languages.")
        let subtitle = SpeechEngineRowText.subtitle(for: Self.supertonic(installed: false, progress: 0))
        XCTAssertTrue(subtitle.hasPrefix("Optional · "))
        XCTAssertTrue(subtitle.contains("2 languages"))
        XCTAssertTrue(subtitle.contains("2 voices"))
        XCTAssertTrue(subtitle.hasSuffix("Code MIT, model weights OpenRAIL-M"))
        XCTAssertTrue(SpeechEnginesSection.licenseNote.contains("OpenRAIL-M"))
    }

    func test_servicePathsEncodeTheEngineId() {
        XCTAssertEqual(SpeechEngineService.path(for: "supertonic", action: "install"), "engine/supertonic/install")
        XCTAssertEqual(SpeechEngineService.path(for: "supertonic"), "engine/supertonic")
        XCTAssertEqual(SpeechEngineService.path(for: "a/b", action: "install"), "engine/a%2Fb/install")
    }

    func test_speechIsScopedToABookOnlyWhenTheIdIsValid() {
        let bookID = String(repeating: "a", count: 32)

        XCTAssertEqual(BackendService.scopedBookID(bookID), bookID)
        XCTAssertNil(BackendService.scopedBookID(nil))
        XCTAssertNil(BackendService.scopedBookID("../x"))
        XCTAssertNil(BackendService.scopedBookID("global"))
        XCTAssertNil(BackendService.scopedBookID(String(repeating: "A", count: 32)))
    }

    func test_articleNarrationUsesTheVoicesEngine() {
        XCTAssertEqual(AudiobookNarration(voice: "supertonic:F1", speed: 1).engine, "supertonic")
        XCTAssertEqual(AudiobookNarration(voice: "af_bella", speed: 1).engine, "kokoro")
    }

    func test_languageDetectionLeavesMultilingualSupertonicVoicesAlone() {
        let spanish = "El veloz zorro marrón salta sobre el perro perezoso todos los días."

        XCTAssertEqual(LanguageDetector.voiceForText(spanish, fallback: "supertonic:F1"), "supertonic:F1")
        XCTAssertEqual(LanguageDetector.voiceForText(spanish, fallback: "af_bella"), "ef_dora")
    }

    func test_mingEntryDecodesNoticeCapabilitiesAndVoiceDetails() throws {
        let engine = try JSONDecoder().decode(SpeechEngine.self, from: Data(Self.mingJSON.utf8))

        XCTAssertEqual(engine.id, "ming")
        XCTAssertEqual(engine.license, "MIT")
        XCTAssertEqual(engine.trimmedNotice, "Renders slower than real time on most Macs. Best for audiobooks and exports.")
        XCTAssertTrue(engine.supports("clone"))
        XCTAssertFalse(engine.supports("telepathy"))
        let james = try XCTUnwrap(engine.voices.first)
        XCTAssertEqual(james.lang, "en")
        XCTAssertEqual(james.description, "American accent; narration")
        XCTAssertEqual(james.emotions, ["neutral", "happy"])
        XCTAssertFalse(james.custom)
        XCTAssertEqual(james.mingGroup, .english)
        let custom = try XCTUnwrap(engine.voices.last)
        XCTAssertTrue(custom.custom)
        XCTAssertEqual(custom.mingGroup, .mine)
    }

    func test_mingVoicesWithMissingOptionalFieldsStillDecode() throws {
        let json = #"{"id":"ming","name":"Ming","installed":true,"voices":[{"id":"ming:CN_A","name":"A","lang":"zh"},{"id":"ming:custom:ff","name":"B"}]}"#
        let engine = try JSONDecoder().decode(SpeechEngine.self, from: Data(json.utf8))

        XCTAssertNil(engine.notice)
        XCTAssertNil(engine.trimmedNotice)
        XCTAssertTrue(engine.capabilities.isEmpty)
        let first = try XCTUnwrap(engine.voices.first)
        XCTAssertEqual(first.gender, "")
        XCTAssertNil(first.description)
        XCTAssertTrue(first.emotions.isEmpty)
        XCTAssertFalse(first.custom)
        XCTAssertEqual(first.mingGroup, .chinese)
        XCTAssertTrue(try XCTUnwrap(engine.voices.last).custom)
    }

    func test_blankNoticeIsTreatedAsMissing() {
        let engine = SpeechEngine(id: "ming", name: "Ming", installed: false, notice: "  \n")

        XCTAssertNil(engine.trimmedNotice)
    }

    func test_engineListKeepsAllThreeEngines() throws {
        let json = #"{"engines":[{"id":"kokoro","name":"Kokoro","installed":true},"# + Self.mingJSON + "]}"
        let list = try JSONDecoder().decode(SpeechEngineList.self, from: Data(json.utf8))

        XCTAssertEqual(list.engines.map(\.id), ["kokoro", "ming"])
    }

    func test_mingVoiceIdsResolveToTheMingEngine() {
        XCTAssertEqual(SpeechEngineID.engine(forVoice: "ming:US_James"), "ming")
        XCTAssertEqual(SpeechEngineID.engine(forVoice: "ming:custom:ab12"), "ming")
        XCTAssertEqual(SpeechEngineID.engine(forVoice: "supertonic:M1"), "supertonic")
        XCTAssertTrue(SpeechEngineID.isMingVoice("ming:US_James"))
        XCTAssertFalse(SpeechEngineID.isMingVoice("mingle"))
        XCTAssertTrue(SpeechEngineID.isCustomMingVoice("ming:custom:ab12"))
        XCTAssertFalse(SpeechEngineID.isCustomMingVoice("ming:US_James"))
        XCTAssertEqual(SpeechEngineID.resolvedEngine(voice: "ming:US_James", requested: "kokoro"), "ming")
        XCTAssertEqual(SpeechEngineID.resolvedEngine(voice: "supertonic:F1", requested: "ming"), "supertonic")
        XCTAssertNil(SpeechEngineID.resolvedEngine(voice: "af_bella", requested: "ming"))
        XCTAssertNil(SpeechEngineID.resolvedEngine(voice: "blend:calm", requested: "supertonic"))
        XCTAssertEqual(AudiobookNarration(voice: "ming:US_James", speed: 1).engine, "ming")
    }

    func test_mingAvailabilityFollowsInstallState() {
        let installed = [Self.kokoro, Self.ming()]
        let removed = [Self.kokoro, Self.ming(installed: false)]

        XCTAssertTrue(SpeechEngineCatalog.isAvailable(voice: "ming:US_James", in: installed))
        XCTAssertTrue(SpeechEngineCatalog.isAvailable(voice: "ming:custom:ab12", in: installed))
        XCTAssertFalse(SpeechEngineCatalog.isAvailable(voice: "ming:US_Nobody", in: installed))
        XCTAssertFalse(SpeechEngineCatalog.isAvailable(voice: "ming:US_James", in: removed))
        XCTAssertEqual(SpeechEngineCatalog.resolve(voice: "ming:US_James", in: removed), "af_bella")
        XCTAssertEqual(SpeechEngineCatalog.resolve(voice: "ming:US_James", in: installed), "ming:US_James")
        XCTAssertEqual(SpeechEngineCatalog.resolve(voice: "supertonic:M1", in: installed), "af_bella")
        XCTAssertEqual(SpeechEngineCatalog.voice("ming:CN_Xiaoyu", in: installed)?.name, "Xiaoyu")
        XCTAssertNil(SpeechEngineCatalog.voice("ming:CN_Xiaoyu", in: removed))
    }

    func test_mingVoicesGetReadableNames() {
        let engines = [Self.ming()]

        XCTAssertEqual(SpeechEngineCatalog.displayName(forVoice: "ming:US_James", in: engines), "Ming James")
        XCTAssertEqual(SpeechEngineCatalog.displayName(forVoice: "ming:custom:ab12", in: engines), "My Narrator")
        XCTAssertEqual(SpeechEngineCatalog.displayName(forVoice: "ming:US_James"), "Ming James")
        XCTAssertEqual(SpeechEngineCatalog.displayName(forVoice: "ming:custom:zz"), "Ming custom voice")
        XCTAssertEqual(SpeechEngineCatalog.displayName(forVoice: "ming:"), "Ming")
        XCTAssertEqual(DashboardViewModel.voiceName(for: "ming:US_James"), "Ming James")
    }

    func test_languageDetectionLeavesMingVoicesAlone() {
        let spanish = "El veloz zorro marrón salta sobre el perro perezoso todos los días."

        XCTAssertEqual(LanguageDetector.voiceForText(spanish, fallback: "ming:US_James"), "ming:US_James")
    }
}
