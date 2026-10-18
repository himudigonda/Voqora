import Foundation
@testable import Voqora

enum TestLinks {
    static func url(_ string: String) -> URL {
        guard let url = URL(string: string) else {
            preconditionFailure("Invalid test URL: \(string)")
        }
        return url
    }
}

final class LibraryStubURLProtocol: URLProtocol {
    struct Reply: Sendable {
        let status: Int
        var headers: [String: String] = [:]
        var body = Data()

        static func json(_ status: Int, _ text: String) -> Reply {
            Reply(status: status, headers: ["Content-Type": "application/json"], body: Data(text.utf8))
        }
    }

    struct Recorded: Sendable {
        let method: String
        let path: String
        let query: [String: String]
        let headers: [String: String]
        let body: Data
    }

    private static let lock = NSLock()
    private static var handler: (@Sendable (Recorded) -> Reply)?
    private static var log: [Recorded] = []

    static func install(_ handler: @escaping @Sendable (Recorded) -> Reply) {
        lock.withLock {
            self.handler = handler
            log = []
        }
    }

    static func reset() {
        lock.withLock {
            handler = nil
            log = []
        }
    }

    static var requests: [Recorded] {
        lock.withLock { log }
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LibraryStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    @MainActor
    static func makeService() -> AudiobookService {
        AudiobookService(
            connection: BackendConnection(baseURL: TestLinks.url("http://127.0.0.1:9"), token: "stub-token"),
            session: makeSession(),
            eventSession: makeSession()
        )
    }

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let recorded = Self.record(request)
        let reply = Self.lock.withLock { () -> Reply in
            Self.log.append(recorded)
            return Self.handler?(recorded) ?? Reply(status: 500)
        }
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !reply.body.isEmpty {
            client?.urlProtocol(self, didLoad: reply.body)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func record(_ request: URLRequest) -> Recorded {
        let components = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] {
            query[item.name] = item.value ?? ""
        }
        return Recorded(
            method: request.httpMethod ?? "GET",
            path: components?.path ?? "",
            query: query,
            headers: request.allHTTPHeaderFields ?? [:],
            body: request.httpBody ?? readStream(request.httpBodyStream)
        )
    }

    private static func readStream(_ stream: InputStream?) -> Data {
        guard let stream else { return Data() }
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
