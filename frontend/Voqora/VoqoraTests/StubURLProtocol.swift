import Foundation
@testable import Voqora

final class StubURLProtocol: URLProtocol {
    struct Reply {
        var statusCode = 200
        var body = Data()
        var failure: URLError?

        static func json(_ text: String, statusCode: Int = 200) -> Reply {
            Reply(statusCode: statusCode, body: Data(text.utf8))
        }

        static func transportFailure() -> Reply {
            Reply(failure: URLError(.cannotConnectToHost))
        }
    }

    struct Recorded {
        let request: URLRequest
        let body: Data?

        var method: String? {
            request.httpMethod
        }

        var path: String? {
            request.url?.path
        }

        var query: String? {
            request.url?.query
        }

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

    static func reset(replies: [Reply]) {
        state.lock.withLock {
            state.replies = replies
            state.recorded = []
        }
    }

    static var recorded: [Recorded] {
        state.lock.withLock { state.recorded }
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    @MainActor
    static func makeClient(token: String = "test-token") -> BackendAPIClient {
        let connection = BackendConnection(baseURL: URL(string: "http://127.0.0.1:9")!, token: token)
        return BackendAPIClient(connection: connection, session: makeSession())
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
        let response = HTTPURLResponse(
            url: request.url ?? URL(fileURLWithPath: "/"),
            statusCode: reply.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )
        if let response {
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
