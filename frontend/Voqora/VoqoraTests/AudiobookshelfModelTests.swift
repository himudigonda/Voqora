import Foundation
@testable import Voqora
import XCTest

final class AudiobookshelfServerAddressTests: XCTestCase {
    func test_httpsAddressesAreAcceptedAndNormalized() {
        XCTAssertEqual(AudiobookshelfServerAddress("https://abs.example.com/").url?.absoluteString, "https://abs.example.com")
        XCTAssertEqual(AudiobookshelfServerAddress("  HTTPS://abs.example.com/audiobookshelf/ ").url?.absoluteString, "https://abs.example.com/audiobookshelf")
        XCTAssertEqual(AudiobookshelfServerAddress("abs.example.com:13378").url?.absoluteString, "https://abs.example.com:13378")
        XCTAssertNil(AudiobookshelfServerAddress("https://abs.example.com").warning)
    }

    func test_plainHTTPIsOnlyAllowedOnTheLocalNetworkWithAWarning() {
        for local in [
            "http://localhost:13378",
            "http://127.0.0.1",
            "http://192.168.1.20:13378",
            "http://10.0.0.5",
            "http://172.20.1.1",
            "http://169.254.10.10",
            "http://nas.local:13378",
            "http://nas:13378",
            "http://[::1]:13378",
            "http://[fd12::1]",
        ] {
            let address = AudiobookshelfServerAddress(local)
            XCTAssertNotNil(address.url, local)
            XCTAssertEqual(address.warning, AudiobookshelfServerAddress.localNetworkWarning, local)
        }
        for remote in ["http://abs.example.com", "http://8.8.8.8", "http://172.32.0.1", "http://192.169.0.1"] {
            XCTAssertEqual(AudiobookshelfServerAddress(remote), .invalid(AudiobookshelfServerAddress.insecureMessage), remote)
        }
    }

    func test_malformedAddressesAreRejected() {
        XCTAssertEqual(AudiobookshelfServerAddress("  "), .invalid(AudiobookshelfServerAddress.emptyMessage))
        XCTAssertEqual(AudiobookshelfServerAddress("ftp://abs.example.com"), .invalid(AudiobookshelfServerAddress.malformedMessage))
        XCTAssertEqual(AudiobookshelfServerAddress("https://abs.example.com/?x=1"), .invalid(AudiobookshelfServerAddress.malformedMessage))
        XCTAssertEqual(AudiobookshelfServerAddress("https://"), .invalid(AudiobookshelfServerAddress.malformedMessage))
        XCTAssertEqual(AudiobookshelfServerAddress("https://me:secret@abs.example.com"), .invalid(AudiobookshelfServerAddress.credentialsMessage))
    }

    func test_libraryDecodingIsLenient() throws {
        let json = """
        {"libraries":[
          {"id":"lib1","name":"Audiobooks","mediaType":"book","folders":[{"id":"fol1","fullPath":"/audiobooks","libraryId":"lib1"}],"icon":"database"},
          {"id":"lib2","name":"Podcasts","mediaType":"podcast","folders":[]},
          {"id":"lib3"}
        ]}
        """
        let list = try JSONDecoder().decode(AudiobookshelfLibraryList.self, from: Data(json.utf8))

        XCTAssertEqual(list.libraries.map(\.id), ["lib1", "lib2", "lib3"])
        XCTAssertEqual(list.libraries[0].folders, [AudiobookshelfFolder(id: "fol1", fullPath: "/audiobooks")])
        XCTAssertEqual(list.libraries.map(\.holdsBooks), [true, false, true])
        XCTAssertEqual(list.libraries[2].name, "lib3")
        XCTAssertEqual(list.libraries[0].folders[0].displayName, "/audiobooks")
    }
}

final class MultipartFormWriterTests: XCTestCase {
    func test_writesSingleLineFieldsThenTheFileWithAHeaderSafeName() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MultipartTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("book.m4b")
        try Data("AUDIO".utf8).write(to: source)
        let output = directory.appendingPathComponent("body")

        try MultipartFormWriter.write(
            fields: [("title", "A \"Line\"\r\nBreak"), ("library", "lib1")],
            file: MultipartFilePart(name: "0", filename: "A \"Book\".m4b", contentType: "audio/mp4", source: source),
            boundary: "XYZ",
            to: output
        )

        let body = try String(contentsOf: output, encoding: .utf8)
        XCTAssertEqual(body, [
            "--XYZ\r\nContent-Disposition: form-data; name=\"title\"\r\n\r\nA \"Line\"  Break\r\n",
            "--XYZ\r\nContent-Disposition: form-data; name=\"library\"\r\n\r\nlib1\r\n",
            "--XYZ\r\nContent-Disposition: form-data; name=\"0\"; filename=\"A 'Book'.m4b\"\r\nContent-Type: audio/mp4\r\n\r\nAUDIO",
            "\r\n--XYZ--\r\n",
        ].joined())
        XCTAssertEqual(MultipartFormWriter.contentType(boundary: "XYZ"), "multipart/form-data; boundary=XYZ")
    }

    func test_missingSourceLeavesNoPartialBody() {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("MultipartTests-\(UUID().uuidString)")
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString)")

        XCTAssertThrowsError(try MultipartFormWriter.write(
            fields: [],
            file: MultipartFilePart(name: "0", filename: "a.m4b", contentType: "audio/mp4", source: missing),
            boundary: "B",
            to: output
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }
}
