import Combine
import FluidAudio
import Foundation

nonisolated enum ParakeetModelError: LocalizedError, Equatable, Sendable {
    case notInstalled
    case downloadInProgress

    var errorDescription: String? {
        switch self {
        case .notInstalled: "The Parakeet speech model isn't installed."
        case .downloadInProgress: "The Parakeet speech model is still downloading."
        }
    }
}

@MainActor
final class ParakeetModelStore: ObservableObject {
    enum State: Equatable, Sendable {
        case notInstalled
        case downloading(Double?)
        case installed
        case failed(String)
    }

    static let shared = ParakeetModelStore()

    @Published private(set) var state: State
    private(set) var revision = 0

    private let version: AsrModelVersion
    private let directory: URL
    private var cachedModels: AsrModels?
    private var loadTask: Task<AsrModels, Error>?

    init(version: AsrModelVersion = .v3, directory: URL? = nil) {
        self.version = version
        self.directory = directory ?? AsrModels.defaultCacheDirectory(for: version)
        state = Self.installedState(version: version, directory: self.directory)
    }

    var isInstalled: Bool {
        state == .installed
    }

    var isDownloading: Bool {
        if case .downloading = state {
            return true
        }
        return false
    }

    func refresh() {
        guard !isDownloading else { return }
        state = Self.installedState(version: version, directory: directory)
    }

    func download() async {
        guard !isDownloading else { return }
        state = .downloading(nil)
        let target = directory
        let version = version
        let (updates, continuation) = AsyncStream<Double?>.makeStream()
        let consumer = Task { @MainActor [weak self] in
            for await fraction in updates {
                self?.applyProgress(fraction)
            }
        }
        defer { continuation.finish() }
        do {
            try await AsrModels.download(to: target, version: version) { progress in
                continuation.yield(Self.determinateFraction(progress))
            }
            continuation.finish()
            await consumer.value
            revision += 1
            cachedModels = nil
            state = .installed
            VoqoraLog.info("ParakeetModelStore", "Parakeet model installed")
        } catch is CancellationError {
            state = Self.installedState(version: version, directory: target)
        } catch {
            VoqoraLog.warn("ParakeetModelStore", "Parakeet model download failed", ["error": "\(error)"])
            state = .failed(error.localizedDescription)
        }
    }

    func remove() throws {
        guard !isDownloading else { throw ParakeetModelError.downloadInProgress }
        loadTask?.cancel()
        loadTask = nil
        cachedModels = nil
        revision += 1
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        state = .notInstalled
    }

    func loadedModels() async throws -> AsrModels {
        if let cachedModels {
            return cachedModels
        }
        guard isInstalled else { throw ParakeetModelError.notInstalled }
        if let loadTask {
            return try await loadTask.value
        }
        let version = version
        let directory = directory
        let task = Task { try await AsrModels.load(from: directory, version: version) }
        loadTask = task
        defer { loadTask = nil }
        do {
            let models = try await task.value
            cachedModels = models
            return models
        } catch {
            if !(error is CancellationError) {
                VoqoraLog.warn("ParakeetModelStore", "Parakeet model failed to load", ["error": "\(error)"])
                state = .failed(error.localizedDescription)
            }
            throw error
        }
    }

    private func applyProgress(_ fraction: Double?) {
        guard case let .downloading(current) = state, let fraction else { return }
        state = .downloading(max(current ?? 0, fraction))
    }

    private nonisolated static func determinateFraction(_ progress: DownloadProgress) -> Double? {
        guard case .downloading = progress.phase else { return nil }
        return min(1, max(0, progress.fractionCompleted))
    }

    private static func installedState(version: AsrModelVersion, directory: URL) -> State {
        AsrModels.modelsExist(at: directory, version: version) ? .installed : .notInstalled
    }
}
