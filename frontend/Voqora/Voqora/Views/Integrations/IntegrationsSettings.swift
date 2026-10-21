import AppKit
import SwiftUI

struct IntegrationsSettings: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.section) {
            LocalAPISettingsView()
            AudiobookshelfSettingsView()
            SystemEntryPointsInfo()
        }
    }
}

private struct SystemEntryPointsInfo: View {
    private static let shortcutsBundleID = "com.apple.shortcuts"

    var body: some View {
        SettingsSection(title: "Shortcuts and Services") {
            SettingsRowShell(
                title: "Shortcuts app",
                detail: "Speak Text, Speak Clipboard, Pause or Resume Speech and Stop Speech are actions in Shortcuts. You can also ask Siri or Spotlight to run them.",
                systemImage: "square.stack.3d.up"
            ) {
                EmptyView()
            }
            SettingsRowShell(
                title: "Services menu",
                detail: "Select text in any app, then choose Speak with Voqora or Add to Voqora Library from the right-click menu or the app menu's Services submenu.",
                systemImage: "contextualmenu.and.cursorarrow"
            ) {
                EmptyView()
            }
            SettingsButtonRow(
                title: "Open Shortcuts",
                detail: "Build your own automations with Voqora's actions.",
                systemImage: "arrow.up.forward.app",
                buttonTitle: "Open Shortcuts",
                action: openShortcuts
            )
        }
    }

    private func openShortcuts() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.shortcutsBundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}
