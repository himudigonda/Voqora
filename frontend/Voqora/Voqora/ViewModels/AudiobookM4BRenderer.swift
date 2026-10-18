import Foundation

struct AudiobookM4BRenderer {
    var audioURL: @MainActor (Audiobook) async throws -> URL
    var transcript: @MainActor (String) async throws -> AudiobookService.Transcript
    var chapterList: @MainActor (String) async throws -> AudiobookChapterList
    var cover: @MainActor (String) async -> Data?
    var exporter: any M4BExporting
    var bitrateKbps: @MainActor () -> Int

    func render(_ book: Audiobook, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let source = try await audioURL(book)
        try Task.checkCancellation()
        try await render(book, source: source, to: destination, progress: progress)
    }

    func render(_ book: Audiobook, source: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let markers = await chapters(for: book)
        try Task.checkCancellation()
        let artwork = await cover(book.bookID)
        let request = M4BExportRequest(
            sources: [source],
            chapters: markers,
            title: book.displayTitle,
            author: book.displayAuthor ?? book.narratorName,
            cover: artwork,
            bitrate: AudiobookExportSettings.clampedKbps(bitrateKbps()) * 1000,
            outputURL: destination
        )
        try await exporter.export(request, progress: progress)
    }

    private func chapters(for book: Audiobook) async -> [M4BChapter] {
        if let list = try? await chapterList(book.bookID), let exact = AudiobookExportController.chapters(from: list) {
            return exact
        }
        let document = await transcriptDocument(for: book.bookID)
        return AudiobookExportController.chapters(from: AudiobookViewModel.chapters(for: book, document: document))
    }

    private func transcriptDocument(for bookID: String) async -> TranscriptDocument {
        guard let loaded = try? await transcript(bookID) else { return .empty }
        return await Task.detached(priority: .userInitiated) {
            TranscriptDocument(transcript: loaded)
        }.value
    }
}

extension AudiobookM4BRenderer {
    static func live(service: AudiobookService, viewModel: AudiobookViewModel) -> Self {
        Self(
            audioURL: { [weak viewModel] book in
                guard let viewModel else { throw CancellationError() }
                return try await viewModel.validatedAudioURL(for: book)
            },
            transcript: { try await service.transcript(for: $0) },
            chapterList: { try await service.chapters(for: $0) },
            cover: { await service.coverImageData(for: $0) },
            exporter: M4BExporter(),
            bitrateKbps: { AudiobookExportSettings.bitrateKbps() }
        )
    }
}
