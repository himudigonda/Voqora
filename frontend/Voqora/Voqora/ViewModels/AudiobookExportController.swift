import AppKit
import Combine
import Foundation

enum AudiobookExportFormat: String, CaseIterable, Identifiable {
    case m4b
    case wav

    var id: String {
        rawValue
    }

    var menuTitle: String {
        switch self {
        case .m4b: "Audiobook (M4B)…"
        case .wav: "Audio Only (WAV)…"
        }
    }

    var systemImage: String {
        switch self {
        case .m4b: "books.vertical"
        case .wav: "waveform"
        }
    }

    var panelTitle: String {
        switch self {
        case .m4b: "Export Audiobook"
        case .wav: "Export Audio"
        }
    }

    var fileExtension: String {
        rawValue
    }
}

enum AudiobookExportSettings {
    static let bitrateKey = "audiobookExportBitrateKbps"
    static let defaultBitrateKbps = 64
    static let bitrateOptionsKbps = [48, 64, 96, 128]

    static func bitrateKbps(in defaults: UserDefaults = .standard) -> Int {
        guard defaults.object(forKey: bitrateKey) != nil else { return defaultBitrateKbps }
        return clampedKbps(defaults.integer(forKey: bitrateKey))
    }

    static func clampedKbps(_ kbps: Int) -> Int {
        let range = M4BExportRequest.bitrateRange
        return min(max(kbps, range.lowerBound / 1000), range.upperBound / 1000)
    }
}

enum AudiobookExportNaming {
    static let fallbackName = "Audiobook"
    static let maximumLength = 120
    private static let unsafeCharacters = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        .union(.controlCharacters)
        .union(.newlines)

    static func fileName(for title: String, format: AudiobookExportFormat) -> String {
        "\(sanitized(title)).\(format.fileExtension)"
    }

    static func sanitized(_ title: String) -> String {
        let scalars: [Unicode.Scalar] = title.unicodeScalars.map { unsafeCharacters.contains($0) ? " " : $0 }
        let collapsed = String(String.UnicodeScalarView(scalars))
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        let trimmed = String(collapsed.prefix(maximumLength))
            .trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespaces))
        return trimmed.isEmpty ? fallbackName : trimmed
    }
}

enum AudiobookExportPanel {
    static func chooseDestination(for format: AudiobookExportFormat, suggestedName: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = format.panelTitle
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}

@MainActor
final class AudiobookExportController: ObservableObject {
    struct ActiveExport: Equatable {
        let bookID: String
        let format: AudiobookExportFormat
        var progress: Double
    }

    struct Dependencies {
        var audioURL: @MainActor (Audiobook) async throws -> URL
        var transcript: @MainActor (String) async throws -> AudiobookService.Transcript
        var cover: @MainActor (String) async -> Data?
        var chooseDestination: @MainActor (AudiobookExportFormat, String) -> URL?
        var exporter: any M4BExporting
        var bitrateKbps: @MainActor () -> Int
        var copyFile: @MainActor (URL, URL) throws -> Void
        var notify: @MainActor (String, AudiobookViewModel.Toast.Kind) -> Void
    }

    @Published private(set) var active: ActiveExport?
    private let dependencies: Dependencies
    private var task: Task<Void, Never>?

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    func isExporting(_ book: Audiobook) -> Bool {
        active?.bookID == book.bookID
    }

    func progress(for book: Audiobook) -> Double? {
        isExporting(book) ? active?.progress : nil
    }

    func export(_ book: Audiobook, as format: AudiobookExportFormat) {
        guard active == nil else {
            dependencies.notify("Another export is still running.", .info)
            return
        }
        guard book.status == "done" else {
            dependencies.notify(AudiobookServiceError.audioNotReady.localizedDescription, .error)
            return
        }
        let suggestedName = AudiobookExportNaming.fileName(for: book.displayTitle, format: format)
        guard let destination = dependencies.chooseDestination(format, suggestedName) else { return }
        active = ActiveExport(bookID: book.bookID, format: format, progress: 0)
        task = Task { [weak self] in
            await self?.run(book, format: format, to: destination)
        }
    }

    func cancel() {
        task?.cancel()
    }

    func waitUntilFinished() async {
        await task?.value
    }

    private func run(_ book: Audiobook, format: AudiobookExportFormat, to destination: URL) async {
        defer {
            active = nil
            task = nil
        }
        do {
            let source = try await dependencies.audioURL(book)
            try Task.checkCancellation()
            switch format {
            case .m4b:
                try await exportM4B(book, source: source, to: destination)
            case .wav:
                try dependencies.copyFile(source, destination)
            }
            dependencies.notify("Exported \(destination.lastPathComponent)", .success)
        } catch is CancellationError {
            dependencies.notify("Export cancelled.", .info)
        } catch {
            VoqoraLog.error("AudiobookExport", "Export failed", [
                "bookID": book.bookID,
                "format": format.rawValue,
                "failureCode": Self.failureCode(for: error),
            ])
            dependencies.notify(Self.message(for: error), .error)
        }
    }

    private func exportM4B(_ book: Audiobook, source: URL, to destination: URL) async throws {
        let markers = await chapters(for: book)
        let cover = await dependencies.cover(book.bookID)
        let request = M4BExportRequest(
            sources: [source],
            chapters: markers,
            title: book.displayTitle,
            author: book.narratorName,
            cover: cover,
            bitrate: AudiobookExportSettings.clampedKbps(dependencies.bitrateKbps()) * 1000,
            outputURL: destination
        )
        let bookID = book.bookID
        try await dependencies.exporter.export(request) { fraction in
            Task { @MainActor in
                self.updateProgress(fraction, for: bookID)
            }
        }
    }

    private func chapters(for book: Audiobook) async -> [M4BChapter] {
        let document = await transcriptDocument(for: book.bookID)
        return Self.chapters(from: AudiobookViewModel.chapters(for: book, document: document))
    }

    private func transcriptDocument(for bookID: String) async -> TranscriptDocument {
        guard let transcript = try? await dependencies.transcript(bookID) else { return .empty }
        return await Task.detached(priority: .userInitiated) {
            TranscriptDocument(transcript: transcript)
        }.value
    }

    private func updateProgress(_ fraction: Double, for bookID: String) {
        guard var current = active, current.bookID == bookID else { return }
        current.progress = min(1, max(current.progress, fraction))
        active = current
    }

    static func chapters(from sections: [AudiobookSection]) -> [M4BChapter] {
        sections.map { M4BChapter(title: AudiobookImportStaging.displayName(from: $0.title), startSeconds: $0.startTime) }
    }

    static func message(for error: Error) -> String {
        switch error {
        case let exportError as M4BExportError: exportError.errorDescription ?? genericFailureMessage
        case let serviceError as AudiobookServiceError: serviceError.errorDescription ?? genericFailureMessage
        default: genericFailureMessage
        }
    }

    static func failureCode(for error: Error) -> String {
        switch error {
        case let exportError as M4BExportError: exportError.failureCode
        case is AudiobookServiceError: "audiobook_audio_unavailable"
        default: "audiobook_export_failed"
        }
    }

    static let genericFailureMessage = "Couldn't export this audiobook."
}

extension AudiobookExportController.Dependencies {
    static func live(service: AudiobookService, viewModel: AudiobookViewModel) -> Self {
        Self(
            audioURL: { [weak viewModel] book in
                guard let viewModel else { throw CancellationError() }
                return try await viewModel.validatedAudioURL(for: book)
            },
            transcript: { try await service.transcript(for: $0) },
            cover: { await service.coverImageData(for: $0) },
            chooseDestination: { AudiobookExportPanel.chooseDestination(for: $0, suggestedName: $1) },
            exporter: M4BExporter(),
            bitrateKbps: { AudiobookExportSettings.bitrateKbps() },
            copyFile: { try AtomicFileReplacement.copy($0, to: $1) },
            notify: { [weak viewModel] message, kind in viewModel?.showToast(message, kind: kind) }
        )
    }
}
