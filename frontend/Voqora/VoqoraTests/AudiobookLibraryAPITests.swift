@testable import Voqora
import XCTest

@MainActor
final class AudiobookLibraryAPITests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoqoraLibraryAPITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        LibraryStubURLProtocol.reset()
        try? FileManager.default.removeItem(at: directory)
        directory = nil
    }

    func test_importWebPage_postsJSONWithTokenVoiceSpeedAndProvider() async throws {
        LibraryStubURLProtocol.install { _ in .json(200, LibraryFixtures.estimate) }
        let credential = LLMCredential(provider: .ollama, apiKey: "secret-key", model: "llama3", serverURL: "http://localhost:11434")

        let estimate = try await LibraryStubURLProtocol.makeService().importWebPage(
            TestLinks.url("https://example.com/story"),
            voice: "af_bella",
            speed: 1.25,
            engine: "kokoro",
            cleanup: credential
        )

        XCTAssertEqual(estimate.title, "An Article")
        XCTAssertEqual(estimate.displayAuthor, "Jane Doe")
        let request = try XCTUnwrap(LibraryStubURLProtocol.requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/audiobook/url")
        XCTAssertEqual(request.headers["X-Voqora-IPC-Token"], "stub-token")
        XCTAssertNil(request.headers["X-Voqora-LLM-Key"])
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        XCTAssertEqual(body["url"] as? String, "https://example.com/story")
        XCTAssertEqual(body["voice"] as? String, "af_bella")
        XCTAssertEqual(body["speed"] as? Double, 1.25)
        XCTAssertEqual(body["engine"] as? String, "kokoro")
        XCTAssertEqual(body["llm_provider"] as? String, "ollama")
        XCTAssertEqual(body["llm_model"] as? String, "llama3")
        XCTAssertEqual(body["llm_base_url"] as? String, "http://localhost:11434")
        XCTAssertFalse(String(decoding: request.body, as: UTF8.self).contains("secret-key"))
    }

    func test_importWebPage_omitsProviderFieldsWithoutCleanup() async throws {
        LibraryStubURLProtocol.install { _ in .json(200, LibraryFixtures.estimate) }

        _ = try await LibraryStubURLProtocol.makeService().importWebPage(
            TestLinks.url("https://example.com/a"),
            voice: "af_bella",
            speed: 1,
            engine: nil
        )

        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: LibraryStubURLProtocol.requests[0].body) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["url", "voice", "speed"])
    }

    func test_importWebPage_surfacesBackendCodeAndDetail() async {
        LibraryStubURLProtocol.install { _ in
            .json(403, #"{"detail":"That address is not allowed.","code":"blocked_address"}"#)
        }

        do {
            _ = try await LibraryStubURLProtocol.makeService().importWebPage(
                TestLinks.url("http://192.168.1.2/"), voice: nil, speed: nil, engine: nil
            )
            XCTFail("A blocked address must throw")
        } catch {
            XCTAssertEqual(
                error as? AudiobookAPIFailure,
                AudiobookAPIFailure(statusCode: 403, detail: "That address is not allowed.", code: "blocked_address")
            )
        }
    }

    func test_chapters_decodesExactStarts() async throws {
        LibraryStubURLProtocol.install { _ in
            .json(200, """
            {"book_id":"b","total_audio_seconds":90.5,"chapters":[
            {"title":"Opening","start_seconds":0.0,"end_seconds":30.25},
            {"title":"Second","start_seconds":30.25,"end_seconds":90.5}]}
            """)
        }

        let list = try await LibraryStubURLProtocol.makeService().chapters(for: "book")

        XCTAssertEqual(list.totalAudioSeconds, 90.5)
        XCTAssertEqual(list.chapters.map(\.startSeconds), [0, 30.25])
        XCTAssertEqual(list.chapters.last?.endSeconds, 90.5)
        XCTAssertEqual(LibraryStubURLProtocol.requests.first?.path, "/audiobook/book/chapters")
    }

    func test_chapters_throwsForNotReadyBooks() async {
        LibraryStubURLProtocol.install { _ in .json(409, #"{"detail":"This audiobook is still being generated."}"#) }

        do {
            _ = try await LibraryStubURLProtocol.makeService().chapters(for: "book")
            XCTFail("A 409 must throw")
        } catch {
            XCTAssertEqual((error as? AudiobookAPIFailure)?.statusCode, 409)
        }
    }

    func test_transcript_requestsWordTimingsAndDecodesThem() async throws {
        LibraryStubURLProtocol.install { _ in .json(200, LibraryFixtures.transcript(includeWords: true)) }

        let transcript = try await LibraryStubURLProtocol.makeService().transcript(for: "book", includingWords: true)

        XCTAssertEqual(LibraryStubURLProtocol.requests.map(\.query), [["words": "true"]])
        let words = try XCTUnwrap(transcript.lines?["1"]?.first?.words)
        XCTAssertEqual(words.map(\.text), ["Hello", "world."])
        XCTAssertEqual(words.last?.end, 1.5)
    }

    func test_transcript_fallsBackToPlainTranscriptWhenWordsAreRejected() async throws {
        LibraryStubURLProtocol.install { request in
            request.query["words"] == nil ? .json(200, LibraryFixtures.transcript(includeWords: false)) : .json(422, #"{"detail":[]}"#)
        }

        let transcript = try await LibraryStubURLProtocol.makeService().transcript(for: "book", includingWords: true)

        XCTAssertEqual(LibraryStubURLProtocol.requests.count, 2)
        XCTAssertNil(transcript.lines?["1"]?.first?.words)
        XCTAssertEqual(transcript.lines?["1"]?.first?.text, "Hello world.")
    }

    func test_transcript_withoutWordsSendsNoQuery() async throws {
        LibraryStubURLProtocol.install { _ in .json(200, LibraryFixtures.transcript(includeWords: false)) }

        _ = try await LibraryStubURLProtocol.makeService().transcript(for: "book")

        XCTAssertEqual(LibraryStubURLProtocol.requests.map(\.query), [[:]])
    }

    func test_exportSubtitles_savesTheBodyAtTheDestination() async throws {
        let srt = "1\n00:00:00,000 --> 00:00:01,500\nHello world.\n\n"
        LibraryStubURLProtocol.install { _ in
            LibraryStubURLProtocol.Reply(status: 200, headers: ["Content-Type": "application/x-subrip"], body: Data(srt.utf8))
        }
        let destination = directory.appendingPathComponent("Book.srt")
        try Data("stale".utf8).write(to: destination)

        try await LibraryStubURLProtocol.makeService().exportSubtitles("book", as: .srt, to: destination)

        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), srt)
        XCTAssertEqual(LibraryStubURLProtocol.requests.first?.path, "/audiobook/book/export/srt")
    }

    func test_exportSubtitles_usesTheWebVTTRoute() async throws {
        LibraryStubURLProtocol.install { _ in
            LibraryStubURLProtocol.Reply(status: 200, body: Data("WEBVTT\n\n".utf8))
        }

        try await LibraryStubURLProtocol.makeService().exportSubtitles("book", as: .vtt, to: directory.appendingPathComponent("Book.vtt"))

        XCTAssertEqual(LibraryStubURLProtocol.requests.first?.path, "/audiobook/book/export/vtt")
    }

    func test_exportMP3_sendsBitrateStreamsFileAndReportsCompletion() async throws {
        let audio = Data((0 ..< 200_000).map { UInt8($0 % 251) })
        LibraryStubURLProtocol.install { _ in
            LibraryStubURLProtocol.Reply(
                status: 200,
                headers: ["Content-Type": "audio/mpeg", "Content-Length": String(audio.count)],
                body: audio
            )
        }
        let destination = directory.appendingPathComponent("Book.mp3")
        let reported = ProgressRecorder()

        try await LibraryStubURLProtocol.makeService().exportMP3("book", bitrateKbps: 128, to: destination) { reported.append($0) }

        XCTAssertEqual(try Data(contentsOf: destination), audio)
        XCTAssertEqual(LibraryStubURLProtocol.requests.first?.query, ["bitrate": "128"])
        XCTAssertEqual(reported.values.last, 1)
        XCTAssertEqual(reported.values, reported.values.sorted())
    }

    func test_exportMP3_withoutContentLengthStillSavesAndFinishesAtOne() async throws {
        let audio = Data((0 ..< 50000).map { UInt8($0 % 241) })
        LibraryStubURLProtocol.install { _ in
            LibraryStubURLProtocol.Reply(status: 200, headers: ["Content-Type": "audio/mpeg"], body: audio)
        }
        let destination = directory.appendingPathComponent("Chunked.mp3")
        let reported = ProgressRecorder()

        try await LibraryStubURLProtocol.makeService().exportMP3("book", bitrateKbps: 96, to: destination) { reported.append($0) }

        XCTAssertEqual(try Data(contentsOf: destination), audio)
        XCTAssertEqual(reported.values, [1])
    }

    func test_exportMP3_replacesAnExistingFileAndSendsAuthorization() async throws {
        let destination = directory.appendingPathComponent("Book.mp3")
        try Data("old".utf8).write(to: destination)
        let audio = Data("new-audio".utf8)
        LibraryStubURLProtocol.install { _ in
            LibraryStubURLProtocol.Reply(status: 200, headers: ["Content-Length": String(audio.count)], body: audio)
        }

        try await LibraryStubURLProtocol.makeService().exportMP3("book", bitrateKbps: 128, to: destination) { _ in }

        XCTAssertEqual(try Data(contentsOf: destination), audio)
        XCTAssertEqual(LibraryStubURLProtocol.requests.first?.headers["X-Voqora-IPC-Token"], "stub-token")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(leftovers, ["Book.mp3"])
    }

    func test_downloadFraction_isDeterminateOnlyWhenTheLengthIsKnown() {
        XCTAssertNil(BackendFileDownload.fraction(written: 10, expected: -1))
        XCTAssertNil(BackendFileDownload.fraction(written: 10, expected: 0))
        XCTAssertEqual(BackendFileDownload.fraction(written: 25, expected: 100), 0.25)
        XCTAssertEqual(BackendFileDownload.fraction(written: 150, expected: 100), 1)
        XCTAssertEqual(BackendFileDownload.fraction(written: -5, expected: 100), 0)
    }

    func test_exportMP3_failureLeavesNoFileAndCarriesStatus() async {
        LibraryStubURLProtocol.install { _ in
            .json(429, #"{"detail":"Another MP3 export is in progress. Try again shortly."}"#)
        }
        let destination = directory.appendingPathComponent("Book.mp3")

        do {
            try await LibraryStubURLProtocol.makeService().exportMP3("book", bitrateKbps: 96, to: destination) { _ in }
            XCTFail("A busy encoder must throw")
        } catch {
            XCTAssertEqual((error as? AudiobookAPIFailure)?.statusCode, 429)
            XCTAssertEqual((error as? AudiobookAPIFailure)?.detail, "Another MP3 export is in progress. Try again shortly.")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func test_mimeTypesCoverEPUBAndHTML() {
        XCTAssertEqual(AudiobookService.mimeType(forFileExtension: "epub"), "application/epub+zip")
        XCTAssertTrue(AudiobookService.mimeType(forFileExtension: "HTML").hasPrefix("text/html"))
        XCTAssertTrue(AudiobookService.mimeType(forFileExtension: "htm").hasPrefix("text/html"))
    }

    func test_apiFailure_readsDetailAndCodeAndIgnoresValidationLists() {
        let coded = AudiobookAPIFailure(statusCode: 422, body: Data(#"{"detail":"Paywall.","code":"paywalled"}"#.utf8))
        XCTAssertEqual(coded, AudiobookAPIFailure(statusCode: 422, detail: "Paywall.", code: "paywalled"))

        let validation = AudiobookAPIFailure(statusCode: 422, body: Data(#"{"detail":[{"loc":["body","url"]}]}"#.utf8))
        XCTAssertNil(validation.detail)
        XCTAssertNil(validation.code)

        XCTAssertEqual(AudiobookAPIFailure(statusCode: 500, body: Data("oops".utf8)), AudiobookAPIFailure(statusCode: 500))
    }
}

enum LibraryFixtures {
    static let estimate = """
    {"book_id":"0123456789abcdef0123456789abcdef","title":"An Article","author":"Jane Doe","page_count":2,
    "word_count_estimate":900,"estimated_processing_seconds":12,"estimated_audio_seconds":300,
    "estimated_cost_usd":0,"maximum_cost_usd":0,"estimated_token_count":1200,"is_image_only":false,
    "cost_warning":false,"duplicate_of_book_id":null,"duplicate_of_title":null}
    """

    static func transcript(includeWords: Bool) -> String {
        let words = includeWords
            ? #","words":[{"text":"Hello","start":0.0,"end":0.6},{"text":"world.","start":0.6,"end":1.5}]"#
            : ""
        return """
        {"book_id":"book","sections":[],"page_to_time":{"1":0.0},"total_audio_seconds":1.5,
        "pages":{"1":"Hello world."},"page_status":{"1":"done"},
        "lines":{"1":[{"paragraph":0,"text":"Hello world.","start":0.0,"end":1.5\(words)}]}}
        """
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Double] = []

    var values: [Double] {
        lock.withLock { recorded }
    }

    func append(_ value: Double) {
        lock.withLock { recorded.append(value) }
    }
}
