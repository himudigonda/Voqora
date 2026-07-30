@testable import Voqora
import XCTest

@MainActor
final class IdentityServiceTests: XCTestCase {
    private var defaults: UserDefaults!
    private var service: IdentityService!
    private var suiteName = ""

    override func setUp() {
        super.setUp()
        suiteName = "IdentityServiceTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        service = IdentityService(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        service = nil
        defaults = nil
        super.tearDown()
    }

    func test_anonID_isStableAcrossReads() {
        let first = service.anonID
        let second = service.anonID
        XCTAssertEqual(first, second, "anonID must be stable for the install lifetime")
        XCTAssertFalse(first.isEmpty)
    }

    func test_anonID_persistsInUserDefaults() {
        let id = service.anonID
        XCTAssertEqual(defaults.string(forKey: "anonymousUserID"), id)
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

    func test_clearEmail_resetsState() async {
        // Direct write to UserDefaults to seed state without hitting the network.
        defaults.set("seed@example.com", forKey: "userIdentityEmail")
        // Re-read via a fresh observer of shared singleton's state is awkward;
        // instead exercise the clear path through the public API and verify UD.
        service.clearEmail()
        XCTAssertNil(defaults.string(forKey: "userIdentityEmail"))
        XCTAssertNil(service.email)
    }
}
