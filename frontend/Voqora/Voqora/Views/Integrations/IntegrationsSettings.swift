import AppKit
import SwiftUI

struct IntegrationsSettings: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            LocalAPISettingsView()
            Divider()
            AudiobookshelfSettingsView()
            Divider()
            SystemEntryPointsInfo()
        }
    }
}

private struct SystemEntryPointsInfo: View {
    @EnvironmentObject var vm: DashboardViewModel

    private static let shortcutsBundleID = "com.apple.shortcuts"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Shortcuts and Services")
                .font(vm.font(.rowTitle))
            entry(
                icon: "square.stack.3d.up",
                title: "Shortcuts app",
                detail: "Speak Text, Speak Clipboard, Pause or Resume Speech and Stop Speech are actions in Shortcuts. You can also ask Siri or Spotlight to run them."
            )
            entry(
                icon: "contextualmenu.and.cursorarrow",
                title: "Services menu",
                detail: "Select text in any app, then choose Speak with Voqora or Add to Voqora Library from the right-click menu or the app menu's Services submenu."
            )
            HStack {
                Button("Open Shortcuts", action: openShortcuts)
                    .buttonStyle(.voqoraSecondary)
                Spacer()
            }
        }
    }

    private func entry(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(Palette.textSecondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(vm.font(.rowTitle).weight(.semibold))
                Text(detail)
                    .font(vm.font(.rowSubtitle))
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func openShortcuts() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.shortcutsBundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}
