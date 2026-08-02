import AppKit
import ApplicationServices
import Combine
import Foundation
import SwiftUI
import UserNotifications

/// Live-status checker for the two macOS permissions Voqora cares about:
/// Accessibility (required for the global hotkey) and Notifications (optional).
///
/// The onboarding wizard observes this service and provides an explicit
/// continue-without-access route when the user declines Accessibility. Status
/// is polled because macOS provides no callback when the user grants/revokes a
/// permission via System Settings — the user leaves the app, flips a toggle,
/// comes back.
@MainActor
final class PermissionsService: ObservableObject {
    /// The app-wide instance. VoqoraApp's `@StateObject` wraps this same
    /// instance so SwiftUI observes it while non-view callers (view models,
    /// AppUpdater) can still reach it to schedule notifications.
    static let shared = PermissionsService()

    @Published private(set) var accessibilityGranted: Bool = false
    @Published private(set) var notificationsStatus: NotificationsStatus = .unknown

    enum NotificationsStatus: Equatable {
        case unknown          // never asked, status not yet read
        case notDetermined    // never asked
        case authorized       // granted
        case denied           // user said no, or system disabled
        case provisional      // limited (rare on macOS)
    }

    private var pollTask: Task<Void, Never>?

    init() {
        refreshAccessibility()
        Task { await refreshNotifications() }
    }

    deinit {
        pollTask?.cancel()
    }

    // MARK: - Polling lifecycle

    /// Start live-polling permission status. Call from `.onAppear` of the
    /// onboarding view. Stops on `stopPolling()` or when the task is cancelled.
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

    // MARK: - Accessibility

    func refreshAccessibility() {
        accessibilityGranted = AXIsProcessTrusted()
    }

    /// Trigger the macOS Accessibility prompt and open System Settings so the
    /// user can flip the toggle. After the system prompt, polling will detect
    /// the granted state and update `accessibilityGranted`.
    func requestAccessibility() {
        if accessibilityGranted { return }
        // Show the system prompt (no-op if already prompted before).
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        // Open the Accessibility pane directly — the user may have dismissed the prompt.
        openAccessibilitySettings()
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Opens System Settings' Notifications pane directly. Once a user has
    /// denied notifications, `requestNotifications()` cannot re-prompt —
    /// macOS only lets the user flip that back on here.
    func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Notifications

    func refreshNotifications() async {
        // UNUserNotificationCenter is known to throw NSCalendarDate decoder
        // exceptions on macOS 27 beta and inside XCTest hosts. Skip both.
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

    /// Trigger the system Notifications authorization prompt. No-op on macOS 27 beta or in tests.
    func requestNotifications() async {
        guard NSClassFromString("XCTestCase") == nil else { return }
        if #available(macOS 27, *) { return }
        do {
            _ = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            // ignored — user denial surfaces via the settings query
        }
        await refreshNotifications()
    }

    /// Delivers a local notification for a meaningful, user-visible moment
    /// (an audiobook finished converting, speech started, an update is
    /// available). Silently no-ops if the user hasn't authorized
    /// notifications yet — this is never the path that requests permission.
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
