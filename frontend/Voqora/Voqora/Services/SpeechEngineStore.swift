import Combine
import Foundation

@MainActor
final class SpeechEngineStore: ObservableObject {
    static let shared = SpeechEngineStore()

    @Published private(set) var engines: [SpeechEngine] = []
    @Published private(set) var state: VoicesLoadState = .idle
    @Published private(set) var actionError: String?
    @Published private(set) var revision = 0

    private let service: any SpeechEngineServing
    private let pollInterval: Duration
    private var pollTask: Task<Void, Never>?

    init(service: (any SpeechEngineServing)? = nil, pollInterval: Duration = .seconds(1)) {
        self.service = service ?? SpeechEngineService()
        self.pollInterval = pollInterval
    }

    var supertonicVoices: [SpeechEngineVoice] {
        SpeechEngineCatalog.installedVoices(for: SpeechEngineID.supertonic, in: engines)
    }

    func engine(id: String) -> SpeechEngine? {
        SpeechEngineCatalog.engine(id, in: engines)
    }

    func displayName(forVoice voice: String) -> String? {
        SpeechEngineCatalog.displayName(forVoice: voice, in: engines)
    }

    func resolvedVoice(_ voice: String) -> String {
        guard state == .loaded else { return voice }
        return SpeechEngineCatalog.resolve(voice: voice, in: engines)
    }

    func refresh() async {
        do {
            try await apply(service.list())
            state = .loaded
        } catch {
            VoqoraLog.warn("SpeechEngineStore", "Speech engines failed to load", ["status": BackendAPIError.logLabel(for: error)])
            if state != .loaded {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func install(_ id: String) async {
        actionError = nil
        do {
            try await replace(service.install(id: id))
            beginPollingIfNeeded()
        } catch {
            VoqoraLog.warn("SpeechEngineStore", "Speech engine install failed", ["status": BackendAPIError.logLabel(for: error)])
            actionError = error.localizedDescription
        }
    }

    func uninstall(_ id: String) async {
        actionError = nil
        do {
            try await replace(service.uninstall(id: id))
        } catch {
            VoqoraLog.warn("SpeechEngineStore", "Speech engine removal failed", ["status": BackendAPIError.logLabel(for: error)])
            actionError = error.localizedDescription
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func waitForPolling() async {
        await pollTask?.value
    }

    private func beginPollingIfNeeded() {
        guard pollTask == nil, engines.contains(where: \.downloading) else { return }
        pollTask = Task { [weak self] in
            while let self, !Task.isCancelled, await pollOnce() {
                try? await Task.sleep(for: pollInterval)
            }
            self?.pollTask = nil
        }
    }

    private func pollOnce() async -> Bool {
        await refresh()
        return engines.contains(where: \.downloading)
    }

    private func apply(_ latest: [SpeechEngine]) {
        guard latest != engines else { return }
        engines = latest
        revision &+= 1
    }

    private func replace(_ updated: SpeechEngine) {
        var next = engines
        if let index = next.firstIndex(where: { $0.id == updated.id }) {
            next[index] = updated
        } else {
            next.append(updated)
        }
        apply(next)
        if state != .loaded {
            state = .loaded
        }
    }
}
