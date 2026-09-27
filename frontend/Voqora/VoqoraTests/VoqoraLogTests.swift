import Foundation
@testable import Voqora
import XCTest

final class VoqoraLogTests: XCTestCase {
    private func serialized(_ context: [String: String]) -> String {
        VoqoraLog.redactedContext(context)
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " | ")
    }

    func testGeminiKeyRedactedUnderConventionalKeyName() {
        let apiKey = "AIzaSyD-fakeKeyForTestingPurposesOnly123"
        let out = serialized(["apiKey": apiKey])
        XCTAssertFalse(out.contains(apiKey))
        XCTAssertEqual(out, "apiKey_redacted=true")
    }

    func testGeminiKeyRedactedEvenUnderGenericKeyName() {
        let apiKey = "AIzaSyD-fakeKeyForTestingPurposesOnly123"
        let out = serialized(["value": apiKey])
        XCTAssertFalse(out.contains(apiKey))
    }

    func testIPCTokenRedactedUnderConventionalKeyName() {
        let token = Data((0 ..< 32).map { _ in UInt8.random(in: 0 ... 255) }).base64EncodedString()
        let out = serialized(["ipcToken": token])
        XCTAssertFalse(out.contains(token))
    }

    func testBearerAndIPCHeaderSyntaxRedactedRegardlessOfKeyName() {
        let bearer = "Authorization: Bearer sk-should-never-appear-in-logs"
        XCTAssertFalse(serialized(["header": bearer]).contains("sk-should-never-appear-in-logs"))

        let ipcHeader = "X-Voqora-IPC-Token: should-never-appear-either"
        XCTAssertFalse(serialized(["detail": ipcHeader]).contains("should-never-appear-either"))
    }

    func testPathWithUsernameRedactedUnderPathKey() {
        let path = NSHomeDirectory() + "/Library/Application Support/Voqora/backend.log"
        let out = serialized(["path": path])
        XCTAssertFalse(out.contains(NSUserName()))
    }

    func testPathWithUsernameRedactedEvenUnderGenericKeyName() {
        let path = NSHomeDirectory() + "/Documents/Projects/Voqora/backend.log"
        let out = serialized(["detail": path])
        XCTAssertFalse(out.contains(NSUserName()), "account name leaked via a non-'path' key: \(out)")
        XCTAssertFalse(out.contains(path), "full path leaked via a non-'path' key: \(out)")
    }

    func testBenignOperationalFieldsPassThroughUnredacted() {
        let context = ["bookID": "abc123", "durationMs": "42"]
        XCTAssertEqual(VoqoraLog.redactedContext(context), context)
    }
}
