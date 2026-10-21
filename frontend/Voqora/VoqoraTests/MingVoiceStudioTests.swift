import Foundation
@testable import Voqora
import XCTest

@MainActor
final class MingVoiceStudioTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.reset(replies: [])
        super.tearDown()
    }

    private let voiceJSON = #"{"id":"ming:custom:ab12","name":"My Narrator","gender":"female","lang":"en","custom":true}"#

    func test_designPostsTheRequestAndDecodesTheVoice() async throws {
        StubURLProtocol.reset(replies: [.json(voiceJSON, statusCode: 201)])
        let service = MingVoiceService(client: StubURLProtocol.makeClient(token: "secret"))
        let request = MingVoiceDesignRequest(name: "My Narrator", description: "Warm baritone", language: "en", sampleText: nil)

        let voice = try await service.design(request)

        let recorded = try XCTUnwrap(StubURLProtocol.recorded.first)
        XCTAssertEqual(recorded.method, "POST")
        XCTAssertEqual(recorded.path, "/engine/ming/voices/design")
        XCTAssertEqual(recorded.request.value(forHTTPHeaderField: "X-Voqora-IPC-Token"), "secret")
        XCTAssertEqual(recorded.jsonBody?["name"] as? String, "My Narrator")
        XCTAssertEqual(recorded.jsonBody?["description"] as? String, "Warm baritone")
        XCTAssertEqual(recorded.jsonBody?["language"] as? String, "en")
        XCTAssertNil(recorded.jsonBody?["sample_text"])
        XCTAssertEqual(voice.id, "ming:custom:ab12")
        XCTAssertTrue(voice.custom)
    }

    func test_designAcceptsAVoiceWrappedInAnEnvelope() async throws {
        StubURLProtocol.reset(replies: [.json(#"{"voice":\#(voiceJSON)}"#)])
        let service = MingVoiceService(client: StubURLProtocol.makeClient())

        let voice = try await service.design(MingVoiceDesignRequest(name: "A", description: "B", language: "en", sampleText: "Hi"))

        XCTAssertEqual(voice.name, "My Narrator")
        XCTAssertEqual(StubURLProtocol.recorded.first?.jsonBody?["sample_text"] as? String, "Hi")
    }

    func test_clonePostsMultipartWithTheAudioFile() async throws {
        StubURLProtocol.reset(replies: [.json(voiceJSON)])
        let service = MingVoiceService(client: StubURLProtocol.makeClient())
        let request = MingVoiceCloneRequest(
            name: "Me",
            language: "en",
            transcript: "Hello there",
            filename: "me.wav",
            mimeType: "audio/wav",
            audio: Data("RIFFdata".utf8)
        )

        _ = try await service.clone(request)

        let recorded = try XCTUnwrap(StubURLProtocol.recorded.first)
        XCTAssertEqual(recorded.path, "/engine/ming/voices/clone")
        let contentType = try XCTUnwrap(recorded.request.value(forHTTPHeaderField: "Content-Type"))
        XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="))
        let body = try XCTUnwrap(recorded.body.flatMap { String(data: $0, encoding: .utf8) })
        for fragment in ["name=\"name\"", "Me", "name=\"language\"", "name=\"transcript\"", "Hello there", "name=\"file\"; filename=\"me.wav\"", "Content-Type: audio/wav", "RIFFdata"] {
            XCTAssertTrue(body.contains(fragment), fragment)
        }
        XCTAssertTrue(body.hasSuffix("--\r\n"))
    }

    func test_deleteAndSampleTargetTheEncodedVoicePath() async throws {
        StubURLProtocol.reset(replies: [.json("{}"), StubURLProtocol.Reply(body: Data("wav".utf8))])
        let service = MingVoiceService(client: StubURLProtocol.makeClient())

        try await service.delete(id: "ming:custom:ab12")
        let audio = try await service.sample(id: "ming:custom:ab12")

        let recorded = StubURLProtocol.recorded
        XCTAssertEqual(recorded.map(\.method), ["DELETE", "GET"])
        XCTAssertEqual(recorded.map(\.path), ["/engine/ming/voices/ming:custom:ab12", "/engine/ming/voices/ming:custom:ab12/sample"])
        XCTAssertEqual(audio, Data("wav".utf8))
    }

    func test_voicePathsCarryTheRawIdSoTheConnectionEncodesItOnce() {
        XCTAssertEqual(MingVoiceService.path(forVoice: "ming:灵小安"), "engine/ming/voices/ming:灵小安")
        XCTAssertEqual(MingVoiceService.path(forVoice: "ming:custom:abc", action: "sample"), "engine/ming/voices/ming:custom:abc/sample")
    }

    func test_nonAsciiVoiceIdsAreEncodedExactlyOnceInTheFinalURL() async throws {
        StubURLProtocol.reset(replies: [.json("{}"), StubURLProtocol.Reply(body: Data("wav".utf8))])
        let service = MingVoiceService(client: StubURLProtocol.makeClient())

        try await service.delete(id: "ming:灵小安")
        _ = try await service.sample(id: "ming:灵小安")

        let urls = StubURLProtocol.recorded.compactMap { $0.request.url?.absoluteString }
        XCTAssertEqual(urls, [
            "http://127.0.0.1:9/engine/ming/voices/ming:%E7%81%B5%E5%B0%8F%E5%AE%89",
            "http://127.0.0.1:9/engine/ming/voices/ming:%E7%81%B5%E5%B0%8F%E5%AE%89/sample",
        ])
        XCTAssertFalse(urls.contains { $0.contains("%25") })
    }

    func test_asciiCustomVoiceIdsEncodeExactlyOnceInTheFinalURL() async throws {
        StubURLProtocol.reset(replies: [.json("{}")])
        let service = MingVoiceService(client: StubURLProtocol.makeClient())

        try await service.delete(id: "ming:custom:abc")

        XCTAssertEqual(StubURLProtocol.recorded.first?.request.url?.absoluteString, "http://127.0.0.1:9/engine/ming/voices/ming:custom:abc")
    }

    func test_rejectedDesignSurfacesTheServerMessage() async {
        StubURLProtocol.reset(replies: [.json(#"{"detail":"description is too short"}"#, statusCode: 422)])
        let service = MingVoiceService(client: StubURLProtocol.makeClient())

        do {
            _ = try await service.design(MingVoiceDesignRequest(name: "A", description: "B", language: "en", sampleText: nil))
            XCTFail("expected a rejection")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Description is too short.")
        }
    }

    func test_designDraftNeedsANameAndADescription() {
        var draft = MingDesignDraft()
        XCTAssertFalse(draft.isValid)
        draft.name = "  Narrator "
        XCTAssertFalse(draft.isValid)
        draft.description = "Warm"
        XCTAssertTrue(draft.isValid)
        XCTAssertEqual(draft.request.name, "Narrator")
        XCTAssertNil(draft.request.sampleText)
        draft.sampleText = " Hello "
        XCTAssertEqual(draft.request.sampleText, "Hello")
    }

    func test_cloneDraftRequiresTheRightsCheckbox() {
        var draft = MingCloneDraft(name: "Me", language: "en", transcript: "Hello", fileURL: URL(fileURLWithPath: "/tmp/me.wav"))
        XCTAssertFalse(draft.isValid)
        draft.hasRights = true
        XCTAssertTrue(draft.isValid)
        draft.fileURL = nil
        XCTAssertFalse(draft.isValid)
    }

    func test_audioTypesCoverTheSupportedFormats() {
        XCTAssertEqual(MingVoiceAudio.mimeType(forExtension: "WAV"), "audio/wav")
        XCTAssertEqual(MingVoiceAudio.mimeType(forExtension: "mp3"), "audio/mpeg")
        XCTAssertEqual(MingVoiceAudio.mimeType(forExtension: "flac"), "audio/flac")
        XCTAssertEqual(MingVoiceAudio.mimeType(forExtension: "aif"), "audio/aiff")
        XCTAssertGreaterThanOrEqual(MingVoiceAudio.importTypes.count, 4)
    }

    func test_languageOptionsFallBackToTheDefaultSet() {
        XCTAssertEqual(MingVoiceLanguage.options(from: nil), MingVoiceLanguage.fallback)
        XCTAssertEqual(MingVoiceLanguage.options(from: SpeechEngineTests.ming()), ["en", "zh"])
    }

    func test_aDesignInFlightBlocksDuplicateSubmitsAndSurvivesWithTheModel() async {
        let service = GatedMingService()
        let store = SpeechEngineStore(service: IdleEngineService(), directory: EngineVoiceDirectory(defaults: UserDefaults(suiteName: "MingStudioGate-\(UUID().uuidString)") ?? .standard))
        let model = MingVoiceStudioModel(service: service, engines: store)
        model.designDraft = MingDesignDraft(name: "A", language: "en", description: "Warm", sampleText: "")

        let first = Task { await model.submitDesign() }
        await service.waitUntilStarted()
        XCTAssertEqual(model.work, .designing)
        await model.submitDesign()
        service.release()
        await first.value

        XCTAssertEqual(service.designCalls, 1)
        XCTAssertNil(model.work)
        XCTAssertEqual(model.lastCreated?.id, "ming:custom:x")
        model.clearResult()
        XCTAssertNil(model.lastCreated)
    }
}

@MainActor
private final class GatedMingService: MingVoiceServing {
    private(set) var designCalls = 0
    private var started: CheckedContinuation<Void, Never>?
    private var gate: CheckedContinuation<Void, Never>?
    private var hasStarted = false

    func waitUntilStarted() async {
        if hasStarted {
            return
        }
        await withCheckedContinuation { started = $0 }
    }

    func release() {
        gate?.resume()
        gate = nil
    }

    func design(_: MingVoiceDesignRequest) async throws -> SpeechEngineVoice {
        designCalls += 1
        hasStarted = true
        started?.resume()
        started = nil
        await withCheckedContinuation { gate = $0 }
        return SpeechEngineVoice(id: "ming:custom:x", name: "A", gender: "", custom: true)
    }

    func clone(_: MingVoiceCloneRequest) async throws -> SpeechEngineVoice {
        throw CancellationError()
    }

    func delete(id _: String) async throws {}

    func sample(id _: String) async throws -> Data {
        Data()
    }
}

@MainActor
private final class IdleEngineService: SpeechEngineServing {
    func list() async throws -> [SpeechEngine] {
        []
    }

    func install(id _: String) async throws -> SpeechEngine {
        throw CancellationError()
    }

    func uninstall(id _: String) async throws -> SpeechEngine {
        throw CancellationError()
    }
}
