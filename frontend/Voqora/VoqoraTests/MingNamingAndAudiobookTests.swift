import Foundation
@testable import Voqora
import XCTest

@MainActor
final class MingNamingAndAudiobookTests: XCTestCase {
    private var suiteName = ""
    private var defaults = UserDefaults.standard

    override func setUp() {
        super.setUp()
        suiteName = "MingNamingAndAudiobookTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName) ?? .standard
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        LibraryStubURLProtocol.reset()
        super.tearDown()
    }

    private func directory() -> EngineVoiceDirectory {
        EngineVoiceDirectory(defaults: defaults)
    }

    func test_catalogNamesACustomVoiceFromTheEngineList() {
        let engines = [SpeechEngineTests.ming()]

        XCTAssertEqual(SpeechEngineCatalog.displayName(forVoice: "ming:custom:ab12", in: engines), "My Narrator")
        XCTAssertEqual(SpeechEngineCatalog.displayName(forVoice: "ming:US_James", in: engines), "Ming James")
    }

    func test_directoryNamesACustomVoiceWhenTheEngineListIsEmpty() {
        let directory = directory()
        directory.record(SpeechEngineTests.ming().voices)

        XCTAssertEqual(
            SpeechEngineCatalog.displayName(forVoice: "ming:custom:ab12", in: [], directory: directory),
            "My Narrator"
        )
        XCTAssertEqual(SpeechEngineCatalog.displayName(forVoice: "ming:custom:gone", in: [], directory: directory), "Ming custom voice")
    }

    func test_directorySurvivesARelaunch() {
        directory().record(SpeechEngineTests.ming().voices)

        let reloaded = directory()

        XCTAssertEqual(reloaded.summary(for: "ming:CN_Xiaoyu")?.lang, "zh")
        XCTAssertEqual(reloaded.summary(for: "ming:custom:ab12")?.custom, true)
        XCTAssertNil(reloaded.summary(for: "ming:nobody"))
    }

    func test_storeRecordsInstalledVoicesIntoTheDirectory() async {
        let directory = directory()
        let store = SpeechEngineStore(
            service: StaticEngineService(engines: [SpeechEngineTests.ming(), SpeechEngineTests.supertonic(installed: false)]),
            directory: directory
        )

        await store.refresh()

        XCTAssertEqual(directory.summary(for: "ming:custom:ab12")?.name, "My Narrator")
        XCTAssertEqual(store.displayName(forVoice: "ming:custom:ab12"), "My Narrator")
    }

    func test_dashboardNamesAndLanguagesComeFromTheSharedDirectory() {
        let id = "ming:custom:review-\(UUID().uuidString.prefix(8))"
        let zhID = "\(id)-zh"
        EngineVoiceDirectory.shared.record([
            SpeechEngineVoice(id: id, name: "Late Night", gender: "male", lang: "en", custom: true),
            SpeechEngineVoice(id: zhID, name: "灵小安", gender: "female", lang: "zh", custom: true),
        ])

        XCTAssertEqual(DashboardViewModel.voiceName(for: id), "Late Night")
        XCTAssertEqual(DashboardViewModel.voiceName(for: zhID), "灵小安")
        XCTAssertEqual(DashboardViewModel.langCode(forVoice: zhID), "cmn")
        XCTAssertEqual(DashboardViewModel.langCode(forVoice: id), "en-us")
        XCTAssertTrue(DashboardViewModel.sampleSentence(forVoice: zhID).contains("狐狸"))
        XCTAssertEqual(DashboardViewModel.sampleSentence(forVoice: id), "The quick brown fox jumps over the lazy dog.")
    }

    func test_unknownMingVoicesFallBackToEnglish() {
        XCTAssertEqual(DashboardViewModel.langCode(forVoice: "ming:custom:never-seen"), "en-us")
        XCTAssertEqual(EngineVoiceLanguage.appCode(forEngineLanguage: "zh-CN"), "cmn")
        XCTAssertEqual(EngineVoiceLanguage.appCode(forEngineLanguage: "ja"), nil)
    }

    func test_webImportSendsDeliveryObjectOnlyForMingNarrators() async throws {
        LibraryStubURLProtocol.install { _ in .json(200, LibraryFixtures.estimate) }
        let service = LibraryStubURLProtocol.makeService()
        let page = TestLinks.url("https://www.example.com/story")
        let delivery = SpeechDelivery(emotion: .happy, pace: .slow)

        _ = try await service.importWebPage(page, voice: "ming:US_James", speed: 1, engine: "kokoro", delivery: delivery)
        _ = try await service.importWebPage(page, voice: "af_bella", speed: 1, engine: "kokoro", delivery: delivery)
        _ = try await service.importWebPage(page, voice: "ming:US_James", speed: 1, engine: "kokoro", delivery: SpeechDelivery())

        let bodies = try LibraryStubURLProtocol.requests.map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: $0.body) as? [String: Any])
        }
        XCTAssertEqual(bodies[0]["delivery"] as? [String: String], ["emotion": "happy", "pace": "slow"])
        XCTAssertEqual(bodies[0]["engine"] as? String, "ming")
        XCTAssertNil(bodies[1]["delivery"])
        XCTAssertNil(bodies[2]["delivery"])
    }

    func test_uploadSendsDeliveryAsAJSONFormFieldForMingNarrators() async throws {
        LibraryStubURLProtocol.install { _ in .json(200, LibraryFixtures.estimate) }
        let service = LibraryStubURLProtocol.makeService()
        let document = FileManager.default.temporaryDirectory.appendingPathComponent("ming-\(UUID().uuidString).txt")
        try Data("hello".utf8).write(to: document)
        defer { try? FileManager.default.removeItem(at: document) }

        _ = try await service.upload(
            document: document,
            voice: "ming:US_James",
            speed: 1,
            engine: "kokoro",
            delivery: SpeechDelivery(emotion: .sad, style: "Calm")
        )
        _ = try await service.upload(
            document: document,
            voice: "af_bella",
            speed: 1,
            engine: "kokoro",
            delivery: SpeechDelivery(emotion: .sad)
        )

        let forms = LibraryStubURLProtocol.requests.map { String(decoding: $0.body, as: UTF8.self) }
        XCTAssertTrue(forms[0].contains("name=\"delivery\""))
        XCTAssertTrue(forms[0].contains("\"emotion\":\"sad\""))
        XCTAssertTrue(forms[0].contains("\"style\":\"Calm\""))
        XCTAssertFalse(forms[1].contains("name=\"delivery\""))
    }

    func test_storedDeliveryReadsTheSavedSettingsForMingVoicesOnly() {
        defaults.set("happy", forKey: "mingEmotion")
        defaults.set("Warm storyteller", forKey: "mingStyle")
        defaults.set("fast", forKey: "mingPace")
        let store = SpeechEngineStore(service: StaticEngineService(engines: []), directory: directory())

        let delivery = SpeechDelivery.stored(forVoice: "ming:US_James", defaults: defaults, engines: store)

        XCTAssertEqual(delivery, SpeechDelivery(emotion: .happy, style: "Warm storyteller", pace: .fast))
        XCTAssertNil(SpeechDelivery.stored(forVoice: "af_bella", defaults: defaults, engines: store))
    }
}

@MainActor
private final class StaticEngineService: SpeechEngineServing {
    let engines: [SpeechEngine]

    init(engines: [SpeechEngine]) {
        self.engines = engines
    }

    func list() async throws -> [SpeechEngine] {
        engines
    }

    func install(id _: String) async throws -> SpeechEngine {
        throw CancellationError()
    }

    func uninstall(id _: String) async throws -> SpeechEngine {
        throw CancellationError()
    }
}
