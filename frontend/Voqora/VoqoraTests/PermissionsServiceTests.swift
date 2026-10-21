@testable import Voqora
import XCTest

private final class PermissionsStubAuthorizer: DictationAuthorizing {
    var microphone: DictationPermissionStatus
    var speech: DictationPermissionStatus
    private(set) var microphoneRequests = 0
    private(set) var speechRequests = 0

    init(microphone: DictationPermissionStatus = .notDetermined, speech: DictationPermissionStatus = .notDetermined) {
        self.microphone = microphone
        self.speech = speech
    }

    func microphoneStatus() -> DictationPermissionStatus {
        microphone
    }

    func requestMicrophoneAccess() async -> Bool {
        microphoneRequests += 1
        microphone = .granted
        return true
    }

    func speechRecognitionStatus() -> DictationPermissionStatus {
        speech
    }

    func requestSpeechRecognitionAccess() async -> Bool {
        speechRequests += 1
        speech = .granted
        return true
    }
}

@MainActor
final class PermissionsServiceTests: XCTestCase {
    func test_init_readsAccessibilityStateImmediately() {
        let svc = PermissionsService()
        XCTAssertEqual(svc.accessibilityGranted, AXIsProcessTrusted())
    }

    func test_init_notificationsStatusIsUnknownInTestRunner() async {
        let svc = PermissionsService()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(svc.notificationsStatus, .unknown)
    }

    func test_requestNotifications_isNoOpInTestRunner() async {
        let svc = PermissionsService()
        await svc.requestNotifications()
        XCTAssertEqual(svc.notificationsStatus, .unknown)
    }

    func test_startPolling_doesNotCrash() {
        let svc = PermissionsService()
        svc.startPolling()
        svc.stopPolling()
    }

    func test_scheduleNotification_isNoOpInTestRunner() {
        let svc = PermissionsService()
        svc.scheduleNotification(title: "Test", body: "Test body")
        XCTAssertEqual(svc.notificationsStatus, .unknown)
    }

    func test_microphoneStatusMapsFromAuthorizer() {
        let authorizer = PermissionsStubAuthorizer(microphone: .granted, speech: .denied)
        let svc = PermissionsService(authorizer: authorizer, screenRecordingProbe: { false }, openURL: { _ in })
        XCTAssertEqual(svc.microphoneStatus, .granted)
        XCTAssertEqual(svc.state(for: .microphone), .granted)
        XCTAssertEqual(svc.state(for: .speechRecognition), .denied)
        authorizer.microphone = .notDetermined
        svc.refreshDeviceAccess()
        XCTAssertEqual(svc.state(for: .microphone), .notDetermined)
    }

    func test_screenRecordingStateFollowsProbe() {
        var granted = false
        let svc = PermissionsService(
            authorizer: PermissionsStubAuthorizer(),
            screenRecordingProbe: { granted },
            openURL: { _ in }
        )
        XCTAssertEqual(svc.state(for: .screenRecording), .denied)
        granted = true
        svc.refreshDeviceAccess()
        XCTAssertEqual(svc.state(for: .screenRecording), .granted)
    }

    func test_deniedKindOpensSettingsInsteadOfRequesting() async {
        let authorizer = PermissionsStubAuthorizer(microphone: .denied, speech: .denied)
        var opened: [URL] = []
        let svc = PermissionsService(
            authorizer: authorizer,
            screenRecordingProbe: { false },
            openURL: { opened.append($0) }
        )
        await svc.request(.microphone)
        await svc.request(.speechRecognition)
        await svc.request(.screenRecording)
        XCTAssertEqual(authorizer.microphoneRequests, 0)
        XCTAssertEqual(authorizer.speechRequests, 0)
        XCTAssertEqual(opened, [
            PermissionKind.microphone.settingsURL,
            PermissionKind.speechRecognition.settingsURL,
            PermissionKind.screenRecording.settingsURL,
        ].compactMap(\.self))
    }

    func test_notDeterminedKindRequestsThroughAuthorizer() async {
        let authorizer = PermissionsStubAuthorizer()
        var opened: [URL] = []
        let svc = PermissionsService(
            authorizer: authorizer,
            screenRecordingProbe: { false },
            openURL: { opened.append($0) }
        )
        await svc.request(.microphone)
        await svc.request(.speechRecognition)
        XCTAssertEqual(authorizer.microphoneRequests, 1)
        XCTAssertEqual(authorizer.speechRequests, 1)
        XCTAssertEqual(svc.state(for: .microphone), .granted)
        XCTAssertEqual(svc.state(for: .speechRecognition), .granted)
        XCTAssertTrue(opened.isEmpty)
    }

    func test_onlyAccessibilityIsRequired() {
        XCTAssertEqual(PermissionKind.allCases.filter(\.isRequired), [.accessibility])
    }

    func test_everyKindHasCopyAndSettingsURL() {
        for kind in PermissionKind.allCases {
            XCTAssertFalse(kind.title.isEmpty)
            XCTAssertFalse(kind.purpose.isEmpty)
            XCTAssertNotNil(kind.settingsURL)
        }
        XCTAssertTrue(PermissionKind.screenRecording.settingsURL?.absoluteString.hasSuffix("Privacy_ScreenCapture") == true)
    }
}
