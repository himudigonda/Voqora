@testable import Voqora
import XCTest

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
