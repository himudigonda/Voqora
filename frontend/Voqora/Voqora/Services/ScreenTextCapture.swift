import AppKit
import CoreGraphics
import Foundation
import Vision

@MainActor
protocol ScreenRegionCapturing {
    func captureRegion(to imageURL: URL) async throws
}

@MainActor
protocol ScreenTextRecognizing {
    func recognizeLines(in imageURL: URL, preferredLanguages: [String]) async throws -> [OCRLine]
}

@MainActor
protocol ScreenCapturePermissionHandling {
    func hasAccess() -> Bool
    func requestAccess() -> Bool
    func openSettings()
}

struct SystemScreenRegionCapturer: ScreenRegionCapturing {
    nonisolated static let executablePath = "/usr/sbin/screencapture"

    func captureRegion(to imageURL: URL) async throws {
        let path = imageURL.path
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let exitStatus = try SystemScreenRegionCapturer.runInteractiveCapture(to: path)
                    continuation.resume(returning: exitStatus)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        VoqoraLog.debug("ScreenTextCapture", "Interactive capture finished", ["status": "\(status)"])
    }

    nonisolated static func runInteractiveCapture(to path: String) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = ["-i", "-x", path]
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}

struct VisionScreenTextRecognizer: ScreenTextRecognizing {
    func recognizeLines(in imageURL: URL, preferredLanguages: [String]) async throws -> [OCRLine] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let lines = try VisionScreenTextRecognizer.performRecognition(in: imageURL, preferredLanguages: preferredLanguages)
                    continuation.resume(returning: lines)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    nonisolated static func performRecognition(in imageURL: URL, preferredLanguages: [String]) throws -> [OCRLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        let available = (try? request.supportedRecognitionLanguages()) ?? []
        let languages = OCRLanguagePreference.supported(preferredLanguages, available: available)
        if !languages.isEmpty {
            request.recognitionLanguages = languages
        }
        let handler = VNImageRequestHandler(url: imageURL, options: [:])
        try handler.perform([request])
        return (request.results ?? []).compactMap { observation -> OCRLine? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return OCRLine(text: candidate.string, bounds: observation.boundingBox)
        }
    }
}

struct SystemScreenCapturePermission: ScreenCapturePermissionHandling {
    private static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")

    func hasAccess() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    func requestAccess() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    func openSettings() {
        guard let url = Self.settingsURL else { return }
        NSWorkspace.shared.open(url)
    }
}
