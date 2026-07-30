@testable import Voqora
import XCTest

final class AudiobookServiceTests: XCTestCase {
    func test_mimeTypeMatchesEverySupportedAudiobookDocumentKind() {
        XCTAssertEqual(AudiobookService.mimeType(forFileExtension: "pdf"), "application/pdf")
        XCTAssertEqual(
            AudiobookService.mimeType(forFileExtension: "docx"),
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        )
        XCTAssertEqual(AudiobookService.mimeType(forFileExtension: "txt"), "text/plain; charset=utf-8")
        XCTAssertEqual(AudiobookService.mimeType(forFileExtension: "MD"), "text/plain; charset=utf-8")
    }

    func test_unknownMimeTypeFallsBackSafely() {
        XCTAssertEqual(AudiobookService.mimeType(forFileExtension: "rtf"), "application/octet-stream")
    }
}
