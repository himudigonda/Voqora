import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

enum AudiobookExportFormat: String, CaseIterable, Identifiable {
    case m4b
    case mp3
    case wav
    case srt
    case vtt

    var id: String {
        rawValue
    }

    static let audioFormats: [AudiobookExportFormat] = [.m4b, .mp3, .wav]
    static let subtitleFormats: [AudiobookExportFormat] = [.srt, .vtt]

    var menuTitle: String {
        switch self {
        case .m4b: "Audiobook (M4B)…"
        case .mp3: "Audio (MP3)…"
        case .wav: "Audio Only (WAV)…"
        case .srt: "Subtitles (SRT)…"
        case .vtt: "Subtitles (WebVTT)…"
        }
    }

    var systemImage: String {
        switch self {
        case .m4b: "books.vertical"
        case .mp3: "music.note"
        case .wav: "waveform"
        case .srt, .vtt: "captions.bubble"
        }
    }

    var panelTitle: String {
        switch self {
        case .m4b: "Export Audiobook"
        case .mp3, .wav: "Export Audio"
        case .srt, .vtt: "Export Subtitles"
        }
    }

    var fileExtension: String {
        rawValue
    }

    var subtitleFormat: AudiobookSubtitleFormat? {
        switch self {
        case .srt: .srt
        case .vtt: .vtt
        case .m4b, .mp3, .wav: nil
        }
    }
}

enum AudiobookExportSettings {
    static let bitrateKey = "audiobookExportBitrateKbps"
    static let defaultBitrateKbps = 64
    static let bitrateOptionsKbps = [48, 64, 96, 128]

    static let mp3BitrateKey = "audiobookMP3BitrateKbps"
    static let defaultMP3BitrateKbps = 96
    static let mp3BitrateOptionsKbps = [64, 80, 96, 112, 128, 160, 192]

    static func bitrateKbps(in defaults: UserDefaults = .standard) -> Int {
        guard defaults.object(forKey: bitrateKey) != nil else { return defaultBitrateKbps }
        return clampedKbps(defaults.integer(forKey: bitrateKey))
    }

    static func clampedKbps(_ kbps: Int) -> Int {
        let range = M4BExportRequest.bitrateRange
        return min(max(kbps, range.lowerBound / 1000), range.upperBound / 1000)
    }

    static func mp3BitrateKbps(in defaults: UserDefaults = .standard) -> Int {
        guard defaults.object(forKey: mp3BitrateKey) != nil else { return defaultMP3BitrateKbps }
        return nearestMP3Kbps(defaults.integer(forKey: mp3BitrateKey))
    }

    static func nearestMP3Kbps(_ kbps: Int) -> Int {
        mp3BitrateOptionsKbps.min { abs($0 - kbps) < abs($1 - kbps) } ?? defaultMP3BitrateKbps
    }
}

enum AudiobookExportNaming {
    static let fallbackName = "Audiobook"
    static let maximumLength = 120
    static let maximumUTF8Length = 200
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
        var limited = collapsed.prefix(maximumLength)
        while limited.utf8.count > maximumUTF8Length {
            limited.removeLast()
        }
        let trimmed = limited.trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespaces))
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
        if let contentType = UTType(filenameExtension: format.fileExtension) {
            panel.allowedContentTypes = [contentType]
        }
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}

@MainActor
final class AudiobookExportController: ObservableObject {
    struct ActiveExport: Equatable {
        let bookID: String
        var progress: Double
    }

    struct Dependencies {
        var audioURL: @MainActor (Audiobook) async throws -> URL
        var transcript: @MainActor (String) async throws -> AudiobookService.Transcript
        var chapters: @MainActor (String) async throws -> AudiobookChapterList
        var cover: @MainActor (String) async -> Data?
        var chooseDestination: @MainActor (AudiobookExportFormat, String) -> URL?
        var exporter: any M4BExporting
        var bitrateKbps: @MainActor () -> Int
        var mp3BitrateKbps: @MainActor () -> Int
        var downloadMP3: @MainActor (String, Int, URL, @escaping @Sendable (Double) -> Void) async throws -> Void
        var downloadSubtitles: @MainActor (String, AudiobookSubtitleFormat, URL) async throws -> Void
        var copyFile: @MainActor (URL, URL) async throws -> Void
        var notify: @MainActor (String, AudiobookViewModel.Toast.Kind) -> Void
    }

    static let genericFailureMessage = "Couldn't export this audiobook."

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
        active = ActiveExport(bookID: book.bookID, progress: 0)
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
            try await perform(book, format: format, to: destination)
            dependencies.notify("Exported \(destination.lastPathComponent)", .success)
        } catch {
            guard !(error is CancellationError), !Task.isCancelled else {
                dependencies.notify("Export cancelled.", .info)
                return
            }
            VoqoraLog.error("AudiobookExport", "Export failed", [
                "bookID": book.bookID,
                "format": format.rawValue,
                "failureCode": Self.failureCode(for: error),
            ])
            dependencies.notify(Self.message(for: error, format: format), .error)
        }
    }

    private func perform(_ book: Audiobook, format: AudiobookExportFormat, to destination: URL) async throws {
        switch format {
        case .m4b:
            let source = try await dependencies.audioURL(book)
            try Task.checkCancellation()
            try await exportM4B(book, source: source, to: destination)
        case .wav:
            let source = try await dependencies.audioURL(book)
            try Task.checkCancellation()
            try await dependencies.copyFile(source, destination)
        case .mp3:
            let kbps = AudiobookExportSettings.nearestMP3Kbps(dependencies.mp3BitrateKbps())
            try await dependencies.downloadMP3(book.bookID, kbps, destination, progressHandler(for: book.bookID))
        case .srt, .vtt:
            guard let subtitles = format.subtitleFormat else { return }
            try await dependencies.downloadSubtitles(book.bookID, subtitles, destination)
        }
    }

    private func exportM4B(_ book: Audiobook, source: URL, to destination: URL) async throws {
        let markers = await chapters(for: book)
        try Task.checkCancellation()
        let cover = await dependencies.cover(book.bookID)
        let request = M4BExportRequest(
            sources: [source],
            chapters: markers,
            title: book.displayTitle,
            author: book.displayAuthor ?? book.narratorName,
            cover: cover,
            bitrate: AudiobookExportSettings.clampedKbps(dependencies.bitrateKbps()) * 1000,
            outputURL: destination
        )
        try await dependencies.exporter.export(request, progress: progressHandler(for: book.bookID))
    }

    private func progressHandler(for bookID: String) -> @Sendable (Double) -> Void {
        { fraction in
            Task { @MainActor in
                self.updateProgress(fraction, for: bookID)
            }
        }
    }

    private func chapters(for book: Audiobook) async -> [M4BChapter] {
        if let list = try? await dependencies.chapters(book.bookID), let exact = Self.chapters(from: list) {
            return exact
        }
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

    static func chapters(from list: AudiobookChapterList) -> [M4BChapter]? {
        let chapters = list.chapters
            .filter { $0.startSeconds.isFinite && $0.startSeconds >= 0 }
            .map { M4BChapter(title: AudiobookImportStaging.displayName(from: $0.title), startSeconds: $0.startSeconds) }
        return chapters.count >= 2 ? chapters : nil
    }

    static func message(for error: Error, format: AudiobookExportFormat = .m4b) -> String {
        switch error {
        case let exportError as M4BExportError: exportError.errorDescription ?? genericFailureMessage
        case let serviceError as AudiobookServiceError: serviceError.errorDescription ?? genericFailureMessage
        case let failure as AudiobookAPIFailure: AudiobookExportFailureMessage.message(for: failure, format: format)
        case let urlError as URLError: AudiobookExportFailureMessage.message(for: urlError)
        default: genericFailureMessage
        }
    }

    static func failureCode(for error: Error) -> String {
        switch error {
        case let exportError as M4BExportError: exportError.failureCode
        case is AudiobookServiceError: "audiobook_audio_unavailable"
        case let failure as AudiobookAPIFailure: "audiobook_export_http_\(failure.statusCode)"
        case is URLError: "audiobook_export_transfer_failed"
        default: "audiobook_export_failed"
        }
    }
}

enum AudiobookExportFailureMessage {
    static func message(for failure: AudiobookAPIFailure, format: AudiobookExportFormat) -> String {
        let isSubtitle = format.subtitleFormat != nil
        switch failure.statusCode {
        case 404:
            return isSubtitle ? "This audiobook's transcript isn't ready yet." : "This audiobook's narration isn't ready yet."
        case 409:
            return "This audiobook is still being generated. Export it once it's ready."
        case 422:
            return "Choose an MP3 quality in Preferences, then try again."
        case 429:
            return "Another MP3 export is in progress. Try again shortly."
        case 503:
            return "MP3 export isn't available in this version of Voqora."
        default:
            return isSubtitle ? "Couldn't export these subtitles." : AudiobookExportController.genericFailureMessage
        }
    }

    static func message(for error: URLError) -> String {
        switch error.code {
        case .timedOut: "The export took too long. Try again."
        case .networkConnectionLost: "The export was interrupted. Try again."
        default: AudiobookExportController.genericFailureMessage
        }
    }
}

extension AudiobookExportController.Dependencies {
    static func live(service: AudiobookService, viewModel: AudiobookViewModel) -> Self {
        Self(
            audioURL: { [weak viewModel] book in
                guard let viewModel else { throw CancellationError() }
                return try await viewModel.validatedAudioURL(for: book)
            },
            transcript: { try await service.transcript(for: $0) },
            chapters: { try await service.chapters(for: $0) },
            cover: { await service.coverImageData(for: $0) },
            chooseDestination: { AudiobookExportPanel.chooseDestination(for: $0, suggestedName: $1) },
            exporter: M4BExporter(),
            bitrateKbps: { AudiobookExportSettings.bitrateKbps() },
            mp3BitrateKbps: { AudiobookExportSettings.mp3BitrateKbps() },
            downloadMP3: { bookID, kbps, destination, progress in
                try await service.exportMP3(bookID, bitrateKbps: kbps, to: destination, progress: progress)
            },
            downloadSubtitles: { bookID, format, destination in
                try await service.exportSubtitles(bookID, as: format, to: destination)
            },
            copyFile: { source, destination in
                try await Task.detached(priority: .userInitiated) {
                    try AtomicFileReplacement.copy(source, to: destination)
                }.value
            },
            notify: { [weak viewModel] message, kind in viewModel?.showToast(message, kind: kind) }
        )
    }
}
