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

    func test_cancel_throwsForNonexistentBook() async {
        let service = AudiobookService(connection: unreachableConnection())
        do {
            try await service.cancel("definitely-not-a-real-book-\(UUID().uuidString)")
            XCTFail("cancel must throw on a transport error or non-2xx response")
        } catch {}
    }

    func test_subscribe_yieldsStalledEventAfterConsecutiveFailures() async {
        let service = AudiobookService(connection: unreachableConnection())
        let stream = service.subscribe(to: "any-book")

        let sawStalled = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await event in stream where event["type"] as? String == "stalled" {
                    return true
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }

        XCTAssertTrue(sawStalled)
        XCTAssertEqual(AudiobookService.stalledReconnectThreshold, 3)
    }

    private func unreachableConnection() -> BackendConnection {
        BackendConnection(baseURL: URL(string: "http://127.0.0.1:1")!, token: "test")
    }
}
