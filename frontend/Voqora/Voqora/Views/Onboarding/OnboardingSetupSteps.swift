import KeyboardShortcuts
import SwiftUI

struct OnboardingAIStep: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var bookVM: AudiobookViewModel
    @EnvironmentObject var providers: LLMProviderStore
    @Environment(\.voqoraTheme) private var theme

    @State private var sheet: ProviderSheet?
    @State private var removalTarget: LLMProvider?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.section) {
            OnboardingCallout(systemImage: "lock.fill", text: OnboardingCopy.aiPrivacyNote)
            if !providers.connectedProviders.isEmpty {
                AICleanupSettings(sheet: $sheet, removalTarget: $removalTarget)
                AIReadingSettings()
            }
            VStack(alignment: .leading, spacing: 10) {
                Text(providers.connectedProviders.isEmpty ? OnboardingCopy.aiChooseLabel : "Add another provider")
                    .voqoraFont(.titleSmall)
                    .foregroundStyle(theme.primary)
                    .padding(.horizontal, 4)
                ProviderPickerGrid { provider in
                    sheet = .edit(provider)
                }
            }
        }
        .sheet(item: $sheet) { sheet in
            Group {
                switch sheet {
                case .add: AddProviderSheet(cleaningCount: bookVM.cleaningBookCount(using:))
                case let .edit(provider): AddProviderSheet(provider: provider, cleaningCount: bookVM.cleaningBookCount(using:))
                }
            }
            .environmentObject(vm)
            .environmentObject(providers)
        }
        .providerRemovalDialog(target: $removalTarget, cleaningCount: bookVM.cleaningBookCount(using:))
    }
}

struct OnboardingSummaryStep: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var bookVM: AudiobookViewModel
    @EnvironmentObject var providers: LLMProviderStore
    @EnvironmentObject var permissions: PermissionsService
    @ObservedObject private var engineStore = SpeechEngineStore.shared
    @ObservedObject private var blendStore = VoiceBlendStore.shared
    @AppStorage(DictationPreferences.engineKey) private var dictationEngine: DictationEngineChoice = .apple
    @Environment(\.voqoraTheme) private var theme

    let jump: (OnboardingStep) -> Void
    let openSettings: (String) -> Void

    private var checklist: [SetupChecklistItem] {
        SetupChecklist.items(
            permissions: Dictionary(uniqueKeysWithValues: PermissionKind.allCases.map { ($0, permissions.state(for: $0)) }),
            hasAIProvider: !providers.connectedProviders.isEmpty,
            analyticsDecided: SetupChecklist.analyticsDecided(),
            dictationEngine: dictationEngine
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.section) {
            checklistSection
            ListGroup {
                shortcutRow(title: "Speak selection", name: .playText)
                shortcutRow(title: "Dictation", name: .toggleDictation)
                row(.engine, title: "Speech engine", value: engineName(forVoice: vm.selectedVoice))
                row(.voice, title: "Speaking voice", value: "\(voiceName(vm.selectedVoice)) · \(PlayerSpeedMenu.label(vm.speechSpeed))")
                row(.audiobooks, title: "Narration voice", value: "\(voiceName(bookVM.defaultBookVoice)) · \(PlayerSpeedMenu.label(bookVM.defaultBookSpeed))")
                row(.ai, title: "AI provider", value: providers.activeProvider?.displayName ?? "None. Narration still works.")
                row(.appearance, title: "Appearance", value: "\(vm.appTheme.capitalized) · \(vm.accentColorID.displayName)")
            }
            ListGroup {
                ListItem(
                    title: OnboardingCopy.integrationsTitle,
                    supporting: OnboardingCopy.integrationsBody,
                    action: { openSettings(TabKey.settings(.integrations)) },
                    leading: { ListItemIcon(systemImage: "point.3.connected.trianglepath.dotted") },
                    trailing: {
                        Image(systemName: "chevron.right")
                            .foregroundStyle(theme.onSurfaceMuted)
                            .accessibilityHidden(true)
                    }
                )
            }
            Button {
                Task { await SpeechSource.$current.withValue(.sample) { await vm.speak(text: sampleText) } }
            } label: {
                Label(OnboardingCopy.doneSampleButton, systemImage: "play.fill")
            }
            .buttonStyle(.voqoraTonal)
            .disabled(!vm.isBackendOnline)
        }
    }

    private var checklistSection: some View {
        SettingsSection(title: OnboardingCopy.checklistTitle, footer: checklist.isEmpty ? nil : OnboardingCopy.checklistFooter) {
            if checklist.isEmpty {
                SettingsNoticeRow(text: OnboardingCopy.checklistEmpty, kind: .success, systemImage: "checkmark.circle.fill")
            } else {
                ForEach(checklist) { item in
                    SettingsButtonRow(
                        title: item.title,
                        detail: item.detail,
                        systemImage: "exclamationmark.circle",
                        buttonTitle: "Fix"
                    ) {
                        openSettings(item.target)
                    }
                }
            }
        }
    }

    private var sampleText: String {
        DashboardViewModel.langCode(forVoice: vm.selectedVoice).hasPrefix("en")
            ? OnboardingCopy.sampleText
            : DashboardViewModel.sampleSentence(forVoice: vm.selectedVoice)
    }

    private func voiceName(_ id: String) -> String {
        VoiceBlendRules.isBlendID(id) ? blendStore.displayName(for: id) : DashboardViewModel.voiceName(for: id)
    }

    private func engineName(forVoice voice: String) -> String {
        let id = SpeechEngineID.engine(forVoice: voice)
        return engineStore.engine(id: id)?.name ?? id.capitalized
    }

    private func shortcutRow(title: String, name: KeyboardShortcuts.Name) -> some View {
        ListItem(
            title: title,
            leading: { ListItemIcon(systemImage: OnboardingStep.shortcuts.systemImage) },
            trailing: {
                HStack(spacing: Theme.Space.item) {
                    ShortcutKeycaps(name: name, size: .compact)
                    Button("Change") { jump(.shortcuts) }
                        .buttonStyle(.voqoraText)
                }
            }
        )
    }

    private func row(_ step: OnboardingStep, title: String, value: String) -> some View {
        ListItem(
            title: title,
            supporting: value,
            leading: { ListItemIcon(systemImage: step.systemImage) },
            trailing: {
                Button("Change") { jump(step) }
                    .buttonStyle(.voqoraText)
            }
        )
    }
}
