import Combine
import FluidAudio
import Foundation

nonisolated enum LocalSpeechModelError: LocalizedError, Equatable, Sendable {
    case notInstalled(String)
    case downloadInProgress(String)

    var errorDescription: String? {
        switch self {
        case let .notInstalled(title): "The \(title) speech model isn't installed."
        case let .downloadInProgress(title): "The \(title) speech model is still downloading."
        }
    }
}

@MainActor
final class LocalSpeechModelStore: ObservableObject {
    enum State: Equatable, Sendable {
        case notInstalled
        case downloading(Double?)
        case installed
        case failed(String)
    }

    static let parakeet = LocalSpeechModelStore(model: .parakeet)
    static let bark = LocalSpeechModelStore(model: .bark)
    static let barkClean = LocalSpeechModelStore(model: .barkClean)

    static func store(for model: LocalSpeechModel) -> LocalSpeechModelStore {
        switch model {
        case .parakeet: parakeet
        case .bark: bark
        case .barkClean: barkClean
        }
    }

    static func isInstalled(_ model: LocalSpeechModel) -> Bool {
        store(for: model).isInstalled
    }

    @Published private(set) var state: State
    @Published private(set) var isPreparing = false
    private(set) var revision = 0

    let model: LocalSpeechModel
    let directory: URL
    private let downloader: BarkModelDownloader
    private var cachedModels: AsrModels?
    private var loadTask: Task<AsrModels, Error>?

    init(model: LocalSpeechModel = .parakeet, directory: URL? = nil, downloader: BarkModelDownloader = BarkModelDownloader()) {
        self.model = model
        self.directory = directory ?? model.defaultDirectory
        self.downloader = downloader
        state = Self.installedState(model: model, directory: self.directory)
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
        state = Self.installedState(model: model, directory: directory)
    }

    func download() async {
        guard !isDownloading else { return }
        state = .downloading(nil)
        let (updates, continuation) = AsyncStream<Double?>.makeStream()
        let consumer = Task { @MainActor [weak self] in
            for await fraction in updates {
                self?.applyProgress(fraction)
            }
        }
        defer { continuation.finish() }
        do {
            try await fetch { continuation.yield($0) }
            continuation.finish()
            await consumer.value
            revision += 1
            cachedModels = nil
            state = .installed
            VoqoraLog.info("LocalSpeechModelStore", "Speech model installed", ["model": model.rawValue])
            if model.manifest != nil {
                Task { try? await self.loadedModels() }
            }
        } catch is CancellationError {
            state = Self.installedState(model: model, directory: directory)
        } catch {
            VoqoraLog.warn("LocalSpeechModelStore", "Speech model download failed", ["model": model.rawValue, "error": "\(error)"])
            state = .failed(error.localizedDescription)
        }
    }

    func remove() throws {
        guard !isDownloading else { throw LocalSpeechModelError.downloadInProgress(model.title) }
        loadTask?.cancel()
        loadTask = nil
        isPreparing = false
        cachedModels = nil
        revision += 1
        let manager = FileManager.default
        for url in [directory, BarkModelDownloader.stagingDirectory(for: directory)] where manager.fileExists(atPath: url.path) {
            try manager.removeItem(at: url)
        }
        state = .notInstalled
    }

    func loadedModels() async throws -> AsrModels {
        if let cachedModels {
            return cachedModels
        }
        guard isInstalled else { throw LocalSpeechModelError.notInstalled(model.title) }
        if let loadTask {
            return try await loadTask.value
        }
        let model = model
        let directory = directory
        let task = Task.detached {
            model.manifest == nil
                ? try await AsrModels.load(from: directory, version: model.loadVersion)
                : try AsrModels.loadLocal(from: directory, version: model.loadVersion)
        }
        let startedRevision = revision
        loadTask = task
        isPreparing = true
        defer {
            if revision == startedRevision {
                loadTask = nil
                isPreparing = false
            }
        }
        do {
            let models = try await task.value
            guard revision == startedRevision else { throw CancellationError() }
            cachedModels = models
            for other in LocalSpeechModel.allCases where other != model {
                Self.store(for: other).releaseModels()
            }
            return models
        } catch {
            if revision == startedRevision, !(error is CancellationError) {
                VoqoraLog.warn("LocalSpeechModelStore", "Speech model failed to load", ["model": model.rawValue, "error": "\(error)"])
                state = .failed(error.localizedDescription)
            }
            throw error
        }
    }

    func releaseModels() {
        guard loadTask == nil else { return }
        cachedModels = nil
    }

    private func fetch(progress: @escaping @Sendable (Double?) -> Void) async throws {
        let target = directory
        guard let files = model.manifest, let folder = model.repositoryFolder else {
            try await AsrModels.download(to: target, version: model.loadVersion) { update in
                progress(Self.determinateFraction(update))
            }
            return
        }
        try await downloader.install(files, folder: folder, into: target) { progress($0) }
    }

    private func applyProgress(_ fraction: Double?) {
        guard case let .downloading(current) = state, let fraction else { return }
        state = .downloading(max(current ?? 0, fraction))
    }

    private nonisolated static func determinateFraction(_ progress: DownloadProgress) -> Double? {
        guard case .downloading = progress.phase else { return nil }
        return min(1, max(0, progress.fractionCompleted))
    }

    private static func installedState(model: LocalSpeechModel, directory: URL) -> State {
        let installed = model.manifest.map { BarkModelDownloader.isInstalled($0, in: directory) }
            ?? AsrModels.modelsExist(at: directory, version: model.loadVersion)
        return installed ? .installed : .notInstalled
    }
}
