import AVFoundation
import Foundation
import Speech

nonisolated enum DictationPermissionStatus: Equatable, Sendable {
    case notDetermined
    case granted
    case denied
}

@MainActor
protocol DictationAuthorizing {
    func microphoneStatus() -> DictationPermissionStatus
    func requestMicrophoneAccess() async -> Bool
    func speechRecognitionStatus() -> DictationPermissionStatus
    func requestSpeechRecognitionAccess() async -> Bool
}

struct DictationPermissionGate {
    let authorizer: any DictationAuthorizing
    var requiresSpeechRecognition = true

    func missingAccess() async -> DictationIssue? {
        switch authorizer.microphoneStatus() {
        case .granted:
            break
        case .denied:
            return .microphoneDenied
        case .notDetermined:
            guard await authorizer.requestMicrophoneAccess() else { return .microphoneDenied }
        }
        guard requiresSpeechRecognition else { return nil }
        switch authorizer.speechRecognitionStatus() {
        case .granted:
            break
        case .denied:
            return .speechRecognitionDenied
        case .notDetermined:
            guard await authorizer.requestSpeechRecognitionAccess() else { return .speechRecognitionDenied }
        }
        return nil
    }
}

struct SystemDictationAuthorizer: DictationAuthorizing {
    func microphoneStatus() -> DictationPermissionStatus {
        Self.status(for: AVCaptureDevice.authorizationStatus(for: .audio))
    }

    func requestMicrophoneAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    func speechRecognitionStatus() -> DictationPermissionStatus {
        Self.status(for: SFSpeechRecognizer.authorizationStatus())
    }

    func requestSpeechRecognitionAccess() async -> Bool {
        await SpeechAuthorization.request() == .authorized
    }

    private static func status(for authorization: AVAuthorizationStatus) -> DictationPermissionStatus {
        switch authorization {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        case .denied, .restricted: .denied
        @unknown default: .denied
        }
    }

    private static func status(for authorization: SFSpeechRecognizerAuthorizationStatus) -> DictationPermissionStatus {
        switch authorization {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        case .denied, .restricted: .denied
        @unknown default: .denied
        }
    }
}

nonisolated enum SpeechAuthorization {
    static func request() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }
}
