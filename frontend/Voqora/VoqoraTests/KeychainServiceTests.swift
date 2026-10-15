import Foundation
import Security
@testable import Voqora
import XCTest

final class KeychainServiceTests: XCTestCase {
    private let service = "com.himudigonda.Voqora.tests.\(UUID().uuidString)"
    private let key = KeychainKey(rawValue: "test.key.\(UUID().uuidString)")

    override func tearDown() {
        KeychainService.delete(key, service: service)
        super.tearDown()
    }

    func testSavedSecretRoundTrips() {
        XCTAssertTrue(KeychainService.set("secret", for: key, service: service))

        XCTAssertEqual(KeychainService.get(key, service: service), "secret")
        XCTAssertTrue(KeychainService.has(key, service: service))
    }

    func testOverwritingReplacesTheSecret() {
        KeychainService.set("first", for: key, service: service)
        KeychainService.set("second", for: key, service: service)

        XCTAssertEqual(KeychainService.get(key, service: service), "second")
    }

    func testDeleteRemovesTheItem() {
        KeychainService.set("secret", for: key, service: service)

        XCTAssertTrue(KeychainService.delete(key, service: service))

        XCTAssertFalse(KeychainService.has(key, service: service))
        XCTAssertNil(KeychainService.get(key, service: service))
    }

    func testOnlyItemsReportingAnOlderAccessibilityNeedMigration() {
        let older = [kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock as String]
        let current = [kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String]

        XCTAssertTrue(KeychainService.needsAccessibilityMigration(older))
        XCTAssertFalse(KeychainService.needsAccessibilityMigration(current))
        XCTAssertFalse(KeychainService.needsAccessibilityMigration([:]))
    }

    func testMigrationNeverLosesTheSecret() {
        KeychainService.set("legacy-secret", for: key, service: service)
        let older = [kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock as String]

        KeychainService.migrateAccessibility(of: older, key: key, service: service)

        XCTAssertEqual(KeychainService.get(key, service: service), "legacy-secret")
    }
}
