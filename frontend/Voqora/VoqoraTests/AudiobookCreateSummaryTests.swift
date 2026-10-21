@testable import Voqora
import XCTest

final class AudiobookCreateSummaryTests: XCTestCase {
    func test_isStartDisabled_falseForOrdinaryTextDocument() {
        XCTAssertFalse(AudiobookCreateSummary.isStartDisabled(
            startingProcessing: false,
            isImageOnly: false,
            useCleanup: false,
            hasProvider: false
        ))
    }

    func test_isStartDisabled_trueWhileStartRequestInFlight() {
        XCTAssertTrue(AudiobookCreateSummary.isStartDisabled(
            startingProcessing: true,
            isImageOnly: false,
            useCleanup: false,
            hasProvider: true
        ))
    }

    func test_isStartDisabled_trueForImageOnlyPDFWithoutCleanup() {
        XCTAssertTrue(AudiobookCreateSummary.isStartDisabled(
            startingProcessing: false,
            isImageOnly: true,
            useCleanup: false,
            hasProvider: true
        ))
    }

    func test_isStartDisabled_falseForImageOnlyPDFWithCleanupAndProvider() {
        XCTAssertFalse(AudiobookCreateSummary.isStartDisabled(
            startingProcessing: false,
            isImageOnly: true,
            useCleanup: true,
            hasProvider: true
        ))
    }

    func test_isStartDisabled_trueWhenCleanupOnWithoutProvider() {
        XCTAssertTrue(AudiobookCreateSummary.isStartDisabled(
            startingProcessing: false,
            isImageOnly: false,
            useCleanup: true,
            hasProvider: false
        ))
    }

    func test_isStartDisabled_falseWhenCleanupOnWithProvider() {
        XCTAssertFalse(AudiobookCreateSummary.isStartDisabled(
            startingProcessing: false,
            isImageOnly: false,
            useCleanup: true,
            hasProvider: true
        ))
    }

    func test_isStartDisabled_trueForImageOnlyPDFWithTextOnlyModel() {
        XCTAssertTrue(AudiobookCreateSummary.isStartDisabled(
            startingProcessing: false,
            isImageOnly: true,
            useCleanup: true,
            hasProvider: true,
            providerReadsImages: false
        ))
    }

    func test_isStartDisabled_falseForImageOnlyPDFWhenVisionIsUnknown() {
        XCTAssertFalse(AudiobookCreateSummary.isStartDisabled(
            startingProcessing: false,
            isImageOnly: true,
            useCleanup: true,
            hasProvider: true,
            providerReadsImages: nil
        ))
    }

    private func estimate(audioSeconds: Double = 600, processingSeconds: Double = 40, cost: Double = 0.5) -> AudiobookEstimateResponse {
        AudiobookEstimateResponse(
            bookID: "book", title: "A", pageCount: 3, wordCountEstimate: 900,
            estimatedProcessingSeconds: processingSeconds, estimatedAudioSeconds: audioSeconds, estimatedCostUsd: cost,
            maximumCostUsd: cost, estimatedTokenCount: 1000, isImageOnly: false, costWarning: false,
            duplicateOfBookID: nil, duplicateOfTitle: nil
        )
    }

    func test_processingSeconds_keepsTheBackendFigureForKokoroAndSupertonic() {
        let book = estimate()

        XCTAssertEqual(AudiobookCreateSummary.processingSeconds(for: book, voice: "af_bella"), 40)
        XCTAssertEqual(AudiobookCreateSummary.processingSeconds(for: book, voice: "supertonic:F1"), 40)
        XCTAssertEqual(AudiobookCreateSummary.processingSeconds(for: book, voice: "blend:00000000-0000-0000-0000-000000000000"), 40)
    }

    func test_processingSeconds_usesTheSlowerMingFactorWithColdStart() {
        let book = estimate(audioSeconds: 600)

        XCTAssertEqual(AudiobookCreateSummary.processingSeconds(for: book, voice: "ming:US_James"), 600 * 3.2 + 60, accuracy: 0.001)
    }

    func test_notices_flagDuplicatesAndCostEnvelope() {
        var book = estimate()
        book = AudiobookEstimateResponse(
            bookID: "book", title: "A", pageCount: 3, wordCountEstimate: 900,
            estimatedProcessingSeconds: 40, estimatedAudioSeconds: 600, estimatedCostUsd: 0.5,
            maximumCostUsd: 2, estimatedTokenCount: 1000, isImageOnly: false, costWarning: true,
            duplicateOfBookID: "other", duplicateOfTitle: "Earlier"
        )

        let notices = AudiobookCreateSummary.notices(for: book, useCleanup: true, hasProvider: true, providerName: "Gemini", isWebPage: true)

        XCTAssertEqual(notices.count, 2)
        XCTAssertTrue(notices[0].text.contains("$2.00"))
        XCTAssertTrue(notices[1].text.contains("page"))
        XCTAssertTrue(AudiobookCreateSummary.notices(for: book, useCleanup: false, hasProvider: false, providerName: "", isWebPage: false).count == 1)
    }

    func test_cleanupCostLabel_coversOffFreeAndPaid() {
        XCTAssertEqual(AudiobookCreateSummary.cleanupCostLabel(for: estimate(cost: 0.5), useCleanup: false), "Off")
        XCTAssertEqual(AudiobookCreateSummary.cleanupCostLabel(for: estimate(cost: 0), useCleanup: true), "Free")
        XCTAssertEqual(AudiobookCreateSummary.cleanupCostLabel(for: estimate(cost: 0.5), useCleanup: true), "$0.50")
        XCTAssertEqual(AudiobookCreateSummary.formatCost(0.001), "< $0.01")
    }

    func test_characterSummary_countsCharactersAndWords() {
        XCTAssertEqual(AudiobookCreateSummary.characterSummary(of: "one two  three"), "14 characters · 3 words")
    }
}
