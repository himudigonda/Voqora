import AppKit
import SwiftUI

struct PermissionsSettingsPage: View {
    @EnvironmentObject var permissions: PermissionsService

    private var requiredKinds: [PermissionKind] {
        PermissionKind.allCases.filter(\.isRequired)
    }

    private var optionalKinds: [PermissionKind] {
        PermissionKind.allCases.filter { !$0.isRequired }
    }

    var body: some View {
        SettingsPage(.permissions) {
            SettingsSection(
                title: "Needed for the basics",
                footer: "Without Accessibility, Voqora cannot read your selection or paste dictation. It copies to the clipboard instead."
            ) {
                ForEach(requiredKinds) { PermissionRow(kind: $0) }
            }
            SettingsSection(
                title: "Turn on as you need them",
                footer: "Screen Recording is only used when you read text from a screen region, and macOS asks the first time. Music ducking asks for Automation access separately, when it first runs."
            ) {
                ForEach(optionalKinds) { PermissionRow(kind: $0) }
            }
        }
        .task { await permissions.refreshAll() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await permissions.refreshAll() }
        }
    }
}
