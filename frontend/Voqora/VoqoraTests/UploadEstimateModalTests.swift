@testable import Voqora
import XCTest

final class UploadEstimateModalTests: XCTestCase {
    func test_isStartDisabled_falseForOrdinaryTextDocument() {
        XCTAssertFalse(UploadEstimateModal.isStartDisabled(
            startingProcessing: false,
            isImageOnly: false,
            useCleanup: false,
            hasProvider: false
        ))
    }

    func test_isStartDisabled_trueWhileStartRequestInFlight() {
        XCTAssertTrue(UploadEstimateModal.isStartDisabled(
            startingProcessing: true,
            isImageOnly: false,
            useCleanup: false,
            hasProvider: true
        ))
    }

    func test_isStartDisabled_trueForImageOnlyPDFWithoutCleanup() {
        XCTAssertTrue(UploadEstimateModal.isStartDisabled(
            startingProcessing: false,
            isImageOnly: true,
            useCleanup: false,
            hasProvider: true
        ))
    }

    func test_isStartDisabled_falseForImageOnlyPDFWithCleanupAndProvider() {
        XCTAssertFalse(UploadEstimateModal.isStartDisabled(
            startingProcessing: false,
            isImageOnly: true,
            useCleanup: true,
            hasProvider: true
        ))
    }

    func test_isStartDisabled_trueWhenCleanupOnWithoutProvider() {
        XCTAssertTrue(UploadEstimateModal.isStartDisabled(
            startingProcessing: false,
            isImageOnly: false,
            useCleanup: true,
            hasProvider: false
        ))
    }

    func test_isStartDisabled_falseWhenCleanupOnWithProvider() {
        XCTAssertFalse(UploadEstimateModal.isStartDisabled(
            startingProcessing: false,
            isImageOnly: false,
            useCleanup: true,
            hasProvider: true
        ))
    }

    func test_isStartDisabled_trueForImageOnlyPDFWithTextOnlyModel() {
        XCTAssertTrue(UploadEstimateModal.isStartDisabled(
            startingProcessing: false,
            isImageOnly: true,
            useCleanup: true,
            hasProvider: true,
            providerReadsImages: false
        ))
    }

    func test_isStartDisabled_falseForImageOnlyPDFWhenVisionIsUnknown() {
        XCTAssertFalse(UploadEstimateModal.isStartDisabled(
            startingProcessing: false,
            isImageOnly: true,
            useCleanup: true,
            hasProvider: true,
            providerReadsImages: nil
        ))
    }
}
