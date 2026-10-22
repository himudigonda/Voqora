@testable import Voqora
import XCTest

@MainActor
final class SharedSettingsSectionsTests: XCTestCase {
    func test_bookVoiceFollowsSpeakingVoiceWhenMatched() {
        XCTAssertEqual(VoiceSync.bookVoice(current: "af_bella", previousSpeaking: "af_bella", newSpeaking: "am_adam"), "am_adam")
        XCTAssertEqual(VoiceSync.bookVoice(current: "bf_emma", previousSpeaking: "af_bella", newSpeaking: "am_adam"), "bf_emma")
    }

    func test_identityValidationAllowsBlankPair() {
        XCTAssertEqual(IdentityDraft().validation, .blank)
        XCTAssertEqual(IdentityDraft(name: "  ", email: "\n").validation, .blank)
        XCTAssertTrue(IdentityDraft().allowsContinue)
        XCTAssertNil(IdentityDraft().errorMessage)
        XCTAssertEqual(IdentityDraft(name: "Ada", email: "ada@example.com").validation, .valid)
        XCTAssertTrue(IdentityDraft(name: "Ada", email: "ada@example.com").allowsContinue)
    }

    func test_identityValidationRejectsPartialInput() {
        let nameOnly = IdentityDraft(name: "Ada", email: "")
        XCTAssertFalse(nameOnly.allowsContinue)
        XCTAssertNotNil(nameOnly.errorMessage)
        let emailOnly = IdentityDraft(name: "", email: "ada@example.com")
        XCTAssertEqual(emailOnly.errorMessage, IdentityDraft.partialNameMessage)
        XCTAssertFalse(IdentityDraft(name: "Ada", email: "not-an-email").allowsContinue)
    }

    func test_saveRequiresValidChangedPair() {
        let draft = IdentityDraft(name: "Ada", email: "Ada@Example.com")
        XCTAssertTrue(draft.canSave(storedName: nil, storedEmail: nil))
        XCTAssertFalse(draft.canSave(storedName: "Ada", storedEmail: "ada@example.com"))
        XCTAssertFalse(IdentityDraft().canSave(storedName: "Ada", storedEmail: "ada@example.com"))
    }

    func test_blankCommitSendsNothing() async throws {
        var requests = 0
        let suite = try XCTUnwrap(UserDefaults(suiteName: "SharedSettingsSectionsTests.\(UUID().uuidString)"))
        let identity = IdentityService(defaults: suite) { _ in
            requests += 1
            throw URLError(.notConnectedToInternet)
        }
        let submitted = try await IdentityDraft().commit(to: identity)
        XCTAssertFalse(submitted)
        XCTAssertEqual(requests, 0)
        XCTAssertNil(identity.email)
    }

    func test_permissionRowPresentationFollowsState() {
        let granted = PermissionRowPresentation(kind: .microphone, state: .granted)
        XCTAssertNil(granted.action)
        XCTAssertEqual(granted.chipKind, .success)
        let askable = PermissionRowPresentation(kind: .microphone, state: .notDetermined)
        XCTAssertEqual(askable.action, .request)
        XCTAssertTrue(askable.isPrimaryAction)
        let denied = PermissionRowPresentation(kind: .microphone, state: .denied)
        XCTAssertEqual(denied.action, .openSettings)
        XCTAssertEqual(denied.actionTitle, "Open System Settings")
        XCTAssertEqual(PermissionRowPresentation(kind: .accessibility, state: .denied).chipKind, .danger)
        XCTAssertEqual(PermissionRowPresentation(kind: .accessibility, state: .denied).action, .request)
        XCTAssertNil(PermissionRowPresentation(kind: .notifications, state: .unknown).action)
    }
}
