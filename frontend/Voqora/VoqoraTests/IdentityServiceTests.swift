@testable import Voqora
import XCTest

@MainActor
final class IdentityServiceTests: XCTestCase {
    func test_anonID_isStableAcrossReads() {
        let first = IdentityService.shared.anonID
        let second = IdentityService.shared.anonID
        XCTAssertEqual(first, second, "anonID must be stable for the install lifetime")
        XCTAssertFalse(first.isEmpty)
    }

    func test_anonID_persistsInUserDefaults() {
        let id = IdentityService.shared.anonID
        XCTAssertEqual(UserDefaults.standard.string(forKey: "anonymousUserID"), id)
    }

    // MARK: - Email validation (pure)

    func test_emailValidator_acceptsCommonShapes() {
        XCTAssertTrue(IdentityService.looksLikeEmail("a@b.co"))
        XCTAssertTrue(IdentityService.looksLikeEmail("first.last+tag@example.org"))
        XCTAssertTrue(IdentityService.looksLikeEmail("user@sub.domain.io"))
    }

    func test_emailValidator_rejectsObviousJunk() {
        XCTAssertFalse(IdentityService.looksLikeEmail(""))
        XCTAssertFalse(IdentityService.looksLikeEmail("no-at-symbol.com"))
        XCTAssertFalse(IdentityService.looksLikeEmail("two@ats@here.com"))
        XCTAssertFalse(IdentityService.looksLikeEmail("missing@domain"))
        XCTAssertFalse(IdentityService.looksLikeEmail("white space@bad.com"))
        XCTAssertFalse(IdentityService.looksLikeEmail("@nope.com"))
        XCTAssertFalse(IdentityService.looksLikeEmail("nope@"))
    }

    func test_clearEmail_resetsState() {
        // Direct write to UserDefaults to seed state without hitting the network.
        UserDefaults.standard.set("seed@example.com", forKey: "userIdentityEmail")
        // Re-read via a fresh observer of shared singleton's state is awkward;
        // instead exercise the clear path through the public API and verify UD.
        IdentityService.shared.clearEmail()
        XCTAssertNil(UserDefaults.standard.string(forKey: "userIdentityEmail"))
        XCTAssertNil(IdentityService.shared.email)
    }
}
