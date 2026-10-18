@testable import Voqora
import XCTest

@MainActor
final class AudiobookExportControllerTests: XCTestCase {
    private enum TranscriptFailure: Error {
        case unavailable
    }

    private struct Notice: Equatable {
        let message: String
        let kind: AudiobookViewModel.Toast.Kind
    }

    private var directory: URL!
    private var notices: [Notice] = []
    private var offeredNames: [String] = []

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoqoraExportControllerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        notices = []
        offeredNames = []
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

    func test_m4bExport_clampsStoredBitrate() async throws {
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

    private var sourceURL: URL {
        directory.appendingPathComponent("source.wav")
    }

    private func makeController(
        exporter: RecordingExporter,
        destination: URL?,
        source: URL? = nil,
        cover: Data? = nil,
        bitrateKbps: Int = 64
    ) -> AudiobookExportController {
        let resolvedSource = source ?? sourceURL
        let dependencies = AudiobookExportController.Dependencies(
            audioURL: { _ in resolvedSource },
            transcript: { _ in throw TranscriptFailure.unavailable },
            cover: { _ in cover },
            chooseDestination: { [weak self] _, name in
                self?.offeredNames.append(name)
                return destination
            },
            exporter: exporter,
            bitrateKbps: { bitrateKbps },
            copyFile: { try AtomicFileReplacement.copy($0, to: $1) },
            notify: { [weak self] message, kind in
                self?.notices.append(Notice(message: message, kind: kind))
            }
        )
        return AudiobookExportController(dependencies: dependencies)
    }

    private func makeBook(id: String = "book-1", status: String = "done", sections: [AudiobookSection] = []) -> Audiobook {
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
            error: nil
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
