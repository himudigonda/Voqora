@testable import Voqora
import XCTest

@MainActor
final class AudioExportTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoqoraAudioExportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
    }

    func test_writeWAV_writesValidHeaderAndAvoidsNameCollisions() throws {
        let pcm = Data([0x01, 0x00, 0xFF, 0x7F])

        let first = try AudioService.writeWAV(pcmData: pcm, to: directory, timestamp: 1_700_000_000)
        let second = try AudioService.writeWAV(pcmData: pcm, to: directory, timestamp: 1_700_000_000)

        XCTAssertEqual(first.lastPathComponent, "Voqora_1700000000.wav")
        XCTAssertEqual(second.lastPathComponent, "Voqora_1700000000_2.wav")
        XCTAssertEqual(try Data(contentsOf: first).prefix(4), Data("RIFF".utf8))
        XCTAssertEqual(try Data(contentsOf: first).subdata(in: 8..<12), Data("WAVE".utf8))
        XCTAssertEqual(try Data(contentsOf: first).suffix(4), pcm)
    }

    func test_writeWAV_rejectsEmptyPCM() {
        XCTAssertThrowsError(
            try AudioService.writeWAV(pcmData: Data(), to: directory, timestamp: 1_700_000_000)
        ) { error in
            XCTAssertEqual((error as? AudioService.ExportError)?.errorDescription, "There is no generated audio to save yet.")
        }
    }
}
