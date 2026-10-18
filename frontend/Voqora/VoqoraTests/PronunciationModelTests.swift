import Foundation
@testable import Voqora
import XCTest

@MainActor
final class PronunciationModelTests: XCTestCase {
    nonisolated static let bookID = "0123456789abcdef0123456789abcdef"
    nonisolated static let entryID = "fedcba9876543210fedcba9876543210"

    static func entryJSON(id: String = entryID, match: String = "SQL", scope: String = "global") -> String {
        """
        {"id":"\(id)","match":"\(match)","replacement":"sequel","case_sensitive":true,
         "whole_word":false,"scope":"\(scope)","created_at":"2026-10-01T10:00:00Z","updated_at":"2026-10-01T10:00:00Z"}
        """
    }

    static func entry(id: String = entryID, match: String = "SQL", scope: String = "global") throws -> PronunciationEntry {
        try JSONDecoder().decode(PronunciationEntry.self, from: Data(entryJSON(id: id, match: match, scope: scope).utf8))
    }

    func test_scopeRoundTripsGlobalAndBookIDs() {
        XCTAssertEqual(PronunciationScope(rawValue: "global"), .global)
        XCTAssertEqual(PronunciationScope(rawValue: Self.bookID), .book(Self.bookID))
        XCTAssertNil(PronunciationScope(rawValue: "0123456789ABCDEF0123456789ABCDEF"))
        XCTAssertNil(PronunciationScope(rawValue: "book"))
        XCTAssertEqual(PronunciationScope.book(Self.bookID).rawValue, Self.bookID)
        XCTAssertNil(PronunciationScope.global.bookID)
    }

    func test_entryDecodesSnakeCaseFields() throws {
        let entry = try Self.entry(scope: Self.bookID)

        XCTAssertEqual(entry.match, "SQL")
        XCTAssertEqual(entry.replacement, "sequel")
        XCTAssertTrue(entry.caseSensitive)
        XCTAssertFalse(entry.wholeWord)
        XCTAssertEqual(entry.scopeValue, .book(Self.bookID))
    }

    func test_entrySearchMatchesEitherSide() throws {
        let entry = try Self.entry()

        XCTAssertTrue(entry.matches(query: "sq"))
        XCTAssertTrue(entry.matches(query: "SEQ"))
        XCTAssertTrue(entry.matches(query: "  "))
        XCTAssertFalse(entry.matches(query: "nginx"))
    }

    func test_draftValidatesMatchAndReplacement() {
        var draft = PronunciationDraft()
        XCTAssertEqual(draft.validationMessage, "Enter the text to replace.")

        draft.match = String(repeating: "x", count: 101)
        XCTAssertEqual(draft.validationMessage, "Keep the text to replace to 100 characters or fewer.")

        draft.match = "SQL"
        draft.replacement = String(repeating: "y", count: 201)
        XCTAssertEqual(draft.validationMessage, "Keep the replacement to 200 characters or fewer.")

        draft.replacement = "se\nquel"
        XCTAssertEqual(draft.validationMessage, "Use a single line of text without line breaks.")

        draft.replacement = ""
        XCTAssertNil(draft.validationMessage)
    }

    func test_draftRequestTrimsAndEncodesSnakeCase() throws {
        let draft = PronunciationDraft(match: "  SQL ", replacement: " sequel ", caseSensitive: true, wholeWord: false, scope: .book(Self.bookID))
        let data = try JSONEncoder().encode(draft.request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["match"] as? String, "SQL")
        XCTAssertEqual(object["replacement"] as? String, "sequel")
        XCTAssertEqual(object["case_sensitive"] as? Bool, true)
        XCTAssertEqual(object["whole_word"] as? Bool, false)
        XCTAssertEqual(object["scope"] as? String, Self.bookID)
    }

    func test_testRequestOmitsMissingBookID() throws {
        let global = try JSONSerialization.jsonObject(with: JSONEncoder().encode(PronunciationTestRequest(text: "Hi", bookID: nil))) as? [String: Any]
        let book = try JSONSerialization.jsonObject(with: JSONEncoder().encode(PronunciationTestRequest(text: "Hi", bookID: Self.bookID))) as? [String: Any]

        XCTAssertEqual(global?.keys.sorted(), ["text"])
        XCTAssertEqual(book?["book_id"] as? String, Self.bookID)
    }

    func test_transferFileRoundTripsWithoutScopeOrIDs() throws {
        let file = try PronunciationTransferFile(entries: [Self.entry(scope: Self.bookID)])
        let data = try file.encoded()
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertFalse(text.contains(Self.entryID))
        XCTAssertFalse(text.contains(Self.bookID))

        let decoded = try PronunciationTransferFile.decode(data)
        let drafts = decoded.drafts(in: .global)
        XCTAssertEqual(drafts.count, 1)
        XCTAssertEqual(drafts.first?.match, "SQL")
        XCTAssertEqual(drafts.first?.caseSensitive, true)
        XCTAssertEqual(drafts.first?.scope, .global)
    }

    func test_transferFileRejectsForeignEmptyAndNewerFiles() {
        XCTAssertThrowsError(try PronunciationTransferFile.decode(Data("[]".utf8))) { error in
            XCTAssertEqual(error as? PronunciationTransferFile.TransferError, .unreadable)
        }
        let empty = #"{"format":"voqora.pronunciations","version":1,"entries":[]}"#
        XCTAssertThrowsError(try PronunciationTransferFile.decode(Data(empty.utf8))) { error in
            XCTAssertEqual(error as? PronunciationTransferFile.TransferError, .empty)
        }
        let newer = #"{"format":"voqora.pronunciations","version":9,"entries":[]}"#
        XCTAssertThrowsError(try PronunciationTransferFile.decode(Data(newer.utf8))) { error in
            XCTAssertEqual(error as? PronunciationTransferFile.TransferError, .unsupportedVersion)
        }
    }

    func test_importSummaryMessageMentionsEveryOutcome() {
        var summary = PronunciationImportSummary(added: 1)
        XCTAssertEqual(summary.message, "Imported 1 pronunciation.")

        summary = PronunciationImportSummary(added: 3, skipped: 2, invalid: 1, limitReached: true)
        XCTAssertEqual(
            summary.message,
            "Imported 3 pronunciations. Skipped 2 already in your dictionary. 1 entry wasn't valid. Your dictionary is full at 500 entries."
        )
    }

    func test_pauseScaleClampsAndLabels() {
        XCTAssertEqual(PauseScale.clamped(0.1), 0.5)
        XCTAssertEqual(PauseScale.clamped(3), 2.0)
        XCTAssertEqual(PauseScale.clamped(.nan), 1.0)
        XCTAssertEqual(PauseScale.clamped(.infinity), 1.0)
        XCTAssertEqual(PauseScale.label(1.0), "1×")
        XCTAssertEqual(PauseScale.label(1.25), "1.25×")
        XCTAssertEqual(PauseScale.description(1.0), "Natural pauses")
        XCTAssertEqual(PauseScale.description(0.6), "Shorter pauses")
        XCTAssertEqual(PauseScale.description(1.6), "Longer pauses")
    }

    func test_backendErrorDetailTurnsValidationIntoSentences() {
        XCTAssertEqual(
            BackendErrorDetail.message(from: Data(#"{"detail":"Voice blend not found."}"#.utf8)),
            "Voice blend not found."
        )
        XCTAssertEqual(
            BackendErrorDetail.message(from: Data(#"{"detail":[{"loc":["body"],"msg":"Value error, voice listed twice: af_bella","type":"value_error"}]}"#.utf8)),
            "Voice listed twice: af_bella."
        )
        XCTAssertNil(BackendErrorDetail.message(from: Data("oops".utf8)))
    }
}
