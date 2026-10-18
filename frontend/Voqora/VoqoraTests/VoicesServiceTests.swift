import Foundation
@testable import Voqora
import XCTest

@MainActor
final class VoicesServiceTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.reset(replies: [])
        super.tearDown()
    }

    func test_listBlendsSendsTheIPCTokenAndDecodes() async throws {
        StubURLProtocol.reset(replies: [.json(#"{"blends":[\#(VoiceBlendModelTests.blendJSON)],"max_blends":50}"#)])
        let service = VoiceBlendService(client: StubURLProtocol.makeClient(token: "secret"))

        let list = try await service.list()

        let recorded = try XCTUnwrap(StubURLProtocol.recorded.first)
        XCTAssertEqual(recorded.method, "GET")
        XCTAssertEqual(recorded.path, "/voices/blends")
        XCTAssertEqual(recorded.request.value(forHTTPHeaderField: "X-Voqora-IPC-Token"), "secret")
        XCTAssertEqual(list.blends.first?.name, "Warm Narrator")
    }

    func test_createBlendPostsNameAndComponents() async throws {
        StubURLProtocol.reset(replies: [.json(VoiceBlendModelTests.blendJSON, statusCode: 201)])
        let service = VoiceBlendService(client: StubURLProtocol.makeClient())
        let draft = VoiceBlendDraft(name: "Warm Narrator")

        let blend = try await service.create(draft.request)

        let recorded = try XCTUnwrap(StubURLProtocol.recorded.first)
        XCTAssertEqual(recorded.method, "POST")
        XCTAssertEqual(recorded.request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(recorded.jsonBody?["name"] as? String, "Warm Narrator")
        XCTAssertEqual((recorded.jsonBody?["components"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual(blend.id, VoiceBlendModelTests.blendID)
    }

    func test_updateAndDeleteTargetTheBlendPath() async throws {
        StubURLProtocol.reset(replies: [
            .json(VoiceBlendModelTests.blendJSON),
            .json(#"{"status":"deleted","id":"\#(VoiceBlendModelTests.blendID)"}"#),
        ])
        let service = VoiceBlendService(client: StubURLProtocol.makeClient())

        _ = try await service.update(id: VoiceBlendModelTests.blendID, with: VoiceBlendDraft(name: "A").request)
        try await service.delete(id: VoiceBlendModelTests.blendID)

        let recorded = StubURLProtocol.recorded
        XCTAssertEqual(recorded.map(\.method), ["PUT", "DELETE"])
        XCTAssertTrue(recorded.allSatisfy { $0.request.url?.absoluteString.hasSuffix("3d4e5f") == true })
    }

    func test_malformedBlendIDNeverReachesTheEngine() async {
        StubURLProtocol.reset(replies: [])
        let service = VoiceBlendService(client: StubURLProtocol.makeClient())

        do {
            try await service.delete(id: "../audiobook")
            XCTFail("A malformed id must be rejected before any request")
        } catch {
            XCTAssertEqual((error as? BackendAPIError)?.statusCode, 400)
        }
        XCTAssertTrue(StubURLProtocol.recorded.isEmpty)
    }

    func test_validationErrorsSurfaceTheBackendMessage() async {
        let detail = #"{"detail":[{"loc":["body","name"],"msg":"Value error, name must be 1 to 40 characters","type":"value_error"}]}"#
        StubURLProtocol.reset(replies: [.json(detail, statusCode: 422)])
        let service = VoiceBlendService(client: StubURLProtocol.makeClient())

        do {
            _ = try await service.create(VoiceBlendDraft(name: "A").request)
            XCTFail("Expected a validation error")
        } catch {
            XCTAssertEqual(error as? BackendAPIError, .rejected(statusCode: 422, message: "Name must be 1 to 40 characters."))
            XCTAssertEqual(error.localizedDescription, "Name must be 1 to 40 characters.")
        }
    }

    func test_limitConflictUsesTheBackendCopy() async {
        StubURLProtocol.reset(replies: [.json(#"{"detail":"You can save up to 50 voice blends."}"#, statusCode: 409)])
        let service = VoiceBlendService(client: StubURLProtocol.makeClient())

        do {
            _ = try await service.create(VoiceBlendDraft(name: "A").request)
            XCTFail("Expected a conflict")
        } catch {
            XCTAssertEqual(error.localizedDescription, "You can save up to 50 voice blends.")
        }
    }

    func test_transportFailureMapsToUnreachable() async {
        StubURLProtocol.reset(replies: [.transportFailure()])
        let service = VoiceBlendService(client: StubURLProtocol.makeClient())

        do {
            _ = try await service.list()
            XCTFail("Expected a transport error")
        } catch {
            XCTAssertEqual(error as? BackendAPIError, .unreachable)
        }
    }

    func test_undecodableBodyMapsToInvalidResponse() async {
        StubURLProtocol.reset(replies: [.json("{}")])
        let service = VoiceBlendService(client: StubURLProtocol.makeClient())

        do {
            _ = try await service.list()
            XCTFail("Expected a decoding error")
        } catch {
            XCTAssertEqual(error as? BackendAPIError, .invalidResponse)
        }
    }

    func test_missingConnectionMapsToEngineUnavailable() async {
        let service = VoiceBlendService(client: BackendAPIClient(connection: unconfiguredConnection(), session: StubURLProtocol.makeSession()))

        do {
            _ = try await service.list()
            XCTFail("Expected the engine to be unavailable")
        } catch {
            XCTAssertEqual(error as? BackendAPIError, .engineUnavailable)
        }
    }

    func test_pronunciationListPassesTheScopeQuery() async throws {
        let json = #"{"version":3,"max_entries":500,"entries":[\#(PronunciationModelTests.entryJSON())]}"#
        StubURLProtocol.reset(replies: [.json(json), .json(json)])
        let service = PronunciationService(client: StubURLProtocol.makeClient())

        let all = try await service.list(scope: nil)
        _ = try await service.list(scope: .book(PronunciationModelTests.bookID))

        let recorded = StubURLProtocol.recorded
        XCTAssertEqual(recorded.map(\.path), ["/pronunciations", "/pronunciations"])
        XCTAssertNil(recorded[0].query)
        XCTAssertEqual(recorded[1].query, "scope=\(PronunciationModelTests.bookID)")
        XCTAssertEqual(all.version, 3)
        XCTAssertEqual(all.entries.first?.replacement, "sequel")
    }

    func test_pronunciationTestPostsTextAndBook() async throws {
        let reply = #"{"text":"SQL rocks","spoken":"sequel rocks","replacements":1,"version":3}"#
        StubURLProtocol.reset(replies: [.json(reply)])
        let service = PronunciationService(client: StubURLProtocol.makeClient())

        let result = try await service.test(text: "SQL rocks", bookID: PronunciationModelTests.bookID)

        let recorded = try XCTUnwrap(StubURLProtocol.recorded.first)
        XCTAssertEqual(recorded.path, "/pronunciations/test")
        XCTAssertEqual(recorded.jsonBody?["text"] as? String, "SQL rocks")
        XCTAssertEqual(recorded.jsonBody?["book_id"] as? String, PronunciationModelTests.bookID)
        XCTAssertEqual(result.spoken, "sequel rocks")
        XCTAssertEqual(result.replacements, 1)
    }

    func test_pronunciationUpdateAndDeleteUseTheEntryPath() async throws {
        StubURLProtocol.reset(replies: [
            .json(PronunciationModelTests.entryJSON()),
            .json(#"{"status":"deleted","id":"\#(PronunciationModelTests.entryID)"}"#),
        ])
        let service = PronunciationService(client: StubURLProtocol.makeClient())

        _ = try await service.update(id: PronunciationModelTests.entryID, with: PronunciationDraft(match: "SQL").request)
        try await service.delete(id: PronunciationModelTests.entryID)

        let recorded = StubURLProtocol.recorded
        XCTAssertEqual(recorded.map(\.method), ["PUT", "DELETE"])
        XCTAssertEqual(recorded.map(\.path), [
            "/pronunciations/\(PronunciationModelTests.entryID)",
            "/pronunciations/\(PronunciationModelTests.entryID)",
        ])
    }

    private func unconfiguredConnection() -> BackendConnection {
        let connection = BackendConnection(baseURL: URL(string: "http://127.0.0.1:9")!, token: "unused")
        connection.invalidate()
        return connection
    }
}
