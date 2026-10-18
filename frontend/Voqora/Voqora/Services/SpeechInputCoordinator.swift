import AppKit
import Foundation

nonisolated enum SpeechInputOutcome: Equatable, Sendable {
    case started
    case cancelled
    case failed(String)
}

@MainActor
protocol SpeechInputSpeaking: AnyObject {
    var isBackendOnline: Bool { get }
    var selectedVoice: String { get }
    var speechSpeed: Double { get }
    func speak(text: String, voice: String?) async
    func togglePlayback()
    func stopPlayback()
    func showTransientError(_ message: String)
}

@MainActor
protocol LibraryTextImporting: AnyObject {
    var defaultBookVoice: String { get }
    func importDocument(_ url: URL, defaultVoice: String, defaultSpeed: Double)
}

extension DashboardViewModel: SpeechInputSpeaking {}

extension AudiobookViewModel: LibraryTextImporting {}

@MainActor
final class SpeechInputCoordinator {
    enum Message {
        static let noText = "There is no text to read."
        static let noClipboardText = "Copy some text first, then try again."
        static let noScreenText = "Voqora found no text in that area. Try a larger selection."
        static let captureFailed = "Voqora could not start a screen capture. Try again."
        static let recognitionFailed = "Voqora could not read text from that capture. Try again."
        static let screenAccessPrompt = "Allow Screen Recording for Voqora when macOS asks, then try again."
        static let screenAccessSettings = "Voqora needs Screen Recording access to read text on screen. Turn it on in System Settings, then reopen Voqora."
        static let unknownVoice = "That voice is not available in Voqora."
        static let engineStarting = "Voqora is still starting. Try again in a moment."
        static let librarySaveFailed = "Voqora could not add that text to your library. Try again."
        static let notRunning = "Open Voqora, then try again."
    }

    static let screenCaptureRequestedKey = "screenCaptureAccessRequested"
    static let captureFilePrefix = "VoqoraCapture-"

    private(set) static var active: SpeechInputCoordinator?

    private let speaker: any SpeechInputSpeaking
    private let library: any LibraryTextImporting
    private let presentLibrary: @MainActor () -> Void
    private let capturer: any ScreenRegionCapturing
    private let recognizer: any ScreenTextRecognizing
    private let permission: any ScreenCapturePermissionHandling
    private let readPasteboardText: @MainActor () -> String?
    private let defaults: UserDefaults
    private let fileManager: FileManager
    private let temporaryDirectory: URL
    private(set) var isCapturing = false

    init(
        speaker: any SpeechInputSpeaking,
        library: any LibraryTextImporting,
        presentLibrary: @escaping @MainActor () -> Void,
        capturer: any ScreenRegionCapturing = SystemScreenRegionCapturer(),
        recognizer: any ScreenTextRecognizing = VisionScreenTextRecognizer(),
        permission: any ScreenCapturePermissionHandling = SystemScreenCapturePermission(),
        readPasteboardText: @escaping @MainActor () -> String? = { NSPasteboard.general.string(forType: .string) },
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        self.speaker = speaker
        self.library = library
        self.presentLibrary = presentLibrary
        self.capturer = capturer
        self.recognizer = recognizer
        self.permission = permission
        self.readPasteboardText = readPasteboardText
        self.defaults = defaults
        self.fileManager = fileManager
        self.temporaryDirectory = temporaryDirectory
    }

    func activate() {
        Self.active = self
    }

    @discardableResult
    func speak(_ text: String, voice: String? = nil) async -> SpeechInputOutcome {
        guard let trimmed = Self.readableText(text) else {
            return fail(Message.noText)
        }
        if let voice, DashboardViewModel.voicesByID[voice] == nil {
            return fail(Message.unknownVoice)
        }
        return await deliver(trimmed, voice: voice)
    }

    @discardableResult
    func speakClipboard() async -> SpeechInputOutcome {
        guard let text = readPasteboardText().flatMap(Self.readableText) else {
            return fail(Message.noClipboardText)
        }
        VoqoraLog.info("SpeechInputCoordinator", "Speaking clipboard", ["chars": "\(text.count)"])
        return await deliver(text, voice: nil)
    }

    @discardableResult
    func speakScreenText() async -> SpeechInputOutcome {
        guard !isCapturing else { return .cancelled }
        isCapturing = true
        defer { isCapturing = false }

        if let denial = screenCaptureDenial() {
            return fail(denial)
        }

        let imageURL = temporaryDirectory.appendingPathComponent("\(Self.captureFilePrefix)\(UUID().uuidString).png")
        defer { try? fileManager.removeItem(at: imageURL) }

        do {
            try await capturer.captureRegion(to: imageURL)
        } catch {
            VoqoraLog.error("SpeechInputCoordinator", "Screen capture could not start", ["failureCode": "screen_capture_launch_failed"])
            return fail(Message.captureFailed)
        }

        guard hasCapturedImage(at: imageURL) else {
            VoqoraLog.info("SpeechInputCoordinator", "Screen capture cancelled")
            return .cancelled
        }

        let lines: [OCRLine]
        do {
            let languages = OCRLanguagePreference.preferredLanguages(forVoices: [speaker.selectedVoice, library.defaultBookVoice])
            lines = try await recognizer.recognizeLines(in: imageURL, preferredLanguages: languages)
        } catch {
            VoqoraLog.error("SpeechInputCoordinator", "Text recognition failed", ["failureCode": "screen_text_recognition_failed"])
            return fail(Message.recognitionFailed)
        }

        let text = OCRTextAssembler.assemble(lines)
        guard !text.isEmpty else {
            VoqoraLog.info("SpeechInputCoordinator", "No text recognized in capture", ["lines": "\(lines.count)"])
            return fail(Message.noScreenText)
        }
        VoqoraLog.info("SpeechInputCoordinator", "Speaking recognized screen text", ["lines": "\(lines.count)", "chars": "\(text.count)"])
        return await deliver(text, voice: nil)
    }

    @discardableResult
    func addToLibrary(_ text: String) -> SpeechInputOutcome {
        guard let trimmed = Self.readableText(text) else {
            return fail(Message.noText)
        }
        let fileURL: URL
        do {
            fileURL = try LibraryTextDocument.write(trimmed, in: temporaryDirectory, fileManager: fileManager)
        } catch {
            VoqoraLog.error("SpeechInputCoordinator", "Could not write library text", ["failureCode": "library_text_write_failed"])
            return fail(Message.librarySaveFailed)
        }
        defer { try? fileManager.removeItem(at: fileURL.deletingLastPathComponent()) }

        VoqoraLog.info("SpeechInputCoordinator", "Adding text to library", ["chars": "\(trimmed.count)"])
        presentLibrary()
        library.importDocument(fileURL, defaultVoice: speaker.selectedVoice, defaultSpeed: speaker.speechSpeed)
        return .started
    }

    func togglePlayback() {
        speaker.togglePlayback()
    }

    func stopPlayback() {
        speaker.stopPlayback()
    }

    static func readableText(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func deliver(_ text: String, voice: String?) async -> SpeechInputOutcome {
        let engineReady = speaker.isBackendOnline
        await speaker.speak(text: text, voice: voice)
        return engineReady ? .started : .failed(Message.engineStarting)
    }

    private func screenCaptureDenial() -> String? {
        guard !permission.hasAccess() else { return nil }
        let askedBefore = defaults.bool(forKey: Self.screenCaptureRequestedKey)
        defaults.set(true, forKey: Self.screenCaptureRequestedKey)
        guard !permission.requestAccess() else { return nil }
        VoqoraLog.warn("SpeechInputCoordinator", "Screen Recording access missing", ["askedBefore": askedBefore ? "true" : "false"])
        guard askedBefore else { return Message.screenAccessPrompt }
        permission.openSettings()
        return Message.screenAccessSettings
    }

    private func hasCapturedImage(at url: URL) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { return false }
        return size.intValue > 0
    }

    private func fail(_ message: String) -> SpeechInputOutcome {
        speaker.showTransientError(message)
        return .failed(message)
    }
}
