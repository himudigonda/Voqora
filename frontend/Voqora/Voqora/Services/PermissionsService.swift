import AppKit
import ApplicationServices
import Combine
import Foundation
import SwiftUI
import UserNotifications

/// Live-status checker for the two macOS permissions Voqora cares about:
/// Accessibility (required for the global hotkey) and Notifications (optional).
///
/// The onboarding wizard observes this service and unlocks its "Next" button
/// only after the required permissions are granted. Status is polled because
/// macOS provides no callback when the user grants/revokes a permission via
/// System Settings — the user leaves the app, flips a toggle, comes back.
@MainActor
final class PermissionsService: ObservableObject {
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
        if accessibilityGranted {
            return
        }
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

    // MARK: - Notifications

    func refreshNotifications() async {
        // UNUserNotificationCenter needs a valid CFBundleIdentifier to talk to
        // notifyd — it was missing one (see Info.plist fix), which is the most
        // likely source of the "NSCalendarDate decoder" crash this used to work
        // around. The old guard was `#available(macOS 26, *)`, which — now that
        // 26/27 are GA, not beta — silently disabled notifications for every
        // user on current hardware. Only skip in XCTest hosts, which legitimately
        // lack a proper app bundle identity.
        guard NSClassFromString("XCTestCase") == nil else {
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

    /// Trigger the system Notifications authorization prompt. No-op in test hosts.
    func requestNotifications() async {
        guard NSClassFromString("XCTestCase") == nil else { return }
        do {
            _ = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            // ignored — user denial surfaces via the settings query
        }
        await refreshNotifications()
    }
}
