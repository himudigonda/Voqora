import AppKit
import SwiftUI

struct AboutView: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var updater: AppUpdater
    @EnvironmentObject var installer: GuidedInstallerService
    @Environment(\.voqoraTheme) private var theme

    private struct AboutLink {
        let title: String
        let symbol: String
        let url: String
    }

    private static let links = [
        AboutLink(title: "GitHub", symbol: "chevron.left.forwardslash.chevron.right", url: "https://github.com/himudigonda/Voqora"),
        AboutLink(title: "Website", symbol: "globe", url: "https://himudigonda.me"),
        AboutLink(title: "LinkedIn", symbol: "person.crop.circle", url: "https://www.linkedin.com/in/himudigonda"),
        AboutLink(title: "Release Notes", symbol: "doc.text", url: GuidedInstallerService.releasePageURL.absoluteString),
    ]

    private static let licensesURL = "https://github.com/himudigonda/Voqora/blob/main/THIRD_PARTY_NOTICES.md"

    private var versionString: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    private var buildString: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Space.section) {
                identity
                updateCard
                linkRow
                credits
            }
            .frame(maxWidth: 560)
            .padding(.horizontal, Theme.Space.gutter)
            .padding(.vertical, Theme.Space.gutter + 8)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await updater.checkGitHubReleaseForUpdateIfStale() }
    }

    private var identity: some View {
        VStack(spacing: 14) {
            Group {
                if let nsImage = NSImage(named: vm.appIconID.assetName) {
                    Image(nsImage: nsImage).resizable()
                } else {
                    Color.clear
                }
            }
            .frame(width: 128, height: 128)
            .clipShape(RoundedRectangle(cornerRadius: 29, style: .continuous))
            .shadow(color: .black.opacity(0.16), radius: 16, y: 8)
            .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text("Voqora")
                    .voqoraFont(.display)
                    .foregroundStyle(theme.onSurface)
                Text("Version \(versionString) (\(buildString))")
                    .voqoraFont(.body)
                    .foregroundStyle(theme.onSurfaceVariant)
            }
            Text("Text-to-speech and audiobooks, spoken locally.")
                .voqoraFont(.body)
                .foregroundStyle(theme.onSurfaceVariant)
                .multilineTextAlignment(.center)
        }
    }

    private var updateCard: some View {
        VoqoraCard {
            VStack(spacing: Theme.Space.item + 4) {
                updateStatus
                updateButton
                if let message = installer.state.message {
                    Text(message)
                        .voqoraFont(.bodySmall)
                        .foregroundStyle(installer.state.isFailure ? theme.danger : theme.onSurfaceVariant)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var updateStatus: some View {
        if let latest = updater.latestGitHubVersion {
            StatusChip(text: "Voqora \(latest) is available", kind: .info, systemImage: "arrow.up.circle.fill")
        } else if updater.isCheckingForUpdates {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking for updates…")
                    .voqoraFont(.label)
                    .foregroundStyle(theme.onSurfaceVariant)
            }
        } else if let message = updater.updateStatusMessage {
            StatusChip(text: message, kind: .warning, systemImage: "exclamationmark.triangle.fill")
        } else {
            StatusChip(text: "You're on the latest version", kind: .success, systemImage: "checkmark.circle.fill")
        }
    }

    @ViewBuilder
    private var updateButton: some View {
        if updater.latestGitHubVersion != nil {
            Button {
                installer.downloadAndOpenLatest()
            } label: {
                Label(installer.state.isBusy ? "Preparing Installer…" : "Download Latest Version", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.voqoraFilled)
            .disabled(installer.state.isBusy)
        } else {
            Button {
                Task { await updater.checkGitHubReleaseForUpdate() }
            } label: {
                Label("Check for Updates", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.voqoraTonal)
            .disabled(updater.isCheckingForUpdates)
        }
    }

    private var linkRow: some View {
        HStack(spacing: Theme.Space.item) {
            ForEach(Self.links, id: \.title) { link in
                AssistChip(title: link.title, systemImage: link.symbol) { open(link.url) }
            }
        }
    }

    private var credits: some View {
        VStack(spacing: 6) {
            Text("Developed by")
                .voqoraFont(.labelSmall)
                .foregroundStyle(theme.onSurfaceMuted)
            Text("Himansh Mudigonda")
                .voqoraFont(.titleSmall)
                .foregroundStyle(theme.onSurface)
            HStack(spacing: 4) {
                Button(OnboardingCopy.privacyPolicyTitle) { NSWorkspace.shared.open(OnboardingCopy.privacyPolicyURL) }
                    .buttonStyle(.voqoraText)
                Button("Open-source licenses") { open(Self.licensesURL) }
                    .buttonStyle(.voqoraText)
            }
        }
    }

    private func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }
}
