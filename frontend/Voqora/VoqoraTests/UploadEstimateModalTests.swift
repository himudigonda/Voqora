@testable import Voqora
import XCTest

/// Pure-logic tests for `UploadEstimateModal`'s Start-Processing
/// disabled-condition (jira-audiobook-quality.md T-19). Exercises the
/// `internal` static member added specifically so this logic is testable
/// without a live view, matching the `AudiobookPlayerLayoutTests` precedent.
final class UploadEstimateModalTests: XCTestCase {
    func test_isStartDisabled_falseForOrdinaryTextDocument() {
        XCTAssertFalse(UploadEstimateModal.isStartDisabled(
            startingProcessing: false,
            isImageOnly: false,
            useGeminiCleanup: false,
            hasStoredKey: false
        ))
    }

    func test_isStartDisabled_trueWhileStartRequestInFlight() {
        XCTAssertTrue(UploadEstimateModal.isStartDisabled(
            startingProcessing: true,
            isImageOnly: false,
            useGeminiCleanup: false,
            hasStoredKey: true
        ))
    }

    func test_isStartDisabled_trueForImageOnlyPDFWithoutGeminiCleanup() {
        XCTAssertTrue(UploadEstimateModal.isStartDisabled(
            startingProcessing: false,
            isImageOnly: true,
            useGeminiCleanup: false,
            hasStoredKey: true
        ))
    }

    func test_isStartDisabled_falseForImageOnlyPDFWithGeminiCleanupAndKey() {
        XCTAssertFalse(UploadEstimateModal.isStartDisabled(
            startingProcessing: false,
            isImageOnly: true,
            useGeminiCleanup: true,
            hasStoredKey: true
        ))
    }

    func test_isStartDisabled_trueWhenGeminiCleanupOnWithoutStoredKey() {
        XCTAssertTrue(UploadEstimateModal.isStartDisabled(
            startingProcessing: false,
            isImageOnly: false,
            useGeminiCleanup: true,
            hasStoredKey: false
        ))
    }

    func test_isStartDisabled_falseWhenGeminiCleanupOnWithStoredKey() {
        XCTAssertFalse(UploadEstimateModal.isStartDisabled(
            startingProcessing: false,
            isImageOnly: false,
            useGeminiCleanup: true,
            hasStoredKey: true
        ))
    }
}
