import Foundation
@testable import Voqora
import XCTest

@MainActor
private final class FakeSpeechEngineService: SpeechEngineServing {
    var engines: [SpeechEngine]
    var listError: Error?
    var installError: Error?
    var uninstallError: Error?
    var downloadSteps: [Double] = []
    private(set) var installed: [String] = []
    private(set) var uninstalled: [String] = []
    private(set) var listCalls = 0

    init(engines: [SpeechEngine]) {
        self.engines = engines
    }

    func list() async throws -> [SpeechEngine] {
        listCalls += 1
        if let listError {
            throw listError
        }
        advanceDownload()
        return engines
    }

    func install(id: String) async throws -> SpeechEngine {
        if let installError {
            throw installError
        }
        installed.append(id)
        replace(id) { SpeechEngineTests.supertonic(installed: false, downloading: true, progress: 0.05) }
        return try XCTUnwrap(engines.first { $0.id == id })
    }

    func uninstall(id: String) async throws -> SpeechEngine {
        if let uninstallError {
            throw uninstallError
        }
        uninstalled.append(id)
        replace(id) { SpeechEngineTests.supertonic(installed: false, progress: 0) }
        return try XCTUnwrap(engines.first { $0.id == id })
    }

    private func advanceDownload() {
        guard engines.contains(where: \.downloading) else { return }
        if downloadSteps.isEmpty {
            replace("supertonic") { SpeechEngineTests.supertonic() }
        } else {
            let progress = downloadSteps.removeFirst()
            replace("supertonic") { SpeechEngineTests.supertonic(installed: false, downloading: true, progress: progress) }
        }
    }

    private func replace(_ id: String, with make: () -> SpeechEngine) {
        guard let index = engines.firstIndex(where: { $0.id == id }) else { return }
        engines[index] = make()
    }
}

@MainActor
final class SpeechEngineStoreTests: XCTestCase {
    private func makeStore(
        installed: Bool = false,
        service: FakeSpeechEngineService? = nil
    ) -> (SpeechEngineStore, FakeSpeechEngineService) {
        let fake = service ?? FakeSpeechEngineService(engines: [
            SpeechEngineTests.kokoro,
            SpeechEngineTests.supertonic(installed: installed, progress: installed ? 1 : 0),
        ])
        return (SpeechEngineStore(service: fake, pollInterval: .milliseconds(1)), fake)
    }

    func test_refreshLoadsBothEngines() async {
        let (store, _) = makeStore()

        await store.refresh()

        XCTAssertEqual(store.state, .loaded)
        XCTAssertEqual(store.engines.map(\.id), ["kokoro", "supertonic"])
        XCTAssertEqual(store.revision, 1)
        XCTAssertTrue(store.supertonicVoices.isEmpty)
    }

    func test_refreshWithNoChangeDoesNotBumpTheRevision() async {
        let (store, _) = makeStore()

        await store.refresh()
        await store.refresh()

        XCTAssertEqual(store.revision, 1)
    }

    func test_installedSupertonicExposesItsVoices() async {
        let (store, _) = makeStore(installed: true)

        await store.refresh()

        XCTAssertEqual(store.supertonicVoices.map(\.id), ["supertonic:M1", "supertonic:F1"])
        XCTAssertEqual(store.displayName(forVoice: "supertonic:M1"), "Supertonic Male 1")
    }

    func test_failedRefreshReportsTheErrorUntilSomethingLoads() async {
        let (store, fake) = makeStore()
        fake.listError = BackendAPIError.unreachable

        await store.refresh()

        XCTAssertEqual(store.state, .failed(BackendAPIError.unreachable.localizedDescription))
        fake.listError = nil
        await store.refresh()
        XCTAssertEqual(store.state, .loaded)
        fake.listError = BackendAPIError.unreachable
        await store.refresh()
        XCTAssertEqual(store.state, .loaded)
    }

    func test_installPollsUntilTheDownloadFinishes() async {
        let (store, fake) = makeStore()
        fake.downloadSteps = [0.3, 0.7]
        await store.refresh()

        await store.install("supertonic")
        XCTAssertEqual(store.engine(id: "supertonic")?.downloading, true)
        await store.waitForPolling()

        XCTAssertEqual(fake.installed, ["supertonic"])
        let supertonic = store.engine(id: "supertonic")
        XCTAssertEqual(supertonic?.installed, true)
        XCTAssertEqual(supertonic?.downloading, false)
        XCTAssertEqual(store.supertonicVoices.count, 2)
    }

    func test_installFailureSurfacesAMessageAndLeavesTheEngineAlone() async {
        let (store, fake) = makeStore()
        fake.installError = BackendAPIError.rejected(statusCode: 409, message: "Not enough free disk space.")
        await store.refresh()

        await store.install("supertonic")

        XCTAssertEqual(store.actionError, "Not enough free disk space.")
        XCTAssertEqual(store.engine(id: "supertonic")?.installed, false)
        XCTAssertEqual(store.engine(id: "supertonic")?.downloading, false)
    }

    func test_aNewActionClearsThePreviousError() async {
        let (store, fake) = makeStore()
        fake.installError = BackendAPIError.unreachable
        await store.install("supertonic")
        XCTAssertNotNil(store.actionError)

        fake.installError = nil
        await store.install("supertonic")
        store.stopPolling()

        XCTAssertNil(store.actionError)
    }

    func test_uninstallRemovesTheEngineVoices() async {
        let (store, fake) = makeStore(installed: true)
        await store.refresh()

        await store.uninstall("supertonic")

        XCTAssertEqual(fake.uninstalled, ["supertonic"])
        XCTAssertEqual(store.engine(id: "supertonic")?.installed, false)
        XCTAssertTrue(store.supertonicVoices.isEmpty)
    }

    func test_uninstallFailureKeepsTheEngineInstalled() async {
        let (store, fake) = makeStore(installed: true)
        fake.uninstallError = BackendAPIError.rejected(statusCode: 409, message: "Wait for the download to finish.")
        await store.refresh()

        await store.uninstall("supertonic")

        XCTAssertEqual(store.actionError, "Wait for the download to finish.")
        XCTAssertEqual(store.engine(id: "supertonic")?.installed, true)
    }

    func test_resolvedVoiceKeepsEverythingUntilTheListHasLoaded() async {
        let (store, _) = makeStore()

        XCTAssertEqual(store.resolvedVoice("supertonic:M1"), "supertonic:M1")
        await store.refresh()
        XCTAssertEqual(store.resolvedVoice("supertonic:M1"), "af_bella")
        XCTAssertEqual(store.resolvedVoice("af_heart"), "af_heart")
    }

    func test_removingTheEngineMovesTheSelectedVoiceToTheFallback() async {
        let (store, _) = makeStore(installed: true)
        await store.refresh()
        XCTAssertEqual(store.resolvedVoice("supertonic:F1"), "supertonic:F1")

        await store.uninstall("supertonic")

        XCTAssertEqual(store.resolvedVoice("supertonic:F1"), "af_bella")
    }

    func test_installedMingExposesVoicesAndLooksUpOneById() async {
        let fake = FakeSpeechEngineService(engines: [SpeechEngineTests.kokoro, SpeechEngineTests.ming()])
        let store = SpeechEngineStore(service: fake, pollInterval: .milliseconds(1))
        await store.refresh()

        XCTAssertEqual(store.mingVoices.map(\.id), ["ming:US_James", "ming:CN_Xiaoyu", "ming:custom:ab12"])
        XCTAssertEqual(store.voice(id: "ming:CN_Xiaoyu")?.lang, "zh")
        XCTAssertNil(store.voice(id: "af_bella"))
        XCTAssertEqual(store.displayName(forVoice: "ming:US_James"), "Ming James")
        XCTAssertEqual(store.resolvedVoice("ming:US_James"), "ming:US_James")
        XCTAssertTrue(store.supertonicVoices.isEmpty)
    }

    func test_anUninstalledMingHidesItsVoicesAndResolvesToTheFallback() async {
        let fake = FakeSpeechEngineService(engines: [SpeechEngineTests.kokoro, SpeechEngineTests.ming(installed: false)])
        let store = SpeechEngineStore(service: fake, pollInterval: .milliseconds(1))
        await store.refresh()

        XCTAssertTrue(store.mingVoices.isEmpty)
        XCTAssertNil(store.voice(id: "ming:US_James"))
        XCTAssertEqual(store.resolvedVoice("ming:US_James"), "af_bella")
    }

    func test_stopPollingEndsTheDownloadWatcher() async {
        let (store, fake) = makeStore()
        fake.downloadSteps = Array(repeating: 0.5, count: 50)
        await store.install("supertonic")

        store.stopPolling()
        await store.waitForPolling()

        XCTAssertEqual(store.engine(id: "supertonic")?.downloading, true)
    }
}
