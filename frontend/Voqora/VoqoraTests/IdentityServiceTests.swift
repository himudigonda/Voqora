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

    func test_freshOptOutInstallationDoesNotCreateAnIdentity() {
        XCTAssertNil(defaults.string(forKey: "anonymousUserID"))
        XCTAssertNil(service.email)
        XCTAssertFalse(service.hasPendingRemoval)
    }

    func test_eraseLocalIdentityRemovesNameEmailAnonIDAndPendingDeletion() {
        defaults.set("anon-id", forKey: "anonymousUserID")
        defaults.set("seed@example.com", forKey: "userIdentityEmail")
        defaults.set("Seed User", forKey: "userIdentityName")
        defaults.set(true, forKey: "userIdentityRemovalPending")
        service = IdentityService(defaults: defaults)

        service.eraseLocalIdentity()

        XCTAssertNil(defaults.string(forKey: "anonymousUserID"))
        XCTAssertNil(defaults.string(forKey: "userIdentityEmail"))
        XCTAssertNil(defaults.string(forKey: "userIdentityName"))
        XCTAssertNil(defaults.object(forKey: "userIdentityRemovalPending"))
        XCTAssertNil(service.email)
        XCTAssertNil(service.name)
        XCTAssertFalse(service.hasPendingRemoval)
    }

    // MARK: - hasIdentity requires both name and email

    func test_hasIdentity_requiresBothNameAndEmail() {
        XCTAssertFalse(service.hasIdentity)

        defaults.set("seed@example.com", forKey: "userIdentityEmail")
        service = IdentityService(defaults: defaults)
        XCTAssertFalse(service.hasIdentity, "email alone must not count as a complete identity")

        defaults.set("Seed User", forKey: "userIdentityName")
        service = IdentityService(defaults: defaults)
        XCTAssertTrue(service.hasIdentity)
    }

    // MARK: - submitIdentity

    func test_submitIdentity_savesNameAndEmailOnSuccess() async throws {
        let response = try XCTUnwrap(try HTTPURLResponse(
            url: XCTUnwrap(URL(string: "https://example.com")),
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        ))
        service = IdentityService(defaults: defaults, sendRequest: { _ in (Data(), response) })

        try await service.submitIdentity(name: "Ada Lovelace", email: "ADA@example.com")

        XCTAssertEqual(service.name, "Ada Lovelace")
        XCTAssertEqual(service.email, "ada@example.com")
        XCTAssertEqual(defaults.string(forKey: "userIdentityName"), "Ada Lovelace")
        XCTAssertEqual(defaults.string(forKey: "userIdentityEmail"), "ada@example.com")
        XCTAssertTrue(service.hasIdentity)
    }

    func test_submitIdentity_rejectsEmptyName() async {
        do {
            try await service.submitIdentity(name: "  ", email: "ada@example.com")
            XCTFail("expected invalidName to be thrown")
        } catch {
            XCTAssertEqual(error as? IdentityService.IdentityError, .invalidName)
        }
        XCTAssertNil(service.name)
    }

    func test_submitIdentity_succeedsLocallyAndQueuesRetryWhenOffline() async throws {
        service = IdentityService(defaults: defaults, sendRequest: { _ in
            throw URLError(.notConnectedToInternet)
        })

        try await service.submitIdentity(name: "Ada Lovelace", email: "ada@example.com")

        XCTAssertTrue(service.hasIdentity, "a failed network send must not undo the local save")
        XCTAssertTrue(service.hasPendingSubmission)
        XCTAssertEqual(defaults.string(forKey: "userIdentityName"), "Ada Lovelace")
        XCTAssertEqual(defaults.string(forKey: "userIdentityEmail"), "ada@example.com")
    }

    func test_retryPendingSubmission_deliversQueuedIdentityOnceOnline() async throws {
        defaults.set("Ada Lovelace", forKey: "userIdentityName")
        defaults.set("ada@example.com", forKey: "userIdentityEmail")
        defaults.set(true, forKey: "userIdentitySubmissionPending")
        let response = try XCTUnwrap(try HTTPURLResponse(
            url: XCTUnwrap(URL(string: "https://example.com")),
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        ))
        service = IdentityService(defaults: defaults, sendRequest: { _ in (Data(), response) })
        XCTAssertTrue(service.hasPendingSubmission)

        let delivered = await service.retryPendingSubmission()

        XCTAssertTrue(delivered)
        XCTAssertFalse(service.hasPendingSubmission)
        XCTAssertNil(defaults.object(forKey: "userIdentitySubmissionPending"))
    }

    // MARK: - Name/email validation (pure)

    func test_nameValidator_acceptsNonEmptyTrimmedNames() {
        XCTAssertTrue(IdentityService.looksLikeName("Ada Lovelace"))
        XCTAssertTrue(IdentityService.looksLikeName("A"))
    }

    func test_nameValidator_rejectsEmptyOrTooLong() {
        XCTAssertFalse(IdentityService.looksLikeName(""))
        XCTAssertFalse(IdentityService.looksLikeName(String(repeating: "a", count: 121)))
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
        defaults.set("seed@example.com", forKey: "userIdentityEmail")
        // Re-read via a fresh observer of shared singleton's state is awkward;
        // instead exercise the clear path through the public API and verify UD.
        service.clearEmail()
        XCTAssertNil(defaults.string(forKey: "userIdentityEmail"))
        XCTAssertNil(service.email)
    }

    func test_removeEmailClearsThisMacAfterRemoteSuccess() async throws {
        defaults.set("seed@example.com", forKey: "userIdentityEmail")
        let response = try XCTUnwrap(try HTTPURLResponse(
            url: XCTUnwrap(URL(string: "https://example.com")),
            statusCode: 204,
            httpVersion: nil,
            headerFields: nil
        ))
        service = IdentityService(defaults: defaults, sendRequest: { _ in (Data(), response) })

        let result = await service.removeEmail()

        XCTAssertEqual(result, .removedRemotely)
        XCTAssertNil(service.email)
        XCTAssertFalse(service.hasPendingRemoval)
        XCTAssertNil(defaults.string(forKey: "userIdentityEmail"))
    }

    func test_removeEmailOfflineClearsThisMacAndQueuesRemoteRetry() async {
        defaults.set("seed@example.com", forKey: "userIdentityEmail")
        service = IdentityService(defaults: defaults, sendRequest: { _ in
            throw URLError(.notConnectedToInternet)
        })

        let result = await service.removeEmail()

        XCTAssertEqual(result, .queuedForRetry)
        XCTAssertNil(service.email)
        XCTAssertTrue(service.hasPendingRemoval)
        XCTAssertNil(defaults.string(forKey: "userIdentityEmail"))
    }
}
