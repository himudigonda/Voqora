@testable import Voqora
import CryptoKit
import Foundation
import XCTest

@MainActor
final class GuidedInstallerServiceTests: XCTestCase {
    func testParsesOneOfficialDigestBackedDMG() throws {
        let hash = String(repeating: "a", count: 64)
        let payload = """
        {"tag_name":"v1.0.0","assets":[{"name":"Voqora-1.0.0.dmg","browser_download_url":"https://github.com/himudigonda/Voqora/releases/download/v1.0.0/Voqora-1.0.0.dmg","size":3,"digest":"sha256:\(hash)"}]}
        """.data(using: .utf8)!

        let artifact = try GuidedInstallerService.artifact(from: payload)

        XCTAssertEqual(artifact.version, "1.0.0")
        XCTAssertEqual(artifact.byteCount, 3)
        XCTAssertEqual(artifact.sha256, hash)
    }

    func testRejectsReleaseWithoutDigestOrWithMultipleDMGs() {
        let noDigest = """
        {"tag_name":"v1.0.0","assets":[{"name":"Voqora.dmg","browser_download_url":"https://github.com/himudigonda/Voqora/releases/download/v1.0.0/Voqora.dmg","size":1}]}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try GuidedInstallerService.artifact(from: noDigest))

        let multiple = """
        {"tag_name":"v1.0.0","assets":[{"name":"a.dmg","browser_download_url":"https://github.com/himudigonda/Voqora/releases/download/v1.0.0/a.dmg","size":1,"digest":"sha256:\(String(repeating: "a", count: 64))"},{"name":"b.dmg","browser_download_url":"https://github.com/himudigonda/Voqora/releases/download/v1.0.0/b.dmg","size":1,"digest":"sha256:\(String(repeating: "b", count: 64))"}]}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try GuidedInstallerService.artifact(from: multiple))
    }

    func testVerificationRejectsSizeAndDigestMismatch() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("voqora".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let good = SHA256.hash(data: Data("voqora".utf8)).map { String(format: "%02x", $0) }.joined()
        let matching = GuidedInstallerService.ReleaseArtifact(version: "1.0.0", name: "Voqora.dmg", downloadURL: GuidedInstallerService.releasePageURL, byteCount: 6, sha256: good)
        XCTAssertNoThrow(try GuidedInstallerService.verify(file, matches: matching))

        let wrongSize = GuidedInstallerService.ReleaseArtifact(version: "1.0.0", name: "Voqora.dmg", downloadURL: GuidedInstallerService.releasePageURL, byteCount: 7, sha256: good)
        XCTAssertThrowsError(try GuidedInstallerService.verify(file, matches: wrongSize))
    }
}
