import Foundation
@testable import Voqora
import XCTest

@MainActor
private final class FakeBlendService: VoiceBlendServing {
    var blends: [VoiceBlend] = []
    var maxBlends = 50
    var listError: Error?
    var saveError: Error?
    var deleteError: Error?
    private(set) var created: [VoiceBlendRequest] = []
    private(set) var deletedIDs: [String] = []

    func list() async throws -> VoiceBlendList {
        if let listError {
            throw listError
        }
        return try JSONDecoder().decode(VoiceBlendList.self, from: Self.listJSON(blends, max: maxBlends))
    }

    func create(_ request: VoiceBlendRequest) async throws -> VoiceBlend {
        if let saveError {
            throw saveError
        }
        created.append(request)
        let blend = VoiceBlendStoreTests.makeBlend(id: VoiceBlendStoreTests.secondID, name: request.name, voices: request.components.map(\.voice))
        blends.append(blend)
        return blend
    }

    func update(id: String, with request: VoiceBlendRequest) async throws -> VoiceBlend {
        if let saveError {
            throw saveError
        }
        return VoiceBlendStoreTests.makeBlend(id: id, name: request.name, voices: request.components.map(\.voice))
    }

    func delete(id: String) async throws {
        if let deleteError {
            throw deleteError
        }
        deletedIDs.append(id)
        blends.removeAll { $0.id == id }
    }

    private static func listJSON(_ blends: [VoiceBlend], max: Int) throws -> Data {
        let encoded = try JSONEncoder().encode(blends)
        let array = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [Any])
        return try JSONSerialization.data(withJSONObject: ["blends": array, "max_blends": max])
    }
}

@MainActor
final class VoiceBlendStoreTests: XCTestCase {
    nonisolated static let firstID = "blend:11111111-1111-4111-8111-111111111111"
    nonisolated static let secondID = "blend:22222222-2222-4222-8222-222222222222"

    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "VoiceBlendStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    static func makeBlend(id: String, name: String, voices: [String]) -> VoiceBlend {
        let share = 1.0 / Double(max(voices.count, 1))
        return VoiceBlend(
            id: id,
            name: name,
            lang: "en-us",
            version: 1,
            components: voices.map { VoiceBlendComponent(voice: $0, weight: 0.5, normalizedWeight: share) },
            createdAt: "2026-10-01T10:00:00Z",
            updatedAt: "2026-10-01T10:00:00Z"
        )
    }

    private func makeStore(_ service: FakeBlendService) -> VoiceBlendStore {
        VoiceBlendStore(service: service, directory: VoiceBlendDirectory(defaults: defaults))
    }

    func test_refreshLoadsBlendsAndRecordsFallbacks() async {
        let service = FakeBlendService()
        service.blends = [Self.makeBlend(id: Self.firstID, name: "Duo", voices: ["bm_george", "af_bella"])]
        let store = makeStore(service)

        await store.refresh()

        XCTAssertEqual(store.state, .loaded)
        XCTAssertEqual(store.blends.map(\.name), ["Duo"])
        XCTAssertEqual(store.revision, 1)
        XCTAssertEqual(store.directory.fallbackVoice(for: Self.firstID), "bm_george")
        XCTAssertEqual(store.displayName(for: Self.firstID), "Duo")
    }

    func test_refreshFailureShowsTheErrorUntilLoaded() async {
        let service = FakeBlendService()
        service.listError = BackendAPIError.unreachable
        let store = makeStore(service)

        await store.refresh()

        XCTAssertEqual(store.state, .failed(BackendAPIError.unreachable.localizedDescription))
        XCTAssertEqual(store.resolvedVoice(Self.firstID), Self.firstID)
    }

    func test_saveRejectsInvalidDraftsWithoutCallingTheEngine() async {
        let service = FakeBlendService()
        let store = makeStore(service)

        do {
            try await store.save(VoiceBlendDraft(), editing: nil)
            XCTFail("An unnamed blend must not be saved")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Give your voice a name.")
        }
        XCTAssertTrue(service.created.isEmpty)
    }

    func test_saveAppendsNewBlendsAndReplacesEditedOnes() async throws {
        let service = FakeBlendService()
        service.blends = [Self.makeBlend(id: Self.firstID, name: "Duo", voices: ["af_bella", "am_adam"])]
        let store = makeStore(service)
        await store.refresh()

        try await store.save(VoiceBlendDraft(name: "Trio"), editing: nil)
        try await store.save(VoiceBlendDraft(name: "Renamed"), editing: Self.firstID)

        XCTAssertEqual(store.blends.map(\.name), ["Renamed", "Trio"])
        XCTAssertEqual(service.created.map(\.name), ["Trio"])
        XCTAssertEqual(store.directory.name(for: Self.firstID), "Renamed")
    }

    func test_saveRespectsTheBlendLimit() async {
        let service = FakeBlendService()
        service.maxBlends = 1
        service.blends = [Self.makeBlend(id: Self.firstID, name: "Duo", voices: ["af_bella", "am_adam"])]
        let store = makeStore(service)
        await store.refresh()

        do {
            try await store.save(VoiceBlendDraft(name: "Second"), editing: nil)
            XCTFail("The limit must be enforced")
        } catch {
            XCTAssertEqual(error.localizedDescription, "You can save up to 1 custom voices.")
        }
    }

    func test_deletingASelectedBlendFallsBackToItsFirstVoice() async throws {
        let service = FakeBlendService()
        let blend = Self.makeBlend(id: Self.firstID, name: "Duo", voices: ["bm_george", "af_bella"])
        service.blends = [blend]
        let store = makeStore(service)
        await store.refresh()
        XCTAssertEqual(store.resolvedVoice(Self.firstID), Self.firstID)

        try await store.delete(blend)

        XCTAssertEqual(service.deletedIDs, [Self.firstID])
        XCTAssertTrue(store.blends.isEmpty)
        XCTAssertEqual(store.resolvedVoice(Self.firstID), "bm_george")
        XCTAssertEqual(store.resolvedVoice("af_sarah"), "af_sarah")
    }

    func test_alreadyDeletedBlendIsTreatedAsDeleted() async throws {
        let service = FakeBlendService()
        let blend = Self.makeBlend(id: Self.firstID, name: "Duo", voices: ["af_bella", "am_adam"])
        service.blends = [blend]
        service.deleteError = BackendAPIError.rejected(statusCode: 404, message: "Voice blend not found.")
        let store = makeStore(service)
        await store.refresh()

        try await store.delete(blend)

        XCTAssertTrue(store.blends.isEmpty)
    }

    func test_otherDeleteFailuresKeepTheBlend() async {
        let service = FakeBlendService()
        let blend = Self.makeBlend(id: Self.firstID, name: "Duo", voices: ["af_bella", "am_adam"])
        service.blends = [blend]
        service.deleteError = BackendAPIError.unreachable
        let store = makeStore(service)
        await store.refresh()

        do {
            try await store.delete(blend)
            XCTFail("Expected the delete to fail")
        } catch {
            XCTAssertEqual(error as? BackendAPIError, .unreachable)
        }
        XCTAssertEqual(store.blends.count, 1)
    }

    func test_unknownBlendWithoutHistoryFallsBackToBella() async {
        let store = makeStore(FakeBlendService())
        await store.refresh()

        XCTAssertEqual(store.resolvedVoice(Self.secondID), "af_bella")
    }

    func test_directoryPersistsAndDropsCorruptEntries() throws {
        let directory = VoiceBlendDirectory(defaults: defaults)
        directory.record([Self.makeBlend(id: Self.firstID, name: "Duo", voices: ["hf_alpha", "af_bella"])])

        let reloaded = VoiceBlendDirectory(defaults: defaults)
        XCTAssertEqual(reloaded.summary(for: Self.firstID), .init(name: "Duo", fallbackVoice: "hf_alpha"))

        let corrupt = try JSONEncoder().encode([
            "not-a-blend": VoiceBlendDirectory.Summary(name: "X", fallbackVoice: "af_bella"),
            Self.secondID: VoiceBlendDirectory.Summary(name: "Loop", fallbackVoice: Self.firstID),
        ])
        defaults.set(corrupt, forKey: VoiceBlendDirectory.defaultsKey)
        let filtered = VoiceBlendDirectory(defaults: defaults)
        XCTAssertNil(filtered.summary(for: "not-a-blend"))
        XCTAssertNil(filtered.summary(for: Self.secondID))
    }

    func test_voiceDefaultsMigrationKeepsBlendSelections() throws {
        let suite = "VoiceBlendStoreTests.migration.\(UUID().uuidString)"
        let migrationDefaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { migrationDefaults.removePersistentDomain(forName: suite) }
        migrationDefaults.set(7, forKey: "voiceDefaultsMigrationVersion")
        migrationDefaults.set(Self.firstID, forKey: "selectedVoice")
        migrationDefaults.set(Self.secondID, forKey: "defaultBookVoice")

        XCTAssertFalse(DashboardViewModel.applyVoiceDefaultsMigrationIfNeeded(defaults: migrationDefaults))
        XCTAssertEqual(migrationDefaults.string(forKey: "selectedVoice"), Self.firstID)
        XCTAssertEqual(migrationDefaults.string(forKey: "defaultBookVoice"), Self.secondID)
    }

    func test_unknownBlendSpeaksEnglishAndHasAFriendlyName() {
        let unknown = "blend:99999999-9999-4999-8999-999999999999"

        XCTAssertEqual(DashboardViewModel.langCode(forVoice: unknown), "en-us")
        XCTAssertEqual(DashboardViewModel.voiceName(for: unknown), "Custom Voice")
    }

    func test_deletedBlendSpeechFailureExplainsWhatHappened() {
        let message = DashboardViewModel.speechFailureMessage(
            for: BackendService.StreamError.rejectedResponse(statusCode: 422),
            voice: Self.firstID
        )

        XCTAssertEqual(message, "That custom voice is no longer available. Choose another voice in Voices.")
        XCTAssertTrue(DashboardViewModel.isMissingBlendFailure(BackendService.StreamError.rejectedResponse(statusCode: 422), voice: Self.firstID))
        XCTAssertFalse(DashboardViewModel.isMissingBlendFailure(BackendService.StreamError.rejectedResponse(statusCode: 503), voice: Self.firstID))
        XCTAssertEqual(
            DashboardViewModel.speechFailureMessage(for: BackendService.StreamError.rejectedResponse(statusCode: 422), voice: "af_bella"),
            "That selection is empty or too long. Try a shorter passage."
        )
    }

    func test_voicesPagesMapToSidebarTabs() {
        XCTAssertEqual(VoicesPage.allCases.map(\.tab), ["voices", "voices.catalog", "voices.pronunciations"])
        XCTAssertEqual(VoicesPage(tab: "voices.catalog"), .catalog)
        XCTAssertNil(VoicesPage(tab: "home"))
    }
}
