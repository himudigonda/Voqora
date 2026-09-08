import SwiftUI

/// Voqora's About screen: identity, version/build, an explicit update
/// check, and developer credit — everything that used to live cramped in
/// the sidebar footer (see `VoqoraWindow`'s now-removed "DEVELOPED BY"
/// block), plus the update affordance that didn't exist anywhere in the UI
/// before this: `AppUpdater.checkGitHubReleaseForUpdate()` and
/// `GuidedInstallerService.downloadAndOpenLatest()` were both only ever
/// called automatically on launch, ***never** from a button a user could
/// press.
struct AboutView: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var updater: AppUpdater
    @EnvironmentObject var installer: GuidedInstallerService
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.colorSchemeContrast) var colorSchemeContrast
    @State private var checkedOnAppear = false

    private var accentColor: Color {
        vm.accentColor(scheme: colorScheme, contrast: colorSchemeContrast)
    }

    private var versionString: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    private var buildString: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                identity

                updateSection

                credits
            }
            .padding(40)
            .frame(maxWidth: 560)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            // One check per visit, not per render — `state`/`latestGitHubVersion`
            // publishing shouldn't retrigger the network call.
            guard !checkedOnAppear else { return }
            checkedOnAppear = true
            await updater.checkGitHubReleaseForUpdate()
        }
    }

    private var identity: some View {
        VStack(spacing: 16) {
            Group {
                if let nsImage = NSImage(named: vm.appIconID.assetName) {
                    Image(nsImage: nsImage).resizable()
                } else {
                    Color.clear
                }
            }
            .frame(width: 96, height: 96)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: 12, y: 6)

            VStack(spacing: 4) {
                Text("Voqora")
                    .font(vm.font(.pageTitle))
                Text("Version \(versionString) (\(buildString))")
                    .font(vm.font(.rowSubtitle))
                    .foregroundStyle(Palette.textSecondary)
            }

            Text("Text-to-speech and audiobooks, spoken locally.")
                .font(vm.font(.rowSubtitle))
                .foregroundStyle(Palette.textTertiary)
        }
    }

    @ViewBuilder
    private var updateSection: some View {
        VStack(spacing: 12) {
            if let latest = updater.latestGitHubVersion {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.up.circle.fill")
                        .foregroundStyle(accentColor)
                    Text("Voqora \(latest) is available.")
                        .font(vm.appFont(size: 13, weight: .semibold))
                }

                Button {
                    installer.downloadAndOpenLatest()
                } label: {
                    Label(installer.state.isBusy ? "Preparing installer…" : "Download & Open", systemImage: "arrow.down.circle")
                        .font(vm.font(.button))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(accentColor)
                .disabled(installer.state.isBusy)
            } else {
                HStack(spacing: 8) {
                    if updater.isCheckingForUpdates {
                        ProgressView().scaleEffect(0.7)
                        Text("Checking for updates…")
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Palette.success)
                        Text("You're on the latest version.")
                    }
                }
                .font(vm.appFont(size: 13))
                .foregroundStyle(Palette.textSecondary)

                Button {
                    Task { await updater.checkGitHubReleaseForUpdate() }
                } label: {
                    Label("Check for Updates", systemImage: "arrow.clockwise")
                        .font(vm.font(.button))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .disabled(updater.isCheckingForUpdates)
            }

            if let message = installer.state.message {
                Text(message)
                    .font(vm.font(.caption))
                    .foregroundStyle(installer.state.isFailure ? Palette.danger : Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Link("View releases on GitHub", destination: GuidedInstallerService.releasePageURL)
                .font(vm.font(.rowSubtitle))
                .foregroundStyle(accentColor)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .voqoraSurface(.raised, in: RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.xLarge, style: .continuous))
    }

    private var credits: some View {
        VStack(spacing: 14) {
            Text("DEVELOPED BY")
                .font(vm.font(.sectionHeader))
                .kerning(0.6)
                .foregroundStyle(Palette.textTertiary)

            Text("Himansh Mudigonda")
                .font(vm.font(.sectionTitle))

            HStack(spacing: 24) {
                Link(destination: URL(string: "https://github.com/himudigonda")!) {
                    Image("github")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 30, height: 30)
                }
                .help("GitHub")

                Link(destination: URL(string: "https://www.linkedin.com/in/himudigonda")!) {
                    Image("linkedin")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 30, height: 30)
                }
                .help("LinkedIn")

                Link(destination: URL(string: "https://himudigonda.me")!) {
                    Image(systemName: "globe")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 24, height: 24)
                        .padding(4)
                }
                .help("Website")
            }
            .foregroundStyle(accentColor)
        }
        .padding(.top, 8)
    }
}
