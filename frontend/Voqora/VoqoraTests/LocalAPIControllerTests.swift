import Combine
import Foundation
@testable import Voqora
import XCTest

@MainActor
private final class FakeLocalAPIBackend: LocalAPIBackend {
    var nextResult: Result<LocalAPIStatus, Error> = .success(LocalAPIStatus(enabled: true, port: 51851, running: true, errorCode: nil))
    var statusResult: Result<LocalAPIStatus, Error> = .success(LocalAPIStatus(enabled: true, port: 51851, running: true, errorCode: nil))
    private(set) var applied: [LocalAPIConfiguration] = []

    func status() async throws -> LocalAPIStatus {
        try statusResult.get()
    }

    func apply(_ configuration: LocalAPIConfiguration) async throws -> LocalAPIStatus {
        applied.append(configuration)
        return try nextResult.get()
    }

    func events() -> AsyncThrowingStream<IntegrationEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

@MainActor
private final class RelaySpy: SpeechRelayControlling {
    private(set) var isRunning = false
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start() {
        startCount += 1
        isRunning = true
    }

    func stop() {
        stopCount += 1
        isRunning = false
    }
}

@MainActor
final class LocalAPIControllerTests: XCTestCase {
    private nonisolated static let fixedKey = "vq_" + String(repeating: "A", count: 43)

    private var testDefaults: TestDefaults!
    private var secrets: MemorySecretStore!
    private var backend: FakeLocalAPIBackend!
    private var relay: RelaySpy!

    override func setUp() {
        super.setUp()
        testDefaults = TestDefaults()
        secrets = MemorySecretStore()
        backend = FakeLocalAPIBackend()
        relay = RelaySpy()
    }

    override func tearDown() {
        testDefaults.tearDown()
        super.tearDown()
    }

    private func makeController(key: String? = LocalAPIControllerTests.fixedKey) -> LocalAPIController {
        let controller = LocalAPIController(
            backend: backend,
            secrets: secrets.store,
            defaults: testDefaults.defaults,
            generateKey: { key }
        )
        controller.attachRelay(relay)
        return controller
    }

    private func settle(_ controller: LocalAPIController) async {
        await yieldUntil { !controller.isApplying }
    }

    func test_defaultsAreOffWithTheDefaultPort() {
        let controller = makeController()

        XCTAssertFalse(controller.isEnabled)
        XCTAssertEqual(controller.port, 51851)
        XCTAssertEqual(controller.portText, "51851")
        XCTAssertEqual(controller.phase, .off)
        XCTAssertTrue(controller.apiKey.isEmpty)
    }

    func test_enablingCreatesAKeyStartsTheServerAndTheRelay() async {
        let controller = makeController()
        controller.engineAvailabilityChanged(true)

        controller.setEnabled(true)
        XCTAssertEqual(controller.phase, .starting)
        await settle(controller)

        XCTAssertEqual(secrets.value(for: .localAPIKey), Self.fixedKey)
        XCTAssertEqual(controller.apiKey, Self.fixedKey)
        XCTAssertEqual(backend.applied, [.enabled(port: 51851, apiKey: Self.fixedKey)])
        XCTAssertEqual(controller.phase, .running(port: 51851))
        XCTAssertTrue(relay.isRunning)
        XCTAssertTrue(testDefaults.defaults.bool(forKey: LocalAPIController.enabledKey))
    }

    func test_enablingWhileTheEngineIsStartingWaitsAndAppliesOnLaunch() async {
        let controller = makeController()

        controller.setEnabled(true)
        XCTAssertEqual(controller.phase, .waitingForEngine)
        XCTAssertTrue(backend.applied.isEmpty)

        controller.engineAvailabilityChanged(true)
        await settle(controller)

        XCTAssertEqual(backend.applied.count, 1)
        XCTAssertTrue(relay.isRunning)
    }

    func test_savedSettingsAreAppliedWhenTheEngineComesOnline() async {
        testDefaults.defaults.set(true, forKey: LocalAPIController.enabledKey)
        testDefaults.defaults.set(6000, forKey: LocalAPIController.portKey)
        secrets.seed(Self.fixedKey, for: .localAPIKey)
        let controller = makeController()
        let online = PassthroughSubject<Bool, Never>()
        controller.observeEngine(online.eraseToAnyPublisher())

        online.send(true)
        await settle(controller)

        XCTAssertEqual(backend.applied, [.enabled(port: 6000, apiKey: Self.fixedKey)])
    }

    func test_engineGoingOfflineStopsTheRelayAndReappliesOnReturn() async {
        secrets.seed(Self.fixedKey, for: .localAPIKey)
        testDefaults.defaults.set(true, forKey: LocalAPIController.enabledKey)
        let controller = makeController()
        controller.engineAvailabilityChanged(true)
        await settle(controller)

        controller.engineAvailabilityChanged(false)
        XCTAssertFalse(relay.isRunning)
        XCTAssertEqual(controller.phase, .waitingForEngine)

        controller.engineAvailabilityChanged(true)
        await settle(controller)
        XCTAssertEqual(backend.applied.count, 2)
        XCTAssertTrue(relay.isRunning)
    }

    func test_portConflictShowsAClearMessageAndKeepsTheRelayOff() async {
        backend.nextResult = .success(LocalAPIStatus(enabled: true, port: 51851, running: false, errorCode: "port_in_use"))
        let controller = makeController()
        controller.engineAvailabilityChanged(true)

        controller.setEnabled(true)
        await settle(controller)

        XCTAssertEqual(controller.phase, .failed(LocalAPIFailure.portInUse.message(port: 51851)))
        XCTAssertFalse(relay.isRunning)
    }

    func test_rejectedSettingsSurfaceAFriendlyError() async {
        backend.nextResult = .failure(IntegrationsServiceError.rejectedSettings)
        let controller = makeController()
        controller.engineAvailabilityChanged(true)

        controller.setEnabled(true)
        await settle(controller)

        XCTAssertEqual(controller.phase, .failed(IntegrationsServiceError.rejectedSettings.errorDescription ?? ""))
    }

    func test_disablingStopsTheServerAndRelay() async {
        let controller = makeController()
        controller.engineAvailabilityChanged(true)
        controller.setEnabled(true)
        await settle(controller)

        controller.setEnabled(false)
        await settle(controller)

        XCTAssertEqual(backend.applied.last, .disabled)
        XCTAssertEqual(controller.phase, .off)
        XCTAssertFalse(relay.isRunning)
        XCTAssertFalse(testDefaults.defaults.bool(forKey: LocalAPIController.enabledKey))
    }

    func test_invalidPortIsRejectedWithoutApplying() async {
        let controller = makeController()
        controller.engineAvailabilityChanged(true)
        controller.setEnabled(true)
        await settle(controller)

        controller.portText = "80"
        controller.commitPort()

        XCTAssertEqual(controller.portError, LocalAPIPort.invalidMessage)
        XCTAssertEqual(controller.port, 51851)
        XCTAssertEqual(backend.applied.count, 1)
    }

    func test_validPortChangeIsSavedAndApplied() async {
        let controller = makeController()
        controller.engineAvailabilityChanged(true)
        controller.setEnabled(true)
        await settle(controller)

        controller.portText = " 6100 "
        controller.commitPort()
        await settle(controller)

        XCTAssertNil(controller.portError)
        XCTAssertEqual(controller.portText, "6100")
        XCTAssertEqual(testDefaults.defaults.integer(forKey: LocalAPIController.portKey), 6100)
        XCTAssertEqual(backend.applied.last, .enabled(port: 6100, apiKey: Self.fixedKey))
    }

    func test_regeneratingTheKeyRestartsWithTheNewKey() async {
        var nextKey = Self.fixedKey
        let controller = LocalAPIController(
            backend: backend,
            secrets: secrets.store,
            defaults: testDefaults.defaults,
            generateKey: { nextKey }
        )
        controller.attachRelay(relay)
        controller.engineAvailabilityChanged(true)
        controller.setEnabled(true)
        await settle(controller)

        nextKey = "vq_" + String(repeating: "B", count: 43)
        controller.regenerateKey()
        await settle(controller)

        XCTAssertEqual(controller.apiKey, nextKey)
        XCTAssertEqual(secrets.value(for: .localAPIKey), nextKey)
        XCTAssertEqual(backend.applied.last, .enabled(port: 51851, apiKey: nextKey))
    }

    func test_keychainFailureKeepsTheAPIOff() {
        secrets.failsWrites = true
        let controller = makeController()
        controller.engineAvailabilityChanged(true)

        controller.setEnabled(true)

        XCTAssertFalse(controller.isEnabled)
        XCTAssertEqual(controller.keyError, LocalAPIController.keyStorageFailure)
        XCTAssertTrue(backend.applied.isEmpty)
    }

    func test_keyGenerationFailureKeepsTheAPIOff() {
        let controller = makeController(key: nil)
        controller.engineAvailabilityChanged(true)

        controller.setEnabled(true)

        XCTAssertFalse(controller.isEnabled)
        XCTAssertEqual(controller.keyError, LocalAPIController.keyGenerationFailure)
    }

    func test_refreshStatusReportsAServerThatStopped() async {
        let controller = makeController()
        controller.engineAvailabilityChanged(true)
        controller.setEnabled(true)
        await settle(controller)
        backend.statusResult = .success(LocalAPIStatus(enabled: true, port: 51851, running: false, errorCode: "stopped"))

        await controller.refreshStatus()

        XCTAssertEqual(controller.phase, .failed(LocalAPIFailure.stopped.message(port: 51851)))
    }

    func test_outOfRangeStoredPortFallsBackToDefault() {
        testDefaults.defaults.set(80, forKey: LocalAPIController.portKey)

        XCTAssertEqual(makeController().port, LocalAPIPort.defaultValue)
    }
}
