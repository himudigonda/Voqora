@testable import Voqora
import XCTest

@MainActor
private final class StubAuthorizer: DictationAuthorizing {
    var microphone: DictationPermissionStatus
    var speech: DictationPermissionStatus
    var grantsMicrophone = true
    var grantsSpeech = true
    private(set) var microphoneRequests = 0
    private(set) var speechRequests = 0

    init(microphone: DictationPermissionStatus = .granted, speech: DictationPermissionStatus = .granted) {
        self.microphone = microphone
        self.speech = speech
    }

    func microphoneStatus() -> DictationPermissionStatus {
        microphone
    }

    func requestMicrophoneAccess() async -> Bool {
        microphoneRequests += 1
        return grantsMicrophone
    }

    func speechRecognitionStatus() -> DictationPermissionStatus {
        speech
    }

    func requestSpeechRecognitionAccess() async -> Bool {
        speechRequests += 1
        return grantsSpeech
    }
}

@MainActor
final class DictationRecognitionTests: XCTestCase {
    func test_onDeviceRouteIsPreferredWheneverSupported() throws {
        XCTAssertEqual(try RecognitionRoute.resolve(isAvailable: true, supportsOnDevice: true, allowsServer: false), .onDevice)
        XCTAssertEqual(try RecognitionRoute.resolve(isAvailable: true, supportsOnDevice: true, allowsServer: true), .onDevice)
    }

    func test_serverRouteRequiresExplicitOptIn() {
        XCTAssertThrowsError(try RecognitionRoute.resolve(isAvailable: true, supportsOnDevice: false, allowsServer: false)) { error in
            XCTAssertEqual(error as? DictationIssue, .onDeviceUnavailable)
        }
        XCTAssertEqual(try? RecognitionRoute.resolve(isAvailable: true, supportsOnDevice: false, allowsServer: true), .server)
    }

    func test_unavailableRecognizerIsReported() {
        XCTAssertThrowsError(try RecognitionRoute.resolve(isAvailable: false, supportsOnDevice: true, allowsServer: false)) { error in
            XCTAssertEqual(error as? DictationIssue, .recognizerUnavailable)
        }
        XCTAssertThrowsError(try RecognitionRoute.resolve(isAvailable: false, supportsOnDevice: false, allowsServer: true)) { error in
            XCTAssertEqual(error as? DictationIssue, .recognizerUnavailable)
        }
    }

    func test_recognitionCallbacksMapToEvents() {
        XCTAssertEqual(SpeechRecognitionEvent.from(transcript: "Hi", isFinal: false, hasError: false), .transcript("Hi", isFinal: false))
        XCTAssertEqual(SpeechRecognitionEvent.from(transcript: "Hi.", isFinal: true, hasError: false), .transcript("Hi.", isFinal: true))
        XCTAssertEqual(SpeechRecognitionEvent.from(transcript: nil, isFinal: false, hasError: true), .failed)
        XCTAssertNil(SpeechRecognitionEvent.from(transcript: nil, isFinal: false, hasError: false))
    }

    func test_permissionGatePassesWhenEverythingIsGranted() async {
        let authorizer = StubAuthorizer()

        let missing = await DictationPermissionGate(authorizer: authorizer).missingAccess()

        XCTAssertNil(missing)
        XCTAssertEqual(authorizer.microphoneRequests, 0)
        XCTAssertEqual(authorizer.speechRequests, 0)
    }

    func test_permissionGateAsksOnlyWhenUndetermined() async {
        let authorizer = StubAuthorizer(microphone: .notDetermined, speech: .notDetermined)

        let missing = await DictationPermissionGate(authorizer: authorizer).missingAccess()

        XCTAssertNil(missing)
        XCTAssertEqual(authorizer.microphoneRequests, 1)
        XCTAssertEqual(authorizer.speechRequests, 1)
    }

    func test_deniedMicrophoneStopsBeforeAskingForSpeech() async {
        let authorizer = StubAuthorizer(microphone: .denied, speech: .notDetermined)

        let missing = await DictationPermissionGate(authorizer: authorizer).missingAccess()

        XCTAssertEqual(missing, .microphoneDenied)
        XCTAssertEqual(missing?.settingsPane, .microphone)
        XCTAssertEqual(authorizer.speechRequests, 0)
    }

    func test_declinedSpeechPromptIsReportedWithSettingsShortcut() async {
        let authorizer = StubAuthorizer(speech: .notDetermined)
        authorizer.grantsSpeech = false

        let missing = await DictationPermissionGate(authorizer: authorizer).missingAccess()

        XCTAssertEqual(missing, .speechRecognitionDenied)
        XCTAssertEqual(missing?.settingsPane?.url?.absoluteString, "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")
    }
}
