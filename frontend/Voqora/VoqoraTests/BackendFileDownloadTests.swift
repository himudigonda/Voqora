import Foundation
@testable import Voqora
import XCTest

private final class ChunkedDownloadProtocol: URLProtocol {
    static let chunkCount = 8
    static let chunkSize = 64 * 1024
    private static let lock = NSLock()
    private static var status = 200

    static func serve(status: Int) {
        lock.withLock { self.status = status }
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChunkedDownloadProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else { return }
        let status = Self.lock.withLock { Self.status }
        let total = Self.chunkCount * Self.chunkSize
        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": "\(total)"]
        )
        guard let response else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let chunk = Data(repeating: 7, count: Self.chunkSize)
        DispatchQueue.global().async { [self] in
            for _ in 0 ..< Self.chunkCount {
                client?.urlProtocol(self, didLoad: chunk)
                Thread.sleep(forTimeInterval: 0.02)
            }
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []

    var values: [Double] {
        lock.withLock { storage }
    }

    func record(_ value: Double) {
        lock.withLock { storage.append(value) }
    }
}

final class BackendFileDownloadTests: XCTestCase {
    private var folder: URL!
    private let request = URLRequest(url: TestLinks.url("http://127.0.0.1:9/export"))

    override func setUpWithError() throws {
        try super.setUpWithError()
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoqoraBackendFileDownloadTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        ChunkedDownloadProtocol.serve(status: 200)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    func test_progressIsReportedWhileTheFileDownloadsAndEndsAtOne() async throws {
        let log = ProgressLog()
        let destination = folder.appendingPathComponent("book.mp3")

        try await BackendFileDownload.save(
            request,
            using: ChunkedDownloadProtocol.makeSession(),
            to: destination,
            progress: { log.record($0) }
        )

        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)
        XCTAssertEqual(size.intValue, ChunkedDownloadProtocol.chunkCount * ChunkedDownloadProtocol.chunkSize)
        XCTAssertEqual(log.values.last, 1)
        XCTAssertGreaterThan(log.values.filter { $0 > 0 && $0 < 1 }.count, 0)
        XCTAssertEqual(log.values, log.values.sorted())
    }

    func test_rejectedStatusThrowsWithoutWritingTheDestination() async {
        ChunkedDownloadProtocol.serve(status: 500)
        let destination = folder.appendingPathComponent("book.mp3")

        do {
            try await BackendFileDownload.save(request, using: ChunkedDownloadProtocol.makeSession(), to: destination)
            XCTFail("Expected a failure")
        } catch let failure as AudiobookAPIFailure {
            XCTAssertEqual(failure.statusCode, 500)
        } catch {
            XCTFail("Unexpected error \(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func test_cancellingTheCallerStopsTheDownload() async {
        let destination = folder.appendingPathComponent("book.mp3")
        let session = ChunkedDownloadProtocol.makeSession()
        let task = Task { [request] in
            try await BackendFileDownload.save(request, using: session, to: destination)
        }
        task.cancel()

        let result = await task.result

        XCTAssertThrowsError(try result.get())
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }
}
