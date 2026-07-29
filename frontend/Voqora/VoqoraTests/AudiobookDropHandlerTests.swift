@testable import Voqora
import UniformTypeIdentifiers
import XCTest

/// the v1.1 design notes Sprint 7, T7.9/E10: `handleDrop` previously only ever processed
/// `providers.first` — dragging 3 files onto the library (a normal Finder
/// gesture) silently dropped 2 of them. These tests drive the extracted,
/// View-independent `AudiobookDropHandler` directly with real `NSItemProvider`
/// instances backed by real temp files (no mocking needed: `NSItemProvider`
/// natively supports being constructed from an in-memory/local item for
/// exactly this kind of use).
final class AudiobookDropHandlerTests: XCTestCase {
    private var tempFiles: [URL] = []

    override func tearDown() {
        for url in tempFiles {
            try? FileManager.default.removeItem(at: url)
        }
        tempFiles = []
        super.tearDown()
    }

    private func makeTempFile(extension ext: String = "txt", contents: String = "hello") -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("drop-test-\(UUID().uuidString)")
            .appendingPathExtension(ext)
        try? Data(contents.utf8).write(to: url)
        tempFiles.append(url)
        return url
    }

    private func provider(for url: URL) -> NSItemProvider {
        NSItemProvider(item: url as NSURL, typeIdentifier: UTType.fileURL.identifier)
    }

    // MARK: - The core E10 regression

    func test_handleDrop_withThreeProviders_reportsAllThreeURLs() {
        let urls = (0 ..< 3).map { _ in makeTempFile() }
        let providers = urls.map(provider(for:))

        let expectation = expectation(description: "all three URLs reported")
        expectation.expectedFulfillmentCount = 3

        let accepted = AudiobookDropHandler.handle(providers: providers) { _ in
            expectation.fulfill()
        } onError: { _, error in
            XCTFail("unexpected error for a real, readable temp file: \(error)")
        }

        XCTAssertTrue(accepted, "a non-empty provider list must be accepted")
        wait(for: [expectation], timeout: 3.0)
    }

    func test_handleDrop_withSingleProvider_stillWorks() {
        let url = makeTempFile()
        let expectation = expectation(description: "single URL reported")

        _ = AudiobookDropHandler.handle(providers: [provider(for: url)]) { _ in
            expectation.fulfill()
        } onError: { _, error in
            XCTFail("unexpected error: \(error)")
        }

        wait(for: [expectation], timeout: 3.0)
    }

    // MARK: - Edge cases

    func test_handleDrop_withNoProviders_declinesAndReportsNothing() {
        let accepted = AudiobookDropHandler.handle(providers: []) { _ in
            XCTFail("onURL must not fire for an empty provider list")
        } onError: { _, _ in
            XCTFail("onError must not fire for an empty provider list")
        }
        XCTAssertFalse(accepted)
    }

    func test_handleDrop_skipsDisallowedExtension() {
        let url = makeTempFile(extension: "exe")
        let notCalled = expectation(description: "onURL/onError must not fire for a disallowed extension")
        notCalled.isInverted = true

        _ = AudiobookDropHandler.handle(providers: [provider(for: url)]) { _ in
            notCalled.fulfill()
        } onError: { _, _ in
            notCalled.fulfill()
        }

        wait(for: [notCalled], timeout: 0.5)
    }

    func test_handleDrop_acceptsEachAllowedExtension() {
        let urls = AudiobookDropHandler.allowedExtensions.sorted().map { makeTempFile(extension: $0) }
        let providers = urls.map(provider(for:))

        let expectation = expectation(description: "one URL per allowed extension")
        expectation.expectedFulfillmentCount = urls.count

        _ = AudiobookDropHandler.handle(providers: providers) { _ in
            expectation.fulfill()
        } onError: { _, error in
            XCTFail("unexpected error: \(error)")
        }

        wait(for: [expectation], timeout: 3.0)
    }
}
