import Combine
import Foundation

@MainActor
protocol SpeechRelayControlling: AnyObject {
    var isRunning: Bool { get }
    func start()
    func stop()
}

extension SpeechRelaySubscriber: SpeechRelayControlling {}

@MainActor
final class LocalAPIController: ObservableObject {
    static let enabledKey = "localAPIEnabled"
    static let portKey = "localAPIPort"
    static let keyStorageFailure = "Voqora could not save the API key to your Keychain. Try again."
    static let keyGenerationFailure = "Voqora could not create a secure API key. Try again."

    @Published private(set) var isEnabled: Bool
    @Published private(set) var port: Int
    @Published var portText: String
    @Published private(set) var portError: String?
    @Published private(set) var apiKey: String
    @Published private(set) var keyError: String?
    @Published private(set) var phase: LocalAPIPhase
    @Published private(set) var isApplying = false

    private let backend: any LocalAPIBackend
    private let secrets: SecretStore
    private let defaults: UserDefaults
    private let generateKey: () -> String?
    private var relay: (any SpeechRelayControlling)?
    private var isEngineAvailable = false
    private var applyGeneration = 0
    private var engineObserver: AnyCancellable?

    init(
        backend: any LocalAPIBackend,
        secrets: SecretStore,
        defaults: UserDefaults,
        generateKey: (() -> String?)? = nil
    ) {
        self.backend = backend
        self.secrets = secrets
        self.defaults = defaults
        self.generateKey = generateKey ?? { LocalAPIKey.generate() }
        let enabled = defaults.bool(forKey: Self.enabledKey)
        let storedPort = defaults.object(forKey: Self.portKey) as? Int
        let port = storedPort.flatMap { LocalAPIPort.range.contains($0) ? $0 : nil } ?? LocalAPIPort.defaultValue
        isEnabled = enabled
        self.port = port
        portText = String(port)
        apiKey = secrets.get(.localAPIKey) ?? ""
        phase = enabled ? .waitingForEngine : .off
    }

    func attachRelay(_ relay: any SpeechRelayControlling) {
        self.relay = relay
    }

    func observeEngine(_ online: AnyPublisher<Bool, Never>) {
        engineObserver = online
            .removeDuplicates()
            .sink { [weak self] isOnline in
                self?.engineAvailabilityChanged(isOnline)
            }
    }

    func engineAvailabilityChanged(_ available: Bool) {
        isEngineAvailable = available
        if available {
            if isEnabled {
                apply()
            }
        } else {
            applyGeneration &+= 1
            isApplying = false
            relay?.stop()
            phase = isEnabled ? .waitingForEngine : .off
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        if enabled {
            guard ensureKey() else { return }
        }
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
        VoqoraLog.info("LocalAPI", enabled ? "Local API turned on" : "Local API turned off")
        if !enabled {
            relay?.stop()
        }
        apply()
    }

    func commitPort() {
        guard let parsed = LocalAPIPort.parse(portText) else {
            portError = LocalAPIPort.invalidMessage
            return
        }
        portError = nil
        portText = String(parsed)
        guard parsed != port else { return }
        port = parsed
        defaults.set(parsed, forKey: Self.portKey)
        if isEnabled {
            apply()
        }
    }

    func regenerateKey() {
        guard storeNewKey() else { return }
        VoqoraLog.info("LocalAPI", "Local API key regenerated")
        if isEnabled {
            apply()
        }
    }

    func refreshStatus() async {
        guard isEngineAvailable, !isApplying else { return }
        do {
            let status = try await backend.status()
            phase = isEnabled ? LocalAPIPhase(status: status, requestedPort: port) : .off
        } catch {
            VoqoraLog.warn("LocalAPI", "Could not read local API status", ["failureCode": Self.failureCode(for: error)])
        }
    }

    private func apply() {
        guard isEngineAvailable else {
            phase = isEnabled ? .waitingForEngine : .off
            return
        }
        applyGeneration &+= 1
        let generation = applyGeneration
        let configuration: LocalAPIConfiguration = isEnabled ? .enabled(port: port, apiKey: apiKey) : .disabled
        isApplying = true
        if isEnabled {
            phase = .starting
        }
        let backend = backend
        Task { [weak self] in
            do {
                let status = try await backend.apply(configuration)
                self?.finishApply(.success(status), generation: generation)
            } catch {
                self?.finishApply(.failure(error), generation: generation)
            }
        }
    }

    private func finishApply(_ outcome: Result<LocalAPIStatus, Error>, generation: Int) {
        guard generation == applyGeneration else { return }
        isApplying = false
        switch outcome {
        case let .success(status):
            phase = isEnabled ? LocalAPIPhase(status: status, requestedPort: port) : .off
            if let failure = status.failure {
                VoqoraLog.warn("LocalAPI", "Local API could not start", ["failureCode": "local_api_\(failure.rawValue)"])
            }
        case let .failure(error):
            VoqoraLog.error("LocalAPI", "Could not apply local API settings", ["failureCode": Self.failureCode(for: error)])
            phase = isEnabled ? .failed(Self.message(for: error)) : .off
        }
        if isEnabled, phase.isRunning {
            relay?.start()
        } else {
            relay?.stop()
        }
    }

    private func ensureKey() -> Bool {
        if LocalAPIKey.isValid(apiKey) {
            return true
        }
        return storeNewKey()
    }

    private func storeNewKey() -> Bool {
        guard let key = generateKey(), LocalAPIKey.isValid(key) else {
            keyError = Self.keyGenerationFailure
            return false
        }
        guard secrets.set(key, .localAPIKey) else {
            keyError = Self.keyStorageFailure
            return false
        }
        keyError = nil
        apiKey = key
        return true
    }

    static func message(for error: Error) -> String {
        (error as? IntegrationsServiceError)?.errorDescription ?? LocalAPIPhase.genericFailure
    }

    static func failureCode(for error: Error) -> String {
        (error as? IntegrationsServiceError)?.failureCode ?? "local_api_request_failed"
    }
}

extension LocalAPIController {
    static func live(
        speaker: any SpeechInputSpeaking,
        announce: @escaping @MainActor (String) -> Void,
        defaults: UserDefaults
    ) -> LocalAPIController {
        let service = IntegrationsService()
        let controller = LocalAPIController(backend: service, secrets: .keychain, defaults: defaults)
        let player = SpeechRelayPlayer(speaker: speaker, announce: announce)
        let relay = SpeechRelaySubscriber(
            connect: { [weak service] in
                service?.events() ?? AsyncThrowingStream { $0.finish() }
            },
            handle: { player.handle($0) }
        )
        controller.attachRelay(relay)
        return controller
    }
}
