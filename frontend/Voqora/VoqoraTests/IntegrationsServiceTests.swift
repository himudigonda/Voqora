import Foundation
@testable import Voqora
import XCTest

@MainActor
final class IntegrationsServiceTests: XCTestCase {
    private var service: IntegrationsService!

    override func setUp() {
        super.setUp()
        HTTPStubProtocol.reset()
        let connection = BackendConnection(baseURL: URL(string: "http://127.0.0.1:9")!, token: "ipc-token")
        service = IntegrationsService(connection: connection, session: HTTPStubProtocol.makeSession())
    }

    override func tearDown() {
        HTTPStubProtocol.reset()
        service = nil
        super.tearDown()
    }

    func test_status_sendsIPCTokenAndDecodesResponse() async throws {
        HTTPStubProtocol.install { _ in HTTPStubReply(statusCode: 200, json: #"{"enabled":true,"port":6000,"running":true}"#) }

        let status = try await service.status()

        XCTAssertEqual(status, LocalAPIStatus(enabled: true, port: 6000, running: true, errorCode: nil))
        let request = try XCTUnwrap(HTTPStubProtocol.requests.first)
        XCTAssertEqual(request.url?.path, "/integrations/local-api")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Voqora-IPC-Token"), "ipc-token")
    }

    func test_apply_postsConfigurationAsJSON() async throws {
        HTTPStubProtocol.install { _ in HTTPStubReply(statusCode: 200, json: #"{"enabled":true,"port":6000,"running":true}"#) }

        _ = try await service.apply(.enabled(port: 6000, apiKey: String(repeating: "k", count: 40)))

        let request = try XCTUnwrap(HTTPStubProtocol.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: HTTPStubProtocol.body(of: request)) as? [String: Any])
        XCTAssertEqual(body["port"] as? Int, 6000)
        XCTAssertEqual(body["api_key"] as? String, String(repeating: "k", count: 40))
        XCTAssertEqual(body["enabled"] as? Bool, true)
    }

    func test_apply_returnsStatusForPortConflicts() async throws {
        HTTPStubProtocol.install { _ in
            HTTPStubReply(statusCode: 409, json: #"{"enabled":true,"port":6000,"running":false,"error":"taken","error_code":"port_in_use"}"#)
        }

        let status = try await service.apply(.enabled(port: 6000, apiKey: String(repeating: "k", count: 40)))

        XCTAssertEqual(status.failure, .portInUse)
        XCTAssertFalse(status.running)
    }

    func test_apply_mapsValidationErrorsWithoutExposingTheBody() async {
        HTTPStubProtocol.install { _ in HTTPStubReply(statusCode: 422, json: #"{"detail":[{"input":"secret-key"}]}"#) }

        do {
            _ = try await service.apply(.enabled(port: 6000, apiKey: "secret-key"))
            XCTFail("Expected a rejection")
        } catch {
            XCTAssertEqual(error as? IntegrationsServiceError, .rejectedSettings)
            XCTAssertFalse(error.localizedDescription.contains("secret-key"))
        }
    }

    func test_transportFailuresMeanTheEngineIsUnavailable() async {
        HTTPStubProtocol.install { _ in throw URLError(.cannotConnectToHost) }

        do {
            _ = try await service.status()
            XCTFail("Expected a failure")
        } catch {
            XCTAssertEqual(error as? IntegrationsServiceError, .engineUnavailable)
        }
    }

    func test_events_streamsParsedFrames() async throws {
        let frames = """
        data: {"type":"ready"}

        : keep-alive

        data: {"type":"speak","id":"1","text":"Hello","voice":null}

        data: {"type":"stop","id":"2"}


        """
        HTTPStubProtocol.install { _ in HTTPStubReply(statusCode: 200, body: Data(frames.utf8), headers: ["Content-Type": "text/event-stream"]) }

        var received: [IntegrationEvent] = []
        for try await event in service.events() {
            received.append(event)
        }

        XCTAssertEqual(received, [
            .ready,
            .speak(RelaySpeakCommand(id: "1", text: "Hello", voice: nil, client: nil)),
            .stop(id: "2"),
        ])
        XCTAssertEqual(HTTPStubProtocol.requests.first?.value(forHTTPHeaderField: "Accept"), "text/event-stream")
        XCTAssertEqual(HTTPStubProtocol.requests.first?.url?.path, "/integrations/events")
    }

    func test_events_failsWhenTheStreamIsRejected() async {
        HTTPStubProtocol.install { _ in HTTPStubReply(statusCode: 403) }

        do {
            for try await _ in service.events() {}
            XCTFail("Expected a failure")
        } catch {
            XCTAssertEqual(error as? IntegrationsServiceError, .eventStreamRejected(403))
        }
    }
}
