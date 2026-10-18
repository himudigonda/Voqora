import Foundation
@testable import Voqora
import XCTest

@MainActor
final class AudiobookshelfClientTests: XCTestCase {
    private var directory: URL!
    private var client: AudiobookshelfClient!
    private let server = URL(string: "https://abs.example.com/shelf")!

    override func setUpWithError() throws {
        HTTPStubProtocol.reset()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("AudiobookshelfClientTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        client = AudiobookshelfClient(session: HTTPStubProtocol.makeSession(), temporaryDirectory: directory)
    }

    override func tearDownWithError() throws {
        HTTPStubProtocol.reset()
        try? FileManager.default.removeItem(at: directory)
    }

    func test_libraries_sendsTheBearerTokenAndDecodesLibraries() async throws {
        HTTPStubProtocol.install { _ in
            HTTPStubReply(statusCode: 200, json: #"{"libraries":[{"id":"lib1","name":"Books","mediaType":"book","folders":[{"id":"f1","fullPath":"/books"}]}]}"#)
        }

        let libraries = try await client.libraries(server: server, token: "tok")

        XCTAssertEqual(libraries.map(\.id), ["lib1"])
        let request = try XCTUnwrap(HTTPStubProtocol.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://abs.example.com/shelf/api/libraries")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        XCTAssertEqual(request.httpMethod, "GET")
    }

    func test_libraries_mapsStatusCodesToClearErrors() async {
        let cases: [(Int, String, AudiobookshelfError)] = [
            (401, "{}", .unauthorized),
            (403, "{}", .forbidden),
            (404, "{}", .notAudiobookshelf),
            (500, "{}", .server(500)),
            (200, "<html>", .notAudiobookshelf),
        ]
        for (status, body, expected) in cases {
            HTTPStubProtocol.install { _ in HTTPStubReply(statusCode: status, json: body) }
            do {
                _ = try await client.libraries(server: server, token: "tok")
                XCTFail("Expected \(expected)")
            } catch {
                XCTAssertEqual(error as? AudiobookshelfError, expected)
            }
        }
    }

    func test_transportErrorsMapToFriendlyErrors() {
        XCTAssertEqual(AudiobookshelfError.from(transport: URLError(.timedOut)) as? AudiobookshelfError, .timedOut)
        XCTAssertEqual(AudiobookshelfError.from(transport: URLError(.cannotFindHost)) as? AudiobookshelfError, .unreachable)
        XCTAssertEqual(AudiobookshelfError.from(transport: URLError(.serverCertificateUntrusted)) as? AudiobookshelfError, .untrustedCertificate)
        XCTAssertEqual(
            AudiobookshelfError.from(transport: URLError(.appTransportSecurityRequiresSecureConnection)) as? AudiobookshelfError,
            .insecureBlocked
        )
        XCTAssertTrue(AudiobookshelfError.from(transport: URLError(.cancelled)) is CancellationError)
    }

    func test_upload_postsMultipartToTheUploadEndpoint() async throws {
        HTTPStubProtocol.install { _ in HTTPStubReply(statusCode: 200) }
        let file = directory.appendingPathComponent("book.m4b")
        try Data("AUDIO".utf8).write(to: file)
        let upload = AudiobookshelfUpload(
            destination: AudiobookshelfDestination(server: server, token: "tok", libraryID: "lib1", folderID: "f1"),
            title: "My Book",
            author: nil,
            file: file
        )

        try await client.upload(upload) { _ in }

        let request = try XCTUnwrap(HTTPStubProtocol.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://abs.example.com/shelf/api/upload")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(leftovers, ["book.m4b"])
    }

    func test_uploadFieldsFollowTheAudiobookshelfForm() {
        let destination = AudiobookshelfDestination(server: server, token: "tok", libraryID: "lib1", folderID: "f1")
        let withAuthor = AudiobookshelfUpload(destination: destination, title: "Dune", author: " Frank Herbert ", file: server)
        let withoutAuthor = AudiobookshelfUpload(destination: destination, title: "Dune", author: "  ", file: server)

        XCTAssertEqual(
            AudiobookshelfClient.fields(for: withAuthor).map { "\($0.0)=\($0.1)" },
            ["title=Dune", "author=Frank Herbert", "library=lib1", "folder=f1"]
        )
        XCTAssertEqual(
            AudiobookshelfClient.fields(for: withoutAuthor).map { "\($0.0)=\($0.1)" },
            ["title=Dune", "library=lib1", "folder=f1"]
        )
        XCTAssertEqual(AudiobookshelfClient.filePart(for: withAuthor).filename, "Dune.m4b")
        XCTAssertEqual(AudiobookshelfClient.filePart(for: withAuthor).contentType, "audio/mp4")
    }

    func test_uploadStatusMapping() {
        XCTAssertNoThrow(try AudiobookshelfClient.validateUpload(statusCode: 200))
        let cases: [(Int, AudiobookshelfError)] = [
            (400, .rejected),
            (401, .unauthorized),
            (403, .uploadNotAllowed),
            (404, .libraryMissing),
            (413, .tooLarge),
            (502, .server(502)),
        ]
        for (status, expected) in cases {
            XCTAssertThrowsError(try AudiobookshelfClient.validateUpload(statusCode: status)) { error in
                XCTAssertEqual(error as? AudiobookshelfError, expected)
            }
        }
    }
}
