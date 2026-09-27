import AppKit
import ApplicationServices
import Combine
import Foundation
import SwiftUI
import UserNotifications

@MainActor
final class PermissionsService: ObservableObject {
    static let shared = PermissionsService()

    @Published private(set) var accessibilityGranted: Bool = false
    @Published private(set) var notificationsStatus: NotificationsStatus = .unknown

    enum NotificationsStatus: Equatable {
        case unknown // never asked, status not yet read
        case notDetermined // never asked
        case authorized // granted
        case denied // user said no, or system disabled
        case provisional // limited (rare on macOS)
    }

    private var pollTask: Task<Void, Never>?
    private var activationObserver: NSObjectProtocol?

    init() {
        refreshAccessibility()
        Task { await refreshNotifications() }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAccessibility()
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
        await refreshNotifications()
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
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
            NSWorkspace.shared.open(url)
        }
    }

    func refreshNotifications() async {
        guard NSClassFromString("XCTestCase") == nil else {
            notificationsStatus = .unknown
            return
        }
        if #available(macOS 27, *) {
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
        guard NSClassFromString("XCTestCase") == nil else { return }
        if #available(macOS 27, *) {
            return
        }
        do {
            _ = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
        } catch {}
        await refreshNotifications()
    }

    func scheduleNotification(title: String, body: String, identifier: String = UUID().uuidString) {
        guard NSClassFromString("XCTestCase") == nil else { return }
        guard notificationsStatus == .authorized || notificationsStatus == .provisional else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        Task {
            try? await UNUserNotificationCenter.current().add(request)
        }
    }
}
