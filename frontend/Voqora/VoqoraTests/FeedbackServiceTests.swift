import Foundation
@testable import Voqora
import XCTest

final class FeedbackServiceTests: XCTestCase {
    private func service(status: Int, capture: @escaping (URLRequest) -> Void = { _ in }) -> FeedbackService {
        var service = FeedbackService(anonID: { "4d37a3eb-71be-45ea-a9f4-e9bd8c3aae23" })
        service.appVersion = "1.2.6"
        service.osVersion = "15.4.1"
        service.sendRequest = { request in
            capture(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data(), response)
        }
        return service
    }

    private func body(_ request: URLRequest?) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request?.httpBody)) as? [String: Any])
    }

    func testSendsTrimmedMessageEmailAndVersions() async throws {
        var sent: URLRequest?
        try await service(status: 200) { sent = $0 }
            .send(kind: .idea, message: "  More voices  ", email: " Reader@Example.com ", includeVersions: true)

        XCTAssertEqual(sent?.url, FeedbackService.endpoint)
        XCTAssertEqual(sent?.httpMethod, "POST")
        let json = try body(sent)
        XCTAssertEqual(json["kind"] as? String, "idea")
        XCTAssertEqual(json["message"] as? String, "More voices")
        XCTAssertEqual(json["email"] as? String, "reader@example.com")
        XCTAssertEqual(json["app_version"] as? String, "1.2.6")
        XCTAssertEqual(json["os_version"] as? String, "15.4.1")
    }

    func testOmitsEmailAndVersionsWhenNotGiven() async throws {
        var sent: URLRequest?
        try await service(status: 200) { sent = $0 }
            .send(kind: .hello, message: "Hi", email: "", includeVersions: false)

        let json = try body(sent)
        XCTAssertEqual(json["kind"] as? String, "hello")
        XCTAssertNil(json["email"])
        XCTAssertNil(json["app_version"])
        XCTAssertNil(json["os_version"])
    }

    func testRejectsInvalidInputWithoutSending() async {
        var sends = 0
        let svc = service(status: 200) { _ in sends += 1 }
        let cases: [(String, String, FeedbackService.SendError)] = [
            ("   ", "", .empty),
            (String(repeating: "a", count: FeedbackService.maxLength + 1), "", .tooLong),
            ("Hi", "not-an-email", .invalidEmail),
            ("Hi", "a@b.c", .invalidEmail),
            ("Hi", "a@b..com", .invalidEmail),
            ("Hi", "a@x_y.com", .invalidEmail),
            ("Hi", "\u{00FC}@example.com", .invalidEmail),
            ("Hi", "a,b@example.com", .invalidEmail),
            ("Hi", String(repeating: "a", count: 65) + "@example.com", .invalidEmail),
            (String(repeating: "\u{1F44D}", count: 2501), "", .tooLong),
            ("\u{FEFF}", "", .empty),
        ]
        for (message, email, expected) in cases {
            do {
                try await svc.send(kind: .issue, message: message, email: email, includeVersions: true)
                XCTFail("expected \(expected)")
            } catch {
                XCTAssertEqual(error as? FeedbackService.SendError, expected)
            }
        }
        XCTAssertEqual(sends, 0)
    }

    func testAcceptsMessagesAtTheServerLimit() async throws {
        var sends = 0
        let svc = service(status: 200) { _ in sends += 1 }
        try await svc.send(kind: .idea, message: String(repeating: "\u{1F44D}", count: 2500), email: "first.last+tag@mail.example.co", includeVersions: false)
        XCTAssertEqual(sends, 1)
    }

    func testMapsServerStatuses() async {
        let cases: [(Int, FeedbackService.SendError)] = [(429, .rateLimited), (400, .rejected), (403, .rejected), (500, .failed)]
        for (status, expected) in cases {
            do {
                try await service(status: status).send(kind: .issue, message: "x", email: "", includeVersions: false)
                XCTFail("expected \(expected)")
            } catch {
                XCTAssertEqual(error as? FeedbackService.SendError, expected)
            }
        }
    }
}
