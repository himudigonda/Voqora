import Combine
import Foundation

@MainActor
final class AudiobookshelfUploadController: ObservableObject {
    enum Stage: Equatable {
        case exporting
        case uploading
    }

    struct ActiveUpload: Equatable {
        let bookID: String
        var stage: Stage
        var progress: Double
    }

    struct Dependencies {
        var destination: @MainActor () -> AudiobookshelfDestination?
        var render: @MainActor (Audiobook, URL, @escaping @Sendable (Double) -> Void) async throws -> Void
        var upload: @MainActor (AudiobookshelfUpload, @escaping @Sendable (Double) -> Void) async throws -> Void
        var temporaryDirectory: URL
        var notify: @MainActor (String, AudiobookViewModel.Toast.Kind) -> Void
    }

    static let exportShare = 0.4
    static let genericFailureMessage = "Couldn't upload this audiobook to Audiobookshelf."

    @Published private(set) var active: ActiveUpload?
    private let dependencies: Dependencies
    private var task: Task<Void, Never>?

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    var isAvailable: Bool {
        dependencies.destination() != nil
    }

    func isUploading(_ book: Audiobook) -> Bool {
        active?.bookID == book.bookID
    }

    func progress(for book: Audiobook) -> Double? {
        isUploading(book) ? active?.progress : nil
    }

    func upload(_ book: Audiobook) {
        guard active == nil else {
            dependencies.notify("Another upload is still running.", .info)
            return
        }
        guard book.status == "done" else {
            dependencies.notify(AudiobookServiceError.audioNotReady.localizedDescription, .error)
            return
        }
        guard let destination = dependencies.destination() else {
            dependencies.notify(AudiobookshelfError.notConfigured.localizedDescription, .error)
            return
        }
        active = ActiveUpload(bookID: book.bookID, stage: .exporting, progress: 0)
        dependencies.notify("Preparing \(book.displayTitle) for Audiobookshelf…", .info)
        task = Task { [weak self] in
            await self?.run(book, destination: destination)
        }
    }

    func cancel() {
        task?.cancel()
    }

    func waitUntilFinished() async {
        await task?.value
    }

    private func run(_ book: Audiobook, destination: AudiobookshelfDestination) async {
        let workspace = dependencies.temporaryDirectory.appendingPathComponent("Voqora-abs-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: workspace)
            active = nil
            task = nil
        }
        do {
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            let file = workspace.appendingPathComponent(AudiobookExportNaming.fileName(for: book.displayTitle, format: .m4b))
            let bookID = book.bookID
            try await dependencies.render(book, file) { fraction in
                Task { @MainActor [weak self] in
                    self?.update(.exporting, fraction: fraction, for: bookID)
                }
            }
            try Task.checkCancellation()
            update(.uploading, fraction: 0, for: bookID)
            let upload = AudiobookshelfUpload(destination: destination, title: book.displayTitle, author: nil, file: file)
            try await dependencies.upload(upload) { fraction in
                Task { @MainActor [weak self] in
                    self?.update(.uploading, fraction: fraction, for: bookID)
                }
            }
            try Task.checkCancellation()
            VoqoraLog.info("Audiobookshelf", "Upload finished", ["bookID": bookID])
            dependencies.notify("Uploaded \(book.displayTitle) to Audiobookshelf.", .success)
        } catch {
            guard !(error is CancellationError), !Task.isCancelled else {
                dependencies.notify("Upload cancelled.", .info)
                return
            }
            VoqoraLog.error("Audiobookshelf", "Upload failed", [
                "bookID": book.bookID,
                "failureCode": Self.failureCode(for: error),
            ])
            dependencies.notify(Self.message(for: error), .error)
        }
    }

    private func update(_ stage: Stage, fraction: Double, for bookID: String) {
        guard var current = active, current.bookID == bookID else { return }
        let overall = Self.overallProgress(stage: stage, fraction: fraction)
        if stage == .uploading {
            current.stage = .uploading
        }
        guard current.stage == stage else { return }
        current.progress = max(current.progress, overall)
        active = current
    }

    static func overallProgress(stage: Stage, fraction: Double) -> Double {
        let clamped = min(1, max(0, fraction))
        switch stage {
        case .exporting: return clamped * exportShare
        case .uploading: return exportShare + clamped * (1 - exportShare)
        }
    }

    static func message(for error: Error) -> String {
        switch error {
        case let shelfError as AudiobookshelfError: shelfError.errorDescription ?? genericFailureMessage
        case let exportError as M4BExportError: exportError.errorDescription ?? genericFailureMessage
        case let serviceError as AudiobookServiceError: serviceError.errorDescription ?? genericFailureMessage
        default: genericFailureMessage
        }
    }

    static func failureCode(for error: Error) -> String {
        switch error {
        case let shelfError as AudiobookshelfError: shelfError.failureCode
        case let exportError as M4BExportError: exportError.failureCode
        case is AudiobookServiceError: "audiobook_audio_unavailable"
        default: "abs_upload_failed"
        }
    }
}

extension AudiobookshelfUploadController.Dependencies {
    static func live(
        renderer: AudiobookM4BRenderer,
        settings: AudiobookshelfSettingsStore,
        client: any AudiobookshelfServing,
        notify: @escaping @MainActor (String, AudiobookViewModel.Toast.Kind) -> Void
    ) -> Self {
        Self(
            destination: { [weak settings] in settings?.destination },
            render: { try await renderer.render($0, to: $1, progress: $2) },
            upload: { try await client.upload($0, progress: $1) },
            temporaryDirectory: FileManager.default.temporaryDirectory,
            notify: notify
        )
    }
}
