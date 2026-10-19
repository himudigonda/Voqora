@testable import Voqora
import XCTest

@MainActor
final class AudiobookExportControllerTests: XCTestCase {
    private enum TranscriptFailure: Error {
        case unavailable
    }

    @MainActor
    private struct Notice: Equatable {
        let message: String
        let kind: AudiobookViewModel.Toast.Kind
    }

    private struct Download: Equatable {
        let bookID: String
        let kbps: Int
        let destination: URL
    }

    private struct SubtitleRequest: Equatable {
        let bookID: String
        let format: AudiobookSubtitleFormat
        let destination: URL
    }

    private var directory: URL!
    private var notices: [Notice] = []
    private var offeredNames: [String] = []
    private var downloads: [Download] = []
    private var subtitleRequests: [SubtitleRequest] = []

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoqoraExportControllerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        notices = []
        offeredNames = []
        downloads = []
        subtitleRequests = []
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
    }

    func test_m4bExport_buildsRequestFromSectionsCoverAndPreferences() async throws {
        let exporter = RecordingExporter()
        let destination = directory.appendingPathComponent("Test Book.m4b")
        let controller = makeController(exporter: exporter, destination: destination, cover: Data([0xFF, 0xD8, 0xFF]), bitrateKbps: 96)
        let book = makeBook(sections: [
            AudiobookSection(title: "Chapter_Two", startPage: 3, endPage: 4, startTime: 60),
            AudiobookSection(title: "Opening", startPage: 1, endPage: 2, startTime: 0),
        ])

        controller.export(book, as: .m4b)
        XCTAssertTrue(controller.isExporting(book))
        await controller.waitUntilFinished()

        let request = try XCTUnwrap(exporter.requests.first)
        XCTAssertEqual(exporter.requests.count, 1)
        XCTAssertEqual(request.sources, [sourceURL])
        XCTAssertEqual(request.outputURL, destination)
        XCTAssertEqual(request.title, "Test Book")
        XCTAssertEqual(request.author, book.narratorName)
        XCTAssertEqual(request.cover, Data([0xFF, 0xD8, 0xFF]))
        XCTAssertEqual(request.bitrate, 96000)
        XCTAssertEqual(request.chapters, [
            M4BChapter(title: "Opening", startSeconds: 0),
            M4BChapter(title: "Chapter Two", startSeconds: 60),
        ])
        XCTAssertEqual(offeredNames, ["Test Book.m4b"])
        XCTAssertEqual(notices, [Notice(message: "Exported Test Book.m4b", kind: .success)])
        XCTAssertNil(controller.active)
    }

    func test_m4bExport_clampsStoredBitrate() async {
        let exporter = RecordingExporter()
        let controller = makeController(exporter: exporter, destination: directory.appendingPathComponent("a.m4b"), bitrateKbps: 512)

        controller.export(makeBook(), as: .m4b)
        await controller.waitUntilFinished()

        XCTAssertEqual(exporter.requests.first?.bitrate, 128_000)
    }

    func test_cancelledSavePanel_doesNothing() async {
        let exporter = RecordingExporter()
        let controller = makeController(exporter: exporter, destination: nil)

        controller.export(makeBook(), as: .m4b)
        await controller.waitUntilFinished()

        XCTAssertTrue(exporter.requests.isEmpty)
        XCTAssertTrue(notices.isEmpty)
        XCTAssertNil(controller.active)
    }

    func test_unfinishedBook_isRejectedWithoutOpeningPanel() {
        let controller = makeController(exporter: RecordingExporter(), destination: directory.appendingPathComponent("a.m4b"))

        controller.export(makeBook(status: "tts"), as: .m4b)

        XCTAssertTrue(offeredNames.isEmpty)
        XCTAssertEqual(notices, [Notice(message: "Audio is not ready yet.", kind: .error)])
    }

    func test_exportFailure_showsUserFacingMessage() async {
        let controller = makeController(
            exporter: RecordingExporter(failure: .encodingFailed),
            destination: directory.appendingPathComponent("a.m4b")
        )

        controller.export(makeBook(), as: .m4b)
        await controller.waitUntilFinished()

        XCTAssertEqual(notices, [Notice(message: "Voqora couldn't encode the audiobook. Try again.", kind: .error)])
    }

    func test_secondExportWhileRunning_isDeclined() async {
        let exporter = RecordingExporter()
        let controller = makeController(exporter: exporter, destination: directory.appendingPathComponent("a.m4b"))

        controller.export(makeBook(), as: .m4b)
        controller.export(makeBook(id: "book-2"), as: .wav)
        await controller.waitUntilFinished()

        XCTAssertEqual(exporter.requests.count, 1)
        XCTAssertEqual(notices.first, Notice(message: "Another export is still running.", kind: .info))
    }

    func test_cancel_stopsBeforeEncoding() async {
        let exporter = RecordingExporter()
        let controller = makeController(exporter: exporter, destination: directory.appendingPathComponent("a.m4b"))

        controller.export(makeBook(), as: .m4b)
        controller.cancel()
        await controller.waitUntilFinished()

        XCTAssertTrue(exporter.requests.isEmpty)
        XCTAssertEqual(notices, [Notice(message: "Export cancelled.", kind: .info)])
    }

    func test_wavExport_replacesExistingFileWithNarration() async throws {
        let source = directory.appendingPathComponent("narration.wav")
        try Data("narration".utf8).write(to: source)
        let destination = directory.appendingPathComponent("Test Book.wav")
        try Data("old".utf8).write(to: destination)
        let controller = makeController(exporter: RecordingExporter(), destination: destination, source: source)

        controller.export(makeBook(), as: .wav)
        await controller.waitUntilFinished()

        XCTAssertEqual(try Data(contentsOf: destination), Data("narration".utf8))
        XCTAssertEqual(try Data(contentsOf: source), Data("narration".utf8))
        XCTAssertEqual(offeredNames, ["Test Book.wav"])
        XCTAssertEqual(notices, [Notice(message: "Exported Test Book.wav", kind: .success)])
    }

    func test_fileNames_areSanitizedForTheFileSystem() {
        XCTAssertEqual(AudiobookExportNaming.fileName(for: "Part 1: The/Start?", format: .m4b), "Part 1 The Start.m4b")
        XCTAssertEqual(AudiobookExportNaming.fileName(for: "  .hidden  ", format: .wav), "hidden.wav")
        XCTAssertEqual(AudiobookExportNaming.fileName(for: "...", format: .m4b), "Audiobook.m4b")
        XCTAssertEqual(AudiobookExportNaming.sanitized("Line\nBreak\tTab"), "Line Break Tab")
        XCTAssertEqual(AudiobookExportNaming.sanitized(String(repeating: "b", count: 300)).count, AudiobookExportNaming.maximumLength)
        XCTAssertLessThanOrEqual(AudiobookExportNaming.sanitized(String(repeating: "本", count: 300)).utf8.count, AudiobookExportNaming.maximumUTF8Length)
    }

    func test_bitrateSetting_defaultsAndClamps() throws {
        let suiteName = "VoqoraExportSettingsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(AudiobookExportSettings.bitrateKbps(in: defaults), 64)
        defaults.set(96, forKey: AudiobookExportSettings.bitrateKey)
        XCTAssertEqual(AudiobookExportSettings.bitrateKbps(in: defaults), 96)
        defaults.set(16, forKey: AudiobookExportSettings.bitrateKey)
        XCTAssertEqual(AudiobookExportSettings.bitrateKbps(in: defaults), 48)
        defaults.set(320, forKey: AudiobookExportSettings.bitrateKey)
        XCTAssertEqual(AudiobookExportSettings.bitrateKbps(in: defaults), 128)
    }

    func test_m4bExport_prefersExactChaptersFromTheBackend() async throws {
        let exporter = RecordingExporter()
        let list = AudiobookChapterList(totalAudioSeconds: 600, chapters: [
            AudiobookChapterList.Chapter(title: "Part_One", startSeconds: 0, endSeconds: 250.125),
            AudiobookChapterList.Chapter(title: "Part Two", startSeconds: 250.125, endSeconds: 600),
        ])
        let controller = makeController(exporter: exporter, destination: directory.appendingPathComponent("a.m4b"), chapters: list)
        let book = makeBook(sections: [AudiobookSection(title: "Derived", startPage: 1, endPage: 2, startTime: 10)])

        controller.export(book, as: .m4b)
        await controller.waitUntilFinished()

        XCTAssertEqual(try XCTUnwrap(exporter.requests.first).chapters, [
            M4BChapter(title: "Part One", startSeconds: 0),
            M4BChapter(title: "Part Two", startSeconds: 250.125),
        ])
    }

    func test_m4bExport_fallsBackToDerivedChaptersWhenTheBackendHasOnlyOne() async throws {
        let exporter = RecordingExporter()
        let single = AudiobookChapterList(totalAudioSeconds: 600, chapters: [
            AudiobookChapterList.Chapter(title: "Test Book", startSeconds: 0, endSeconds: 600),
        ])
        let controller = makeController(exporter: exporter, destination: directory.appendingPathComponent("a.m4b"), chapters: single)
        let book = makeBook(sections: [
            AudiobookSection(title: "One", startPage: 1, endPage: 1, startTime: 0),
            AudiobookSection(title: "Two", startPage: 2, endPage: 2, startTime: 30),
        ])

        controller.export(book, as: .m4b)
        await controller.waitUntilFinished()

        XCTAssertEqual(try XCTUnwrap(exporter.requests.first).chapters.map(\.startSeconds), [0, 30])
    }

    func test_m4bExport_usesTheBookAuthorWhenKnown() async throws {
        let exporter = RecordingExporter()
        let controller = makeController(exporter: exporter, destination: directory.appendingPathComponent("a.m4b"))

        controller.export(makeBook(author: "  Herman   Melville "), as: .m4b)
        await controller.waitUntilFinished()

        XCTAssertEqual(try XCTUnwrap(exporter.requests.first).author, "Herman Melville")
    }

    func test_m4bExport_creditsAPodcastWithItsCreditLineNotTheFirstVoice() async throws {
        let exporter = RecordingExporter()
        let controller = makeController(exporter: exporter, destination: directory.appendingPathComponent("a.m4b"))
        let speakers = [
            PodcastSpeaker(id: "host_1", name: "Avery", voice: "af_bella"),
            PodcastSpeaker(id: "host_2", name: "Jordan", voice: "am_adam"),
        ]
        let podcast = makeBook(kind: Audiobook.podcastKind, speakers: speakers)

        controller.export(podcast, as: .m4b)
        await controller.waitUntilFinished()

        let author = try XCTUnwrap(exporter.requests.first).author
        XCTAssertEqual(author, podcast.creditLine)
        XCTAssertEqual(author, "With \(ListFormatter.localizedString(byJoining: ["Avery", "Jordan"]))")
        XCTAssertNotEqual(author, podcast.narratorName)
    }

    func test_mp3Export_downloadsAtTheNearestAllowedBitrate() async {
        let destination = directory.appendingPathComponent("Test Book.mp3")
        let controller = makeController(exporter: RecordingExporter(), destination: destination, mp3BitrateKbps: 100)

        controller.export(makeBook(), as: .mp3)
        XCTAssertEqual(controller.progress(for: makeBook()), 0)
        await controller.waitUntilFinished()

        XCTAssertEqual(downloads, [Download(bookID: "book-1", kbps: 96, destination: destination)])
        XCTAssertEqual(offeredNames, ["Test Book.mp3"])
        XCTAssertEqual(notices, [Notice(message: "Exported Test Book.mp3", kind: .success)])
        XCTAssertNil(controller.active)
    }

    func test_mp3Export_mapsABusyEncoderToAClearMessage() async {
        let controller = makeController(
            exporter: RecordingExporter(),
            destination: directory.appendingPathComponent("a.mp3"),
            downloadFailure: AudiobookAPIFailure(statusCode: 429, detail: "busy")
        )

        controller.export(makeBook(), as: .mp3)
        await controller.waitUntilFinished()

        XCTAssertEqual(notices, [Notice(message: "Another MP3 export is in progress. Try again shortly.", kind: .error)])
    }

    func test_subtitleExports_requestTheMatchingFormat() async {
        let srt = directory.appendingPathComponent("Test Book.srt")
        let srtController = makeController(exporter: RecordingExporter(), destination: srt)
        srtController.export(makeBook(), as: .srt)
        await srtController.waitUntilFinished()

        let vtt = directory.appendingPathComponent("Test Book.vtt")
        let vttController = makeController(exporter: RecordingExporter(), destination: vtt)
        vttController.export(makeBook(), as: .vtt)
        await vttController.waitUntilFinished()

        XCTAssertEqual(subtitleRequests, [
            SubtitleRequest(bookID: "book-1", format: .srt, destination: srt),
            SubtitleRequest(bookID: "book-1", format: .vtt, destination: vtt),
        ])
        XCTAssertEqual(offeredNames, ["Test Book.srt", "Test Book.vtt"])
    }

    func test_subtitleExport_explainsAMissingTranscript() async {
        let controller = makeController(
            exporter: RecordingExporter(),
            destination: directory.appendingPathComponent("a.vtt"),
            downloadFailure: AudiobookAPIFailure(statusCode: 404, detail: "Transcript not ready.")
        )

        controller.export(makeBook(), as: .vtt)
        await controller.waitUntilFinished()

        XCTAssertEqual(notices, [Notice(message: "This audiobook's transcript isn't ready yet.", kind: .error)])
    }

    func test_failureMessages_coverEveryExportStatus() {
        XCTAssertEqual(
            AudiobookExportController.message(for: AudiobookAPIFailure(statusCode: 409), format: .mp3),
            "This audiobook is still being generated. Export it once it's ready."
        )
        XCTAssertEqual(
            AudiobookExportController.message(for: AudiobookAPIFailure(statusCode: 503), format: .mp3),
            "MP3 export isn't available in this version of Voqora."
        )
        XCTAssertEqual(
            AudiobookExportController.message(for: AudiobookAPIFailure(statusCode: 500), format: .srt),
            "Couldn't export these subtitles."
        )
        XCTAssertEqual(
            AudiobookExportController.message(for: URLError(.timedOut), format: .mp3),
            "The export took too long. Try again."
        )
        XCTAssertEqual(AudiobookExportController.failureCode(for: AudiobookAPIFailure(statusCode: 429)), "audiobook_export_http_429")
    }

    func test_formatsAreGroupedForTheMenu() {
        XCTAssertEqual(Set(AudiobookExportFormat.audioFormats + AudiobookExportFormat.subtitleFormats), Set(AudiobookExportFormat.allCases))
        XCTAssertEqual(AudiobookExportFormat.mp3.fileExtension, "mp3")
        XCTAssertEqual(AudiobookExportFormat.vtt.subtitleFormat, .vtt)
        XCTAssertNil(AudiobookExportFormat.m4b.subtitleFormat)
        XCTAssertEqual(AudiobookExportNaming.fileName(for: "Notes: Part 1", format: .srt), "Notes Part 1.srt")
    }

    func test_mp3BitrateSetting_defaultsAndSnapsToAllowedValues() throws {
        let suiteName = "VoqoraMP3SettingsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(AudiobookExportSettings.mp3BitrateKbps(in: defaults), 96)
        defaults.set(160, forKey: AudiobookExportSettings.mp3BitrateKey)
        XCTAssertEqual(AudiobookExportSettings.mp3BitrateKbps(in: defaults), 160)
        defaults.set(20, forKey: AudiobookExportSettings.mp3BitrateKey)
        XCTAssertEqual(AudiobookExportSettings.mp3BitrateKbps(in: defaults), 64)
        defaults.set(320, forKey: AudiobookExportSettings.mp3BitrateKey)
        XCTAssertEqual(AudiobookExportSettings.mp3BitrateKbps(in: defaults), 192)
        XCTAssertEqual(AudiobookExportSettings.nearestMP3Kbps(115), 112)
    }

    private var sourceURL: URL {
        directory.appendingPathComponent("source.wav")
    }

    private func makeController(
        exporter: RecordingExporter,
        destination: URL?,
        source: URL? = nil,
        cover: Data? = nil,
        bitrateKbps: Int = 64,
        mp3BitrateKbps: Int = 96,
        chapters: AudiobookChapterList? = nil,
        downloadFailure: Error? = nil
    ) -> AudiobookExportController {
        let resolvedSource = source ?? sourceURL
        let dependencies = AudiobookExportController.Dependencies(
            audioURL: { _ in resolvedSource },
            transcript: { _ in throw TranscriptFailure.unavailable },
            chapters: { _ in
                guard let chapters else { throw TranscriptFailure.unavailable }
                return chapters
            },
            cover: { _ in cover },
            chooseDestination: { [weak self] _, name in
                self?.offeredNames.append(name)
                return destination
            },
            exporter: exporter,
            bitrateKbps: { bitrateKbps },
            mp3BitrateKbps: { mp3BitrateKbps },
            downloadMP3: { [weak self] bookID, kbps, destination, progress in
                self?.downloads.append(Download(bookID: bookID, kbps: kbps, destination: destination))
                progress(0.5)
                if let downloadFailure {
                    throw downloadFailure
                }
            },
            downloadSubtitles: { [weak self] bookID, format, destination in
                self?.subtitleRequests.append(SubtitleRequest(bookID: bookID, format: format, destination: destination))
                if let downloadFailure {
                    throw downloadFailure
                }
            },
            copyFile: { try AtomicFileReplacement.copy($0, to: $1) },
            notify: { [weak self] message, kind in
                self?.notices.append(Notice(message: message, kind: kind))
            }
        )
        return AudiobookExportController(dependencies: dependencies)
    }

    private func makeBook(
        id: String = "book-1",
        status: String = "done",
        sections: [AudiobookSection] = [],
        author: String? = nil,
        kind: String? = nil,
        speakers: [PodcastSpeaker]? = nil
    ) -> Audiobook {
        Audiobook(
            bookID: id,
            title: "Test Book.pdf",
            createdAt: "2026-01-01T00:00:00Z",
            pageCount: 10,
            status: status,
            phaseProgress: PhaseProgress(pageDone: 10, pageTotal: 10),
            sections: sections,
            pageToTime: [:],
            totalAudioSeconds: 600,
            failedPages: [],
            estimated: nil,
            actual: nil,
            engine: "kokoro",
            voice: "af_bella",
            speed: 1.0,
            usesLLMCleanup: false,
            budget: nil,
            error: nil,
            author: author,
            kind: kind,
            speakers: speakers
        )
    }
}

private final class RecordingExporter: M4BExporting, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [M4BExportRequest] = []
    private let failure: M4BExportError?

    init(failure: M4BExportError? = nil) {
        self.failure = failure
    }

    var requests: [M4BExportRequest] {
        lock.withLock { recorded }
    }

    func export(_ request: M4BExportRequest, progress: @escaping @Sendable (Double) -> Void) async throws {
        lock.withLock { recorded.append(request) }
        progress(0.5)
        if let failure {
            throw failure
        }
    }
}
