@testable import Voqora
import XCTest

final class AudiobookServiceTests: XCTestCase {
    func test_mimeTypeMatchesEverySupportedAudiobookDocumentKind() {
        XCTAssertEqual(AudiobookService.mimeType(forFileExtension: "pdf"), "application/pdf")
        XCTAssertEqual(
            AudiobookService.mimeType(forFileExtension: "docx"),
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        )
        XCTAssertEqual(AudiobookService.mimeType(forFileExtension: "txt"), "text/plain; charset=utf-8")
        XCTAssertEqual(AudiobookService.mimeType(forFileExtension: "MD"), "text/plain; charset=utf-8")
    }

    func test_unknownMimeTypeFallsBackSafely() {
        XCTAssertEqual(AudiobookService.mimeType(forFileExtension: "rtf"), "application/octet-stream")
    }

    func test_pruneCacheKeepsOnlyTheMostRecentBooks() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for (index, name) in ["old", "mid", "new"].enumerated() {
            let file = dir.appendingPathComponent("\(name).wav")
            try Data([0]).write(to: file)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: TimeInterval(1000 * (index + 1)))],
                ofItemAtPath: file.path
            )
        }
        try Data([0]).write(to: dir.appendingPathComponent("notes.txt"))

        AudiobookService.pruneCache(in: dir, keeping: 2)

        let remaining = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        XCTAssertEqual(remaining, ["mid.wav", "new.wav", "notes.txt"])
    }

    func test_verificationSurfacesDetailFromRejectedRequests() {
        let body = Data(#"{"detail":"Enter a valid API key."}"#.utf8)

        let result = AudiobookService.decodeVerification(data: body, statusCode: 400)

        XCTAssertEqual(result, LLMVerification(verified: false, models: [], error: "Enter a valid API key."))
    }

    func test_verificationKeepsErrorFieldOnSuccessfulResponses() {
        let body = Data(#"{"verified":false,"models":[],"error":"Google rejected the API key."}"#.utf8)

        let result = AudiobookService.decodeVerification(data: body, statusCode: 200)

        XCTAssertEqual(result, LLMVerification(verified: false, models: [], error: "Google rejected the API key."))
    }

    func test_verificationReadsModelsOnSuccess() {
        let body = Data(#"{"verified":true,"models":["a","b"]}"#.utf8)

        XCTAssertEqual(
            AudiobookService.decodeVerification(data: body, statusCode: 200),
            LLMVerification(verified: true, models: ["a", "b"], error: nil)
        )
    }

    func test_verificationIgnoresNonJSONBodies() {
        XCTAssertNil(AudiobookService.decodeVerification(data: Data("oops".utf8), statusCode: 502))
    }
}
