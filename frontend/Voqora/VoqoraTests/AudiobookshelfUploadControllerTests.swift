import Foundation
@testable import Voqora
import XCTest

@MainActor
final class AudiobookshelfUploadControllerTests: XCTestCase {
    private struct Notice: Equatable {
        let message: String
        let kind: AudiobookViewModel.Toast.Kind
    }

    private var directory: URL!
    private var notices: [Notice] = []
    private var uploads: [AudiobookshelfUpload] = []
    private var renderedFiles: [URL] = []
    private let destination = AudiobookshelfDestination(
        server: URL(string: "https://abs.example.com")!,
        token: "tok",
        libraryID: "lib1",
        folderID: "f1"
    )

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ShelfUploadTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        notices = []
        uploads = []
        renderedFiles = []
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeController(
        configured: Bool = true,
        renderError: Error? = nil,
        uploadError: Error? = nil
    ) -> AudiobookshelfUploadController {
        let resolved = configured ? destination : nil
        let dependencies = AudiobookshelfUploadController.Dependencies(
            destination: { resolved },
            render: { [weak self] _, file, progress in
                self?.renderedFiles.append(file)
                if let renderError {
                    throw renderError
                }
                try Data("AUDIO".utf8).write(to: file)
                progress(1)
            },
            upload: { [weak self] upload, progress in
                self?.uploads.append(upload)
                XCTAssertTrue(FileManager.default.fileExists(atPath: upload.file.path))
                progress(0.5)
                if let uploadError {
                    throw uploadError
                }
            },
            temporaryDirectory: directory,
            notify: { [weak self] message, kind in
                self?.notices.append(Notice(message: message, kind: kind))
            }
        )
        return AudiobookshelfUploadController(dependencies: dependencies)
    }

    func test_successfulUploadExportsThenUploadsAndCleansUp() async throws {
        let controller = makeController()
        let book = makeTestAudiobook()

        controller.upload(book)
        XCTAssertTrue(controller.isUploading(book))
        XCTAssertEqual(controller.progress(for: book), 0)
        await controller.waitUntilFinished()

        let upload = try XCTUnwrap(uploads.first)
        XCTAssertEqual(upload.destination, destination)
        XCTAssertEqual(upload.title, "Test Book")
        XCTAssertEqual(upload.file.lastPathComponent, "Test Book.m4b")
        XCTAssertEqual(renderedFiles, [upload.file])
        XCTAssertFalse(FileManager.default.fileExists(atPath: upload.file.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
        XCTAssertEqual(notices.last, Notice(message: "Uploaded Test Book to Audiobookshelf.", kind: .success))
        XCTAssertNil(controller.active)
    }

    func test_notConfiguredExplainsWhatToDo() {
        let controller = makeController(configured: false)

        controller.upload(makeTestAudiobook())

        XCTAssertNil(controller.active)
        XCTAssertEqual(notices, [Notice(message: AudiobookshelfError.notConfigured.errorDescription ?? "", kind: .error)])
    }

    func test_unfinishedBooksCannotBeUploaded() {
        let controller = makeController()

        controller.upload(makeTestAudiobook(status: "processing"))

        XCTAssertNil(controller.active)
        XCTAssertEqual(notices.first?.kind, .error)
    }

    func test_uploadErrorsAreShownAndTheTempFileIsRemoved() async throws {
        let controller = makeController(uploadError: AudiobookshelfError.uploadNotAllowed)

        controller.upload(makeTestAudiobook())
        await controller.waitUntilFinished()

        XCTAssertEqual(notices.last, Notice(message: AudiobookshelfError.uploadNotAllowed.errorDescription ?? "", kind: .error))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func test_exportErrorsSkipTheUpload() async {
        let controller = makeController(renderError: M4BExportError.encodingFailed)

        controller.upload(makeTestAudiobook())
        await controller.waitUntilFinished()

        XCTAssertTrue(uploads.isEmpty)
        XCTAssertEqual(notices.last, Notice(message: M4BExportError.encodingFailed.errorDescription ?? "", kind: .error))
    }

    func test_cancellationIsReportedQuietly() async {
        let controller = makeController(renderError: CancellationError())

        controller.upload(makeTestAudiobook())
        await controller.waitUntilFinished()

        XCTAssertEqual(notices.last, Notice(message: "Upload cancelled.", kind: .info))
    }

    func test_secondUploadWhileBusyIsRefused() async {
        let controller = makeController()

        controller.upload(makeTestAudiobook(id: "a"))
        controller.upload(makeTestAudiobook(id: "b"))
        await controller.waitUntilFinished()

        XCTAssertEqual(uploads.count, 1)
        XCTAssertTrue(notices.contains(Notice(message: "Another upload is still running.", kind: .info)))
    }

    func test_progressSplitsBetweenExportAndUpload() {
        XCTAssertEqual(AudiobookshelfUploadController.overallProgress(stage: .exporting, fraction: 0.5), 0.2, accuracy: 0.0001)
        XCTAssertEqual(AudiobookshelfUploadController.overallProgress(stage: .uploading, fraction: 0), 0.4, accuracy: 0.0001)
        XCTAssertEqual(AudiobookshelfUploadController.overallProgress(stage: .uploading, fraction: 2), 1, accuracy: 0.0001)
    }
}
