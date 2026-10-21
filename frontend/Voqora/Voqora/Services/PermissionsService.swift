import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import Foundation
import SwiftUI
import UserNotifications

enum PermissionState: Equatable {
    case granted
    case denied
    case notDetermined
    case unknown
}

enum PermissionKind: String, CaseIterable, Identifiable {
    case accessibility
    case notifications
    case microphone
    case speechRecognition
    case screenRecording

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .accessibility: "Accessibility"
        case .notifications: "Notifications"
        case .microphone: "Microphone"
        case .speechRecognition: "Speech Recognition"
        case .screenRecording: "Screen Recording"
        }
    }

    var purpose: String {
        switch self {
        case .accessibility:
            "Lets Voqora read selected text and paste dictation into other apps."
        case .notifications:
            "Tells you when an audiobook is ready or a long job finishes."
        case .microphone:
            "Lets Voqora hear you while you dictate."
        case .speechRecognition:
            "Lets Apple's recognizer turn your speech into text."
        case .screenRecording:
            "Lets Voqora read text from a screen region when you ask it to."
        }
    }

    var isRequired: Bool {
        self == .accessibility
    }

    var settingsURL: URL? {
        switch self {
        case .accessibility: PrivacySettingsPane.accessibility.url
        case .microphone: PrivacySettingsPane.microphone.url
        case .speechRecognition: PrivacySettingsPane.speechRecognition.url
        case .screenRecording:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        case .notifications:
            URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
        }
    }
}

@MainActor
final class PermissionsService: ObservableObject {
    static let shared = PermissionsService()

    @Published private(set) var accessibilityGranted: Bool = false
    @Published private(set) var notificationsStatus: NotificationsStatus = .unknown
    @Published private(set) var microphoneStatus: DictationPermissionStatus = .notDetermined
    @Published private(set) var speechRecognitionStatus: DictationPermissionStatus = .notDetermined
    @Published private(set) var screenRecordingGranted: Bool = false

    enum NotificationsStatus: Equatable {
        case unknown // never asked, status not yet read
        case notDetermined // never asked
        case authorized // granted
        case denied // user said no, or system disabled
        case provisional // limited (rare on macOS)
    }

    var isNotificationsEnabled: Bool {
        notificationsStatus == .authorized || notificationsStatus == .provisional
    }

    private let authorizer: any DictationAuthorizing
    private let screenRecordingProbe: () -> Bool
    private let openURL: (URL) -> Void
    private var isRequestingNotifications = false
    private var pollTask: Task<Void, Never>?
    private var activationObserver: NSObjectProtocol?

    init(
        authorizer: (any DictationAuthorizing)? = nil,
        screenRecordingProbe: @escaping () -> Bool = { CGPreflightScreenCaptureAccess() },
        openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }
    ) {
        self.authorizer = authorizer ?? SystemDictationAuthorizer()
        self.screenRecordingProbe = screenRecordingProbe
        self.openURL = openURL
        refreshAccessibility()
        refreshDeviceAccess()
        Task { await refreshNotifications() }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAccessibility()
                self?.refreshDeviceAccess()
                await self?.refreshNotifications()
            }
        }
    }

    deinit {
        pollTask?.cancel()
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
    }

    func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshAll()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refreshAll() async {
        refreshAccessibility()
        refreshDeviceAccess()
        await refreshNotifications()
    }

    func refreshDeviceAccess() {
        microphoneStatus = authorizer.microphoneStatus()
        speechRecognitionStatus = authorizer.speechRecognitionStatus()
        screenRecordingGranted = screenRecordingProbe()
    }

    func state(for kind: PermissionKind) -> PermissionState {
        switch kind {
        case .accessibility:
            accessibilityGranted ? .granted : .denied
        case .notifications:
            switch notificationsStatus {
            case .authorized, .provisional: .granted
            case .denied: .denied
            case .notDetermined: .notDetermined
            case .unknown: .unknown
            }
        case .microphone:
            Self.state(for: microphoneStatus)
        case .speechRecognition:
            Self.state(for: speechRecognitionStatus)
        case .screenRecording:
            screenRecordingGranted ? .granted : .denied
        }
    }

    func request(_ kind: PermissionKind) async {
        switch kind {
        case .accessibility:
            requestAccessibility()
        case .notifications:
            await requestNotifications()
        case .screenRecording:
            if state(for: kind) != .granted {
                openSettings(for: kind)
            }
        case .microphone:
            switch microphoneStatus {
            case .granted: return
            case .denied: openSettings(for: kind)
            case .notDetermined:
                _ = await authorizer.requestMicrophoneAccess()
                refreshDeviceAccess()
            }
        case .speechRecognition:
            switch speechRecognitionStatus {
            case .granted: return
            case .denied: openSettings(for: kind)
            case .notDetermined:
                _ = await authorizer.requestSpeechRecognitionAccess()
                refreshDeviceAccess()
            }
        }
    }

    func openSettings(for kind: PermissionKind) {
        if kind == .notifications {
            openNotificationSettings()
        } else if let url = kind.settingsURL {
            openURL(url)
        }
    }

    private static func state(for status: DictationPermissionStatus) -> PermissionState {
        switch status {
        case .granted: .granted
        case .denied: .denied
        case .notDetermined: .notDetermined
        }
    }

    func refreshAccessibility() {
        accessibilityGranted = AXIsProcessTrusted()
    }

    func requestAccessibility() {
        if accessibilityGranted {
            return
        }
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        openAccessibilitySettings()
    }

    func openAccessibilitySettings() {
        openSettings(for: .accessibility)
    }

    func openNotificationSettings() {
        let candidates = [
            Bundle.main.bundleIdentifier.map { "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\($0)" },
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.notifications",
        ]
        for candidate in candidates.compactMap(\.self) {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    func refreshNotifications() async {
        guard !RuntimeEnvironment.isRunningTests else {
            notificationsStatus = .unknown
            return
        }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: notificationsStatus = .notDetermined
        case .authorized: notificationsStatus = .authorized
        case .denied: notificationsStatus = .denied
        case .provisional: notificationsStatus = .provisional
        case .ephemeral: notificationsStatus = .authorized
        @unknown default: notificationsStatus = .unknown
        }
    }

    func requestNotifications() async {
        guard !RuntimeEnvironment.isRunningTests, !isRequestingNotifications else { return }
        isRequestingNotifications = true
        defer { isRequestingNotifications = false }
        await refreshNotifications()
        switch notificationsStatus {
        case .authorized, .provisional:
            return
        case .denied:
            openNotificationSettings()
            return
        case .notDetermined, .unknown:
            break
        }
        NSApp.activate(ignoringOtherApps: true)
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            VoqoraLog.info("PermissionsService", "Notification authorization finished", ["granted": "\(granted)"])
        } catch {
            VoqoraLog.warn("PermissionsService", "Notification authorization failed", ["error": "\(error)"])
        }
        await refreshNotifications()
    }

    func scheduleNotification(title: String, body: String, identifier: String = UUID().uuidString) {
        guard !RuntimeEnvironment.isRunningTests else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        Task { [weak self] in
            if self?.isNotificationsEnabled != true {
                await self?.refreshNotifications()
            }
            guard self?.isNotificationsEnabled == true else { return }
            do {
                try await UNUserNotificationCenter.current().add(request)
            } catch {
                VoqoraLog.warn("PermissionsService", "Could not deliver notification", ["error": "\(error)"])
            }
        }
    }
}

final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationPresenter()

    func install() {
        guard !RuntimeEnvironment.isRunningTests else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent _: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive _: UNNotificationResponse
    ) async {
        await MainActor.run { WindowPresenter.shared.show() }
    }
}
