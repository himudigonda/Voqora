import AppKit
import SwiftUI

struct GeneralSettingsPage: View {
    @EnvironmentObject var launchManager: LaunchManager
    @EnvironmentObject var onboarding: OnboardingCoordinator
    @EnvironmentObject var installer: GuidedInstallerService
    @EnvironmentObject var permissions: PermissionsService
    @EnvironmentObject var updater: AppUpdater
    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.voqoraTheme) private var theme

    @AppStorage(AppPresence.showMenuBarIconKey) private var showMenuBarIcon = true
    @AppStorage(AppPresence.hideFromDockKey) private var hideFromDock = false

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    var body: some View {
        SettingsPage(.general) {
            presenceSection
            updatesSection
            setupSection
        }
        .task { await permissions.refreshAll() }
    }

    private var presenceSection: some View {
        SettingsSection(title: "Startup and presence") {
            SettingsSwitchRow(
                title: "Start at Login",
                detail: "Open Voqora automatically when you sign in.",
                systemImage: "power",
                isOn: $launchManager.isLaunchAtLoginEnabled
            )
            SettingsSwitchRow(
                title: "Hide from Dock & App Switcher",
                detail: "Keep Voqora in the menu bar only.",
                systemImage: "dock.rectangle",
                isOn: Binding(
                    get: { hideFromDock },
                    set: { hidden in
                        AppPresence.setHideFromDock(hidden)
                        AppPresence.applyActivationPolicy(onboarding: onboarding.needsOnboarding, presentsDashboard: false)
                    }
                )
            )
            SettingsSwitchRow(
                title: "Show Menu Bar Icon",
                detail: hideFromDock ? "Always on while Voqora is hidden from the Dock." : "Quick access to speaking and playback controls.",
                systemImage: "menubar.rectangle",
                isOn: Binding(
                    get: { showMenuBarIcon },
                    set: { shown in
                        AppPresence.setShowMenuBarIcon(shown)
                        AppPresence.applyActivationPolicy(onboarding: onboarding.needsOnboarding, presentsDashboard: false)
                    }
                )
            )
            .disabled(hideFromDock)
        }
    }

    private var setupSection: some View {
        SettingsSection(title: "Setup") {
            SetupChecklistCard()
            SettingsButtonRow(
                title: "Run Setup Again",
                detail: "Walk through the first-run guide from the beginning. Your settings stay as they are.",
                systemImage: "arrow.counterclockwise",
                buttonTitle: "Run Setup Again"
            ) {
                onboarding.reset()
            }
        }
    }

    private var updatesSection: some View {
        SettingsSection(title: "Updates", footer: updatesFooter) {
            SettingsValueRow(title: "Version", detail: "The version of Voqora you are running.", systemImage: "number") {
                SettingsTextValue(text: "v" + appVersion)
            }
            SettingsValueRow(title: "Status", systemImage: "arrow.triangle.2.circlepath") {
                updateStatus
            }
            SettingsRowShell(title: updater.latestGitHubVersion == nil ? "Check for updates" : "Update available", systemImage: "arrow.down.circle") {
                HStack(spacing: 8) {
                    updateButtons
                    Button {
                        NSWorkspace.shared.open(GuidedInstallerService.releasePageURL)
                    } label: {
                        Label("Release Notes", systemImage: "arrow.up.right.square")
                    }
                    .buttonStyle(.voqoraText)
                }
            }
            if let message = installer.state.message {
                SettingsNoticeRow(text: message, kind: installer.state.isFailure ? .danger : .info)
            }
        }
    }

    private var updatesFooter: String? {
        guard updater.latestGitHubVersion != nil else { return nil }
        return "Early access downloads a verified DMG, opens it in Finder, and lets you drag Voqora to Applications. It never replaces the app automatically."
    }

    @ViewBuilder
    private var updateButtons: some View {
        if updater.latestGitHubVersion != nil {
            Button(installer.state.isBusy ? "Preparing Installer…" : "Download Latest Version") {
                installer.downloadAndOpenLatest()
            }
            .buttonStyle(.voqoraFilled)
            .disabled(installer.state.isBusy)
        } else {
            Button("Check for Updates") {
                Task { await updater.checkGitHubReleaseForUpdate() }
            }
            .buttonStyle(.voqoraTonal)
            .disabled(updater.isCheckingForUpdates)
        }
        if case .failed = installer.state {
            Button("Try Again") {
                installer.reset()
                installer.downloadAndOpenLatest()
            }
            .buttonStyle(.voqoraOutlined)
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
                    .font(vm.font(.label))
                    .foregroundStyle(theme.onSurfaceVariant)
            }
        } else if let message = updater.updateStatusMessage {
            StatusChip(text: message, kind: .warning, systemImage: "exclamationmark.triangle.fill")
        } else {
            StatusChip(text: "Up to date", kind: .success, systemImage: "checkmark.circle.fill")
        }
    }
}

struct SetupChecklistCard: View {
    @EnvironmentObject var permissions: PermissionsService
    @EnvironmentObject var providers: LLMProviderStore
    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.voqoraTheme) private var theme

    @AppStorage(MetricsService.analyticsEnabledKey) private var analyticsEnabledSignal = false
    @AppStorage(DictationPreferences.engineKey) private var dictationEngine: DictationEngineChoice = .apple

    private var items: [SetupChecklistItem] {
        _ = analyticsEnabledSignal
        return SetupChecklist.items(
            permissions: Dictionary(uniqueKeysWithValues: PermissionKind.allCases.map { ($0, permissions.state(for: $0)) }),
            hasAIProvider: !providers.connectedProviders.isEmpty,
            analyticsDecided: SetupChecklist.analyticsDecided(),
            dictationEngine: dictationEngine
        )
    }

    var body: some View {
        let pending = items
        VStack(spacing: Theme.Space.listGap) {
            if pending.isEmpty {
                SettingsRowShell(
                    title: "Finish setup",
                    detail: "Everything Voqora asked about is taken care of.",
                    systemImage: "checkmark.seal"
                ) {
                    StatusChip(text: "All set", kind: .success, systemImage: "checkmark.circle.fill")
                }
            } else {
                header(count: pending.count)
                ForEach(pending) { item in
                    SettingsRowShell(title: item.title, detail: item.detail, systemImage: Self.symbol(for: item.gap)) {
                        Button("Fix") { vm.selectedTab = item.target }
                            .buttonStyle(.voqoraTonal)
                            .accessibilityLabel("Fix: \(item.title)")
                    }
                }
            }
        }
    }

    private func header(count: Int) -> some View {
        HStack(spacing: 10) {
            Text("Finish setup")
                .font(vm.font(.titleSmall))
                .foregroundStyle(theme.onSurface)
            StatusChip(text: count == 1 ? "1 to go" : "\(count) to go", kind: .info)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    static func symbol(for gap: SetupChecklistItem.Gap) -> String {
        switch gap {
        case .accessibility: PermissionKind.accessibility.systemImage
        case .notifications: PermissionKind.notifications.systemImage
        case .dictationAccess: PermissionKind.microphone.systemImage
        case .aiProvider: "sparkles"
        case .analytics: "chart.bar"
        }
    }
}
