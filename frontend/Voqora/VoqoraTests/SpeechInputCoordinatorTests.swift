import AppKit
import CoreGraphics
import Foundation
@testable import Voqora
import XCTest

private struct SpokenRequest: Equatable {
    let text: String
    let voice: String?
}

@MainActor
private final class SpeakerSpy: SpeechInputSpeaking {
    var isBackendOnline = true
    var selectedVoice = "ff_siwis"
    var speechSpeed = 1.25
    private(set) var spoken: [SpokenRequest] = []
    private(set) var errors: [String] = []
    private(set) var toggleCount = 0
    private(set) var stopCount = 0

    func speak(text: String, voice: String?) async {
        spoken.append(SpokenRequest(text: text, voice: voice))
    }

    func togglePlayback() {
        toggleCount += 1
    }

    func stopPlayback() {
        stopCount += 1
    }

    func showTransientError(_ message: String) {
        errors.append(message)
    }
}

@MainActor
private final class LibrarySpy: LibraryTextImporting {
    var defaultBookVoice = "ef_dora"
    private(set) var importedContents: [String] = []
    private(set) var importedNames: [String] = []
    private(set) var importedVoice: String?
    private(set) var importedSpeed: Double?

    func importDocument(_ url: URL, defaultVoice: String, defaultSpeed: Double) {
        importedContents.append((try? String(contentsOf: url, encoding: .utf8)) ?? "")
        importedNames.append(url.lastPathComponent)
        importedVoice = defaultVoice
        importedSpeed = defaultSpeed
    }
}

private struct StubError: Error {}

@MainActor
private final class CapturerStub: ScreenRegionCapturing {
    var writesImage = true
    var error: Error?
    private(set) var capturedURL: URL?

    func captureRegion(to imageURL: URL) async throws {
        capturedURL = imageURL
        if let error {
            throw error
        }
        if writesImage {
            try Data([0x89, 0x50, 0x4E, 0x47]).write(to: imageURL)
        }
    }
}

@MainActor
private final class RecognizerStub: ScreenTextRecognizing {
    var result: Result<[OCRLine], Error> = .success([])
    private(set) var receivedLanguages: [String]?
    private(set) var imageExistedDuringRecognition = false

    func recognizeLines(in imageURL: URL, preferredLanguages: [String]) async throws -> [OCRLine] {
        receivedLanguages = preferredLanguages
        imageExistedDuringRecognition = FileManager.default.fileExists(atPath: imageURL.path)
        return try result.get()
    }
}

@MainActor
private final class PermissionStub: ScreenCapturePermissionHandling {
    var granted = true
    var grantsOnRequest = false
    private(set) var requestCount = 0
    private(set) var openSettingsCount = 0

    func hasAccess() -> Bool {
        granted
    }

    func requestAccess() -> Bool {
        requestCount += 1
        return grantsOnRequest
    }

    func openSettings() {
        openSettingsCount += 1
    }
}

@MainActor
final class SpeechInputCoordinatorTests: XCTestCase {
    private var speaker: SpeakerSpy!
    private var library: LibrarySpy!
    private var capturer: CapturerStub!
    private var recognizer: RecognizerStub!
    private var permission: PermissionStub!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var root: URL!
    private var pasteboardText: String?
    private var libraryPresentations = 0

    override func setUpWithError() throws {
        try super.setUpWithError()
        speaker = SpeakerSpy()
        library = LibrarySpy()
        capturer = CapturerStub()
        recognizer = RecognizerStub()
        permission = PermissionStub()
        suiteName = "SpeechInputCoordinatorTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        root = FileManager.default.temporaryDirectory.appendingPathComponent("SpeechInputCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        pasteboardText = nil
        libraryPresentations = 0
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suiteName)
        speaker = nil
        library = nil
        capturer = nil
        recognizer = nil
        permission = nil
        defaults = nil
        root = nil
        try super.tearDownWithError()
    }

    private func makeCoordinator() -> SpeechInputCoordinator {
        SpeechInputCoordinator(
            speaker: speaker,
            library: library,
            presentLibrary: { [weak self] in self?.libraryPresentations += 1 },
            capturer: capturer,
            recognizer: recognizer,
            permission: permission,
            readPasteboardText: { [weak self] in self?.pasteboardText },
            defaults: defaults,
            temporaryDirectory: root
        )
    }

    private func rootContents() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.path)
    }

    func test_speakClipboardSpeaksTrimmedPasteboardText() async {
        pasteboardText = "  Hello from the clipboard.\n"

        let outcome = await makeCoordinator().speakClipboard()

        XCTAssertEqual(outcome, .started)
        XCTAssertEqual(speaker.spoken.map(\.text), ["Hello from the clipboard."])
        XCTAssertNil(speaker.spoken.first?.voice)
        XCTAssertTrue(speaker.errors.isEmpty)
    }

    func test_speakClipboardWithoutTextReportsError() async {
        pasteboardText = " \n "

        let outcome = await makeCoordinator().speakClipboard()

        XCTAssertEqual(outcome, .failed(SpeechInputCoordinator.Message.noClipboardText))
        XCTAssertTrue(speaker.spoken.isEmpty)
        XCTAssertEqual(speaker.errors, [SpeechInputCoordinator.Message.noClipboardText])
    }

    func test_speakRejectsUnknownVoice() async {
        let outcome = await makeCoordinator().speak("Hello", voice: "xx_missing")

        XCTAssertEqual(outcome, .failed(SpeechInputCoordinator.Message.unknownVoice))
        XCTAssertTrue(speaker.spoken.isEmpty)
    }

    func test_speakPassesChosenVoice() async {
        let outcome = await makeCoordinator().speak("Bonjour", voice: "ff_siwis")

        XCTAssertEqual(outcome, .started)
        XCTAssertEqual(speaker.spoken.first?.voice, "ff_siwis")
    }

    func test_speakWhileEngineStartingStillRequestsSpeechButReportsFailure() async {
        speaker.isBackendOnline = false

        let outcome = await makeCoordinator().speak("Hello")

        XCTAssertEqual(outcome, .failed(SpeechInputCoordinator.Message.engineStarting))
        XCTAssertEqual(speaker.spoken.count, 1)
        XCTAssertTrue(speaker.errors.isEmpty)
    }

    func test_screenTextIsRecognizedAssembledSpokenAndImageDeleted() async throws {
        recognizer.result = .success([
            OCRLine(text: "Screen capture is hy-", bounds: CGRect(x: 0.1, y: 0.86, width: 0.8, height: 0.04)),
            OCRLine(text: "phenated here.", bounds: CGRect(x: 0.1, y: 0.81, width: 0.8, height: 0.04)),
        ])

        let outcome = await makeCoordinator().speakScreenText()

        XCTAssertEqual(outcome, .started)
        XCTAssertEqual(speaker.spoken.map(\.text), ["Screen capture is hyphenated here."])
        XCTAssertEqual(recognizer.receivedLanguages, ["fr-FR", "es-ES", "en-US"])
        XCTAssertTrue(recognizer.imageExistedDuringRecognition)
        let capturedURL = try XCTUnwrap(capturer.capturedURL)
        XCTAssertEqual(capturedURL.deletingLastPathComponent().standardizedFileURL, root.standardizedFileURL)
        XCTAssertTrue(capturedURL.lastPathComponent.hasPrefix(SpeechInputCoordinator.captureFilePrefix))
        XCTAssertEqual(try rootContents(), [])
    }

    func test_cancelledCaptureIsSilent() async throws {
        capturer.writesImage = false

        let outcome = await makeCoordinator().speakScreenText()

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertNil(recognizer.receivedLanguages)
        XCTAssertTrue(speaker.spoken.isEmpty)
        XCTAssertTrue(speaker.errors.isEmpty)
        XCTAssertEqual(try rootContents(), [])
    }

    func test_captureLaunchFailureReportsError() async {
        capturer.error = StubError()

        let outcome = await makeCoordinator().speakScreenText()

        XCTAssertEqual(outcome, .failed(SpeechInputCoordinator.Message.captureFailed))
        XCTAssertEqual(speaker.errors, [SpeechInputCoordinator.Message.captureFailed])
    }

    func test_recognitionFailureReportsErrorAndDeletesImage() async throws {
        recognizer.result = .failure(StubError())

        let outcome = await makeCoordinator().speakScreenText()

        XCTAssertEqual(outcome, .failed(SpeechInputCoordinator.Message.recognitionFailed))
        XCTAssertTrue(speaker.spoken.isEmpty)
        XCTAssertEqual(try rootContents(), [])
    }

    func test_captureWithNoTextReportsError() async {
        recognizer.result = .success([OCRLine(text: "   ", bounds: CGRect(x: 0, y: 0, width: 0.2, height: 0.02))])

        let outcome = await makeCoordinator().speakScreenText()

        XCTAssertEqual(outcome, .failed(SpeechInputCoordinator.Message.noScreenText))
        XCTAssertTrue(speaker.spoken.isEmpty)
    }

    func test_firstScreenRecordingDenialOnlyShowsSystemPrompt() async {
        permission.granted = false

        let outcome = await makeCoordinator().speakScreenText()

        XCTAssertEqual(outcome, .failed(SpeechInputCoordinator.Message.screenAccessPrompt))
        XCTAssertEqual(permission.requestCount, 1)
        XCTAssertEqual(permission.openSettingsCount, 0)
        XCTAssertNil(capturer.capturedURL)
        XCTAssertTrue(defaults.bool(forKey: SpeechInputCoordinator.screenCaptureRequestedKey))
    }

    func test_laterScreenRecordingDenialOpensSystemSettings() async {
        permission.granted = false
        defaults.set(true, forKey: SpeechInputCoordinator.screenCaptureRequestedKey)

        let outcome = await makeCoordinator().speakScreenText()

        XCTAssertEqual(outcome, .failed(SpeechInputCoordinator.Message.screenAccessSettings))
        XCTAssertEqual(permission.openSettingsCount, 1)
        XCTAssertNil(capturer.capturedURL)
    }

    func test_grantedOnRequestContinuesToCapture() async {
        permission.granted = false
        permission.grantsOnRequest = true
        capturer.writesImage = false

        let outcome = await makeCoordinator().speakScreenText()

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertNotNil(capturer.capturedURL)
    }

    func test_addToLibraryImportsTextFileAndCleansUp() throws {
        let outcome = makeCoordinator().addToLibrary("  A Short Story\nOnce upon a time.  ")

        XCTAssertEqual(outcome, .started)
        XCTAssertEqual(library.importedContents, ["A Short Story\nOnce upon a time."])
        XCTAssertEqual(library.importedNames, ["A Short Story.txt"])
        XCTAssertEqual(library.importedVoice, "ff_siwis")
        XCTAssertEqual(library.importedSpeed, 1.25)
        XCTAssertEqual(libraryPresentations, 1)
        XCTAssertEqual(try rootContents(), [])
    }

    func test_addToLibraryRejectsEmptyText() {
        let outcome = makeCoordinator().addToLibrary(" \n\t ")

        XCTAssertEqual(outcome, .failed(SpeechInputCoordinator.Message.noText))
        XCTAssertTrue(library.importedContents.isEmpty)
        XCTAssertEqual(libraryPresentations, 0)
    }

    func test_playbackControlsForwardToSpeaker() {
        let coordinator = makeCoordinator()
        coordinator.togglePlayback()
        coordinator.stopPlayback()

        XCTAssertEqual(speaker.toggleCount, 1)
        XCTAssertEqual(speaker.stopCount, 1)
    }

    func test_servicesTextIsTrimmedAndRejectsBlankPasteboard() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("SpeechInputCoordinatorTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        pasteboard.clearContents()
        pasteboard.setString("  Selected words \n", forType: .string)
        XCTAssertEqual(VoqoraServicesProvider.serviceText(from: pasteboard), "Selected words")

        pasteboard.clearContents()
        pasteboard.setString("   ", forType: .string)
        XCTAssertNil(VoqoraServicesProvider.serviceText(from: pasteboard))
    }

    func test_intentOutcomeThrowsOnlyForFailures() {
        XCTAssertNoThrow(try SpeechInputOutcome.started.requireSuccess())
        XCTAssertNoThrow(try SpeechInputOutcome.cancelled.requireSuccess())
        XCTAssertThrowsError(try SpeechInputOutcome.failed("Nope").requireSuccess()) { error in
            XCTAssertEqual((error as? VoqoraIntentError)?.message, "Nope")
        }
    }

    func test_intentsReportNotRunningWithoutActiveCoordinator() {
        let expected = SpeechInputCoordinator.Message.notRunning
        XCTAssertThrowsError(try SpeechInputCoordinator.requireActive()) { error in
            XCTAssertEqual((error as? VoqoraIntentError)?.message, expected)
        }
    }

    func test_voiceEntitiesMirrorTheVoiceCatalog() async throws {
        XCTAssertEqual(VoqoraVoiceEntity.all.map(\.id), DashboardViewModel.voiceCatalog.map(\.id))
        let found = try await VoqoraVoiceQuery().entities(for: ["bf_emma", "missing"])
        XCTAssertEqual(found.map(\.id), ["bf_emma"])
    }
}
