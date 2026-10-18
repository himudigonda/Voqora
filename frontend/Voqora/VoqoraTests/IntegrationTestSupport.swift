import Foundation
@testable import Voqora
import XCTest

struct HTTPStubReply: Sendable {
    let statusCode: Int
    let body: Data
    let headers: [String: String]

    init(statusCode: Int, body: Data = Data(), headers: [String: String] = ["Content-Type": "application/json"]) {
        self.statusCode = statusCode
        self.body = body
        self.headers = headers
    }

    init(statusCode: Int, json: String) {
        self.init(statusCode: statusCode, body: Data(json.utf8))
    }
}

final class HTTPStubProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> HTTPStubReply

    private static let lock = NSLock()
    private nonisolated(unsafe) static var handler: Handler?
    private nonisolated(unsafe) static var recorded: [URLRequest] = []

    static func install(_ handler: @escaping Handler) {
        lock.withLock {
            self.handler = handler
            recorded = []
        }
    }

    static func reset() {
        lock.withLock {
            handler = nil
            recorded = []
        }
    }

    static var requests: [URLRequest] {
        lock.withLock { recorded }
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HTTPStubProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else { return Data() }
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

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let handler = Self.lock.withLock { () -> Handler? in
            Self.recorded.append(request)
            return Self.handler
        }
        guard let handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let reply = try handler(request)
            guard let response = HTTPURLResponse(url: url, statusCode: reply.statusCode, httpVersion: "HTTP/1.1", headerFields: reply.headers) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class MemorySecretStore: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]
    var failsWrites = false

    func value(for key: KeychainKey) -> String? {
        read(key)
    }

    func seed(_ value: String, for key: KeychainKey) {
        lock.withLock { storage[key.rawValue] = value }
    }

    var store: SecretStore {
        SecretStore(
            get: { key in self.read(key) },
            set: { value, key in self.write(value, for: key) },
            delete: { key in
                self.remove(key)
                return true
            }
        )
    }

    private func read(_ key: KeychainKey) -> String? {
        lock.withLock { storage[key.rawValue] }
    }

    private func write(_ value: String, for key: KeychainKey) -> Bool {
        lock.withLock {
            guard !failsWrites else { return false }
            storage[key.rawValue] = value
            return true
        }
    }

    private func remove(_ key: KeychainKey) {
        _ = lock.withLock { storage.removeValue(forKey: key.rawValue) }
    }
}

final class TestDefaults {
    let suiteName = "VoqoraIntegrationTests.\(UUID().uuidString)"
    let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: suiteName) ?? .standard
    }

    func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

@MainActor
func yieldUntil(_ condition: @MainActor () -> Bool, iterations: Int = 2000) async {
    var remaining = iterations
    while !condition(), remaining > 0 {
        remaining -= 1
        await Task.yield()
    }
}

@MainActor
func makeTestAudiobook(id: String = "book-1", status: String = "done") -> Audiobook {
    Audiobook(
        bookID: id,
        title: "Test Book.pdf",
        createdAt: "2026-01-01T00:00:00Z",
        pageCount: 10,
        status: status,
        phaseProgress: PhaseProgress(pageDone: 10, pageTotal: 10),
        sections: [],
        pageToTime: [:],
        totalAudioSeconds: 600,
        failedPages: [],
        estimated: nil,
        actual: nil,
        engine: "kokoro",
        voice: "af_bella",
        speed: 1.0,
        usesLLMCleanup: false,
        budget: nil,
        error: nil
    )
}
