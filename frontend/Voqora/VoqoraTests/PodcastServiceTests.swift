import Foundation
@testable import Voqora
import XCTest

final class PodcastStubURLProtocol: URLProtocol {
    struct Reply {
        var statusCode = 200
        var body = Data()
        var failure: URLError?

        static func json(_ text: String, statusCode: Int = 200) -> Reply {
            Reply(statusCode: statusCode, body: Data(text.utf8))
        }
    }

    struct Recorded {
        let request: URLRequest
        let body: Data?

        var jsonBody: [String: Any]? {
            body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
    }

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var replies: [Reply] = []
        var recorded: [Recorded] = []
    }

    private static let state = State()

    static func reset(_ replies: [Reply]) {
        state.lock.withLock {
            state.replies = replies
            state.recorded = []
        }
    }

    static var recorded: [Recorded] {
        state.lock.withLock { state.recorded }
    }

    @MainActor
    static func makeService(token: String = "test-token") -> PodcastService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PodcastStubURLProtocol.self]
        let connection = BackendConnection(baseURL: URL(string: "http://127.0.0.1:9")!, token: token)
        return PodcastService(connection: connection, session: URLSession(configuration: configuration))
    }

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let body = request.httpBody ?? request.httpBodyStream.map(Self.readAll)
        let reply: Reply = Self.state.lock.withLock {
            Self.state.recorded.append(Recorded(request: request, body: body))
            return Self.state.replies.isEmpty ? Reply() : Self.state.replies.removeFirst()
        }
        if let failure = reply.failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        if let response = HTTPURLResponse(
            url: request.url ?? URL(fileURLWithPath: "/"),
            statusCode: reply.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ) {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readAll(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

@MainActor
final class PodcastServiceTests: XCTestCase {
    private let scriptJSON = """
    {"title":"Night Sky","speakers":[{"id":"host_1","name":"Avery","voice":"af_bella"},{"id":"host_2","name":"Jordan","voice":"am_adam"}],\
    "turns":[{"speaker_id":"host_1","text":"Look up.","pause_after_seconds":0.6,"section":"Opening"},{"speaker_id":"host_2","text":"Wow."}]}
    """

    private func request() -> PodcastScriptRequest {
        PodcastScriptRequest(
            source: .book(String(repeating: "b", count: 32)),
            style: .debate,
            minutes: 12,
            language: .englishUK,
            hosts: [PodcastHost(name: "Avery", voice: "bf_emma"), PodcastHost(name: "Jordan", voice: "bm_george")],
            title: "Stars"
        )
    }

    func test_writeScriptSendsBriefAndProviderHeaders() async throws {
        PodcastStubURLProtocol.reset([.json(#"{"script":\#(scriptJSON),"used_notes":true,"repaired":false,"source_truncated":true,"estimated_audio_seconds":42.5,"llm_provider":"openai","llm_model":"gpt"}"#)])
        let service = PodcastStubURLProtocol.makeService()
        let credential = LLMCredential(provider: .openai, apiKey: "sk-test", model: "gpt-x", serverURL: "")

        let result = try await service.writeScript(request(), credential: credential)

        let recorded = try XCTUnwrap(PodcastStubURLProtocol.recorded.first)
        XCTAssertEqual(recorded.request.httpMethod, "POST")
        XCTAssertEqual(recorded.request.url?.path, "/podcast/script")
        XCTAssertEqual(recorded.request.value(forHTTPHeaderField: "X-Voqora-IPC-Token"), "test-token")
        XCTAssertEqual(recorded.request.value(forHTTPHeaderField: "X-Voqora-LLM-Provider"), "openai")
        XCTAssertEqual(recorded.request.value(forHTTPHeaderField: "X-Voqora-LLM-Key"), "sk-test")
        XCTAssertEqual(recorded.request.value(forHTTPHeaderField: "X-Voqora-LLM-Model"), "gpt-x")
        XCTAssertEqual(PodcastService.scriptTimeout, recorded.request.timeoutInterval)
        let body = try XCTUnwrap(recorded.jsonBody)
        XCTAssertEqual((body["source"] as? [String: String])?["book_id"], String(repeating: "b", count: 32))
        XCTAssertEqual(body["style"] as? String, "debate")
        XCTAssertEqual(body["minutes"] as? Int, 12)
        XCTAssertEqual(body["language"] as? String, "en-gb")
        XCTAssertEqual(body["title"] as? String, "Stars")
        let hosts = try XCTUnwrap(body["hosts"] as? [[String: String]])
        XCTAssertEqual(hosts, [["name": "Avery", "voice": "bf_emma"], ["name": "Jordan", "voice": "bm_george"]])
        XCTAssertTrue(result.sourceTruncated)
        XCTAssertEqual(result.estimatedAudioSeconds, 42.5)
        XCTAssertEqual(result.script.turns.count, 2)
        XCTAssertEqual(result.script.turns[0].section, "Opening")
        XCTAssertEqual(result.script.turns[1].pauseAfterSeconds, PodcastLimits.defaultPauseSeconds)
    }

    func test_textSourceEncodesTextAndOmitsMissingTitle() async throws {
        PodcastStubURLProtocol.reset([.json("{}", statusCode: 500)])
        let service = PodcastStubURLProtocol.makeService()
        let request = PodcastScriptRequest(
            source: .text("Some notes"),
            style: .brief,
            minutes: 2,
            language: .englishUS,
            hosts: [PodcastHost(name: "Avery", voice: "af_bella")],
            title: nil
        )

        _ = try? await service.writeScript(request, credential: LLMCredential(provider: .ollama, apiKey: "", model: "", serverURL: ""))

        let body = try XCTUnwrap(PodcastStubURLProtocol.recorded.first?.jsonBody)
        XCTAssertEqual(body["source"] as? [String: String], ["text": "Some notes"])
        XCTAssertNil(body["title"])
        XCTAssertNil(PodcastStubURLProtocol.recorded.first?.request.value(forHTTPHeaderField: "X-Voqora-LLM-Key"))
    }

    func test_renderPostsScriptAndDecodesReceipt() async throws {
        let receipt = #"{"status":"queued","book_id":"\#(String(repeating: "c", count: 32))","kind":"podcast","title":"Night Sky","turn_count":2,"speakers":[{"id":"host_1","name":"Avery","voice":"af_bella"}],"estimated_audio_seconds":9.5}"#
        PodcastStubURLProtocol.reset([.json(receipt)])
        let service = PodcastStubURLProtocol.makeService()
        var script = StudioFixtures.script()
        script.turns[0].section = "Intro"

        let result = try await service.render(script)

        let recorded = try XCTUnwrap(PodcastStubURLProtocol.recorded.first)
        XCTAssertEqual(recorded.request.url?.path, "/podcast/render")
        XCTAssertNil(recorded.request.value(forHTTPHeaderField: "X-Voqora-LLM-Provider"))
        let sent = try XCTUnwrap(recorded.jsonBody?["script"] as? [String: Any])
        let turns = try XCTUnwrap(sent["turns"] as? [[String: Any]])
        XCTAssertEqual(turns[0]["speaker_id"] as? String, "host_1")
        XCTAssertEqual(turns[0]["section"] as? String, "Intro")
        XCTAssertEqual(turns[0]["pause_after_seconds"] as? Double, PodcastLimits.defaultPauseSeconds)
        XCTAssertNil(turns[1]["section"])
        XCTAssertNil(turns[0]["id"])
        XCTAssertEqual(result.bookID, String(repeating: "c", count: 32))
        XCTAssertEqual(result.turnCount, 2)
    }

    func test_scriptForPodcastUsesBookPath() async throws {
        PodcastStubURLProtocol.reset([.json(scriptJSON)])
        let service = PodcastStubURLProtocol.makeService()
        let id = String(repeating: "d", count: 32)

        let script = try await service.script(forPodcast: id)

        XCTAssertEqual(PodcastStubURLProtocol.recorded.first?.request.url?.path, "/podcast/\(id)/script")
        XCTAssertEqual(PodcastStubURLProtocol.recorded.first?.request.httpMethod, "GET")
        XCTAssertEqual(script.speakers.map(\.name), ["Avery", "Jordan"])
    }

    func test_voiceBlendsDecodeList() async throws {
        PodcastStubURLProtocol.reset([.json(#"{"blends":[{"id":"blend:1","name":"Warm","lang":"en-us","version":1,"components":[]}],"max_blends":50}"#)])
        let service = PodcastStubURLProtocol.makeService()

        let blends = try await service.voiceBlends()

        XCTAssertEqual(blends, [PodcastVoiceBlend(id: "blend:1", name: "Warm", lang: "en-us")])
    }

    func test_validationErrorsUseFirstMessage() async {
        PodcastStubURLProtocol.reset([.json(#"{"detail":[{"msg":"Value error, every host voice must speak the script language","loc":["body"]}]}"#, statusCode: 422)])
        let service = PodcastStubURLProtocol.makeService()

        await assertThrows(.invalid("Every host voice must speak the script language.")) {
            _ = try await service.writeScript(self.request(), credential: LLMCredential(provider: .ollama, apiKey: "", model: "", serverURL: ""))
        }
    }

    func test_statusCodesMapToFriendlyErrors() {
        let detail = Data(#"{"detail":"Voqora is already writing podcast scripts. Try again shortly."}"#.utf8)
        XCTAssertEqual(PodcastServiceError.from(statusCode: 429, data: detail), .busy("Voqora is already writing podcast scripts. Try again shortly."))
        XCTAssertEqual(
            PodcastServiceError.from(statusCode: 503, data: Data()),
            .providerUnavailable("The AI provider is temporarily unavailable. Try again later.")
        )
        XCTAssertEqual(PodcastServiceError.from(statusCode: 404, data: Data(#"{"detail":"Podcast not found."}"#.utf8)), .notFound("Podcast not found."))
        XCTAssertEqual(PodcastServiceError.from(statusCode: 500, data: Data()), .unexpected)
        XCTAssertEqual(
            PodcastServiceError.from(statusCode: 500, data: Data(#"{"detail":"Script writing failed. Please try again."}"#.utf8)),
            .rejected("Script writing failed. Please try again.")
        )
        if case .tooLarge = PodcastServiceError.from(statusCode: 413, data: Data()) {} else {
            XCTFail("413 should map to tooLarge")
        }
        if case .scriptFailed = PodcastServiceError.from(statusCode: 502, data: Data()) {} else {
            XCTFail("502 should map to scriptFailed")
        }
    }

    func test_transportFailureReportsEngineUnavailable() async {
        PodcastStubURLProtocol.reset([PodcastStubURLProtocol.Reply(failure: URLError(.cannotConnectToHost))])
        let service = PodcastStubURLProtocol.makeService()

        await assertThrows(.engineUnavailable) {
            _ = try await service.render(StudioFixtures.script())
        }
    }

    func test_missingConnectionReportsEngineUnavailable() async {
        let service = PodcastService(connection: unavailableConnection())

        await assertThrows(.engineUnavailable) {
            _ = try await service.voiceBlends()
        }
    }

    func test_malformedSuccessBodyIsInvalidResponse() async {
        PodcastStubURLProtocol.reset([.json(#"{"unexpected":true}"#)])
        let service = PodcastStubURLProtocol.makeService()

        await assertThrows(.invalidResponse) {
            _ = try await service.render(StudioFixtures.script())
        }
    }

    func test_previewWAVHeaderGetsRealSizes() throws {
        var header = Data("RIFF".utf8) + Data([0xFF, 0xFF, 0xFF, 0xFF]) + Data("WAVE".utf8)
        header += Data("fmt ".utf8) + Data(repeating: 0, count: 20)
        header += Data("data".utf8) + Data([0xFF, 0xFF, 0xFF, 0xFF])
        let wav = header + Data(repeating: 1, count: 10)

        let fixed = try XCTUnwrap(PodcastPreviewAudio.finalizedWAV(wav))

        XCTAssertEqual(Array(fixed[4 ..< 8]), [46, 0, 0, 0])
        XCTAssertEqual(Array(fixed[40 ..< 44]), [10, 0, 0, 0])
        XCTAssertNil(PodcastPreviewAudio.finalizedWAV(Data("not audio".utf8)))
    }

    private func unavailableConnection() -> BackendConnection {
        let connection = BackendConnection(baseURL: URL(string: "http://127.0.0.1:9")!, token: "t")
        connection.invalidate()
        return connection
    }

    private func assertThrows(
        _ expected: PodcastServiceError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? PodcastServiceError, expected, file: file, line: line)
        }
    }
}
