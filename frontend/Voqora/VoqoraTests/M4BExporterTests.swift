import AppKit
import AVFoundation
@testable import Voqora
import XCTest

@MainActor
final class M4BExporterTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoqoraM4BExporterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
    }

    func test_export_writesAudioChaptersAndMetadata() async throws {
        let source = try writeSineWAV(seconds: 3, timestamp: 1)
        let output = directory.appendingPathComponent("Test Book.m4b")
        let cover = try makeJPEG()
        let recorder = ProgressRecorder()
        let request = M4BExportRequest(
            sources: [source],
            chapters: [
                M4BChapter(title: "Opening", startSeconds: 0),
                M4BChapter(title: "Middle", startSeconds: 1),
                M4BChapter(title: "Finale", startSeconds: 2),
            ],
            title: "Test Book",
            author: "Bella",
            cover: cover,
            outputURL: output
        )

        try await M4BExporter().export(request) { recorder.record($0) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 3, accuracy: 0.25)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audioTracks.count, 1)
        let titles = try await chapterTitles(of: asset)
        XCTAssertEqual(titles, ["Opening", "Middle", "Finale"])
        let commonMetadata = try await asset.load(.commonMetadata)
        let titleItem = try XCTUnwrap(AVMetadataItem.metadataItems(from: commonMetadata, filteredByIdentifier: .commonIdentifierTitle).first)
        let title = try await titleItem.load(.stringValue)
        XCTAssertEqual(title, "Test Book")
        XCTAssertFalse(AVMetadataItem.metadataItems(from: commonMetadata, filteredByIdentifier: .commonIdentifierArtwork).isEmpty)
        XCTAssertEqual(recorder.values.last, 1)
        XCTAssertEqual(recorder.values, recorder.values.sorted())
    }

    func test_export_concatenatesSourcesAndReplacesExistingFile() async throws {
        let first = try writeSineWAV(seconds: 1.5, timestamp: 2)
        let second = try writeSineWAV(seconds: 1.5, timestamp: 3)
        let output = directory.appendingPathComponent("Joined.m4b")
        try Data("stale".utf8).write(to: output)
        let request = M4BExportRequest(
            sources: [first, second],
            chapters: [M4BChapter(title: "Part One", startSeconds: 0), M4BChapter(title: "Part Two", startSeconds: 1.5)],
            title: "Joined",
            author: "Bella",
            bitrate: 48000,
            outputURL: output
        )

        try await M4BExporter().export(request) { _ in }

        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 3, accuracy: 0.25)
        let titles = try await chapterTitles(of: asset)
        XCTAssertEqual(titles, ["Part One", "Part Two"])
    }

    func test_export_rejectsInvalidRequestsBeforeEncoding() async throws {
        let source = try writeSineWAV(seconds: 0.5, timestamp: 4)
        let output = directory.appendingPathComponent("Invalid.m4b")

        let noSources = await exportError(M4BExportRequest(sources: [], chapters: [], title: "Book", author: "", outputURL: output))
        let missingSource = directory.appendingPathComponent("missing.wav")
        let missing = await exportError(M4BExportRequest(sources: [missingSource], chapters: [], title: "Book", author: "", outputURL: output))
        let untitled = await exportError(M4BExportRequest(sources: [source], chapters: [], title: "  ", author: "", outputURL: output))
        let loud = await exportError(M4BExportRequest(sources: [source], chapters: [], title: "Book", author: "", bitrate: 320_000, outputURL: output))

        XCTAssertEqual(noSources as? M4BExportError, .noSourceAudio)
        XCTAssertEqual(missing as? M4BExportError, .missingSourceFile)
        XCTAssertEqual(untitled as? M4BExportError, .missingTitle)
        XCTAssertEqual(loud as? M4BExportError, .unsupportedBitrate)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func test_export_rejectsUnreadableAudio() async throws {
        let source = directory.appendingPathComponent("broken.wav")
        try Data("not audio".utf8).write(to: source)
        let output = directory.appendingPathComponent("Broken.m4b")

        let error = await exportError(M4BExportRequest(sources: [source], chapters: [], title: "Broken", author: "", outputURL: output))

        XCTAssertEqual(error as? M4BExportError, .unreadableAudio)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func test_cancelledExport_throwsCancellationAndLeavesNoFile() async throws {
        let source = try writeSineWAV(seconds: 2, timestamp: 5)
        let output = directory.appendingPathComponent("Cancelled.m4b")
        let request = M4BExportRequest(sources: [source], chapters: [], title: "Cancelled", author: "", outputURL: output)

        let task = Task { try await M4BExporter().export(request) { _ in } }
        task.cancel()

        do {
            try await task.value
            XCTFail("Expected the export to be cancelled")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    private func exportError(_ request: M4BExportRequest) async -> Error? {
        do {
            try await M4BExporter().export(request) { _ in }
            return nil
        } catch {
            return error
        }
    }

    private func chapterTitles(of asset: AVURLAsset) async throws -> [String] {
        let locales = try await asset.load(.availableChapterLocales)
        let languages = locales.map(\.identifier) + Locale.preferredLanguages + ["und", "en"]
        let groups = try await asset.loadChapterMetadataGroups(bestMatchingPreferredLanguages: languages)
        var titles: [String] = []
        for group in groups {
            guard let item = group.items.first(where: { $0.commonKey == .commonKeyTitle }) ?? group.items.first,
                  let title = try await item.load(.stringValue)
            else { continue }
            titles.append(title)
        }
        return titles
    }

    private func writeSineWAV(seconds: Double, timestamp: Int) throws -> URL {
        let sampleRate = 24000.0
        let count = Int(seconds * sampleRate)
        let samples: [Int16] = (0 ..< count).map { index in
            Int16(sin(2 * Double.pi * 440 * Double(index) / sampleRate) * 12000)
        }
        let pcm = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        return try AudioService.writeWAV(pcmData: pcm, to: directory, timestamp: timestamp)
    }

    private func makeJPEG() throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 4,
            pixelsHigh: 4,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        return try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [:]))
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Double] = []

    var values: [Double] {
        lock.withLock { recorded }
    }

    func record(_ value: Double) {
        lock.withLock { recorded.append(value) }
    }
}
