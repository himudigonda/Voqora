import SwiftUI

struct NewAudiobookVoiceSection: View {
    @ObservedObject var form: AudiobookCreateForm

    @Environment(\.voqoraTheme) private var theme
    @ObservedObject private var engineStore = SpeechEngineStore.shared

    private var showsDialect: Bool {
        engineStore.voice(id: form.voice)?.isChinese ?? false
    }

    var body: some View {
        FormSection(step: 2, title: "Voice", supporting: "How this audiobook sounds.") {
            VoicePickerCard(title: "Narration voice", voiceID: $form.voice)
            SettingsSliderRow(
                title: "Narration speed",
                value: $form.speed,
                range: AudiobookCreateForm.speedRange,
                step: 0.05,
                valueLabel: PlayerSpeedMenu.label(form.speed)
            )
            PauseLengthControl(value: $form.pauseScale, accentColor: theme.primary)
            if form.isMingVoice {
                VStack(alignment: .leading, spacing: Theme.Space.item + 4) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Delivery for this book")
                            .voqoraFont(.titleSmall)
                            .foregroundStyle(theme.onSurface)
                        Text("Ming can change how it reads. These settings apply to this audiobook only.")
                            .voqoraFont(.bodySmall)
                            .foregroundStyle(theme.onSurfaceVariant)
                    }
                    BookDeliveryControls(delivery: $form.delivery, showsDialect: showsDialect)
                }
            }
        }
    }
}

struct NewAudiobookCleanupSection: View {
    @ObservedObject var form: AudiobookCreateForm
    let addProvider: () -> Void
    let providerChosen: () -> Void

    @EnvironmentObject var bookVM: AudiobookViewModel
    @EnvironmentObject var providers: LLMProviderStore
    @Environment(\.voqoraTheme) private var theme

    private var hasProvider: Bool {
        providers.activeCredential != nil
    }

    var body: some View {
        FormSection(step: 3, title: "Clean up with AI (optional)") {
            SettingsSwitchRow(
                title: "Clean up with AI",
                detail: "Removes headers, page numbers and scan errors before narration. Sends the text to your provider.",
                isOn: $form.useCleanup
            )
            .disabled(!hasProvider)
            .opacity(hasProvider ? 1 : 0.6)
            providerRow
            if form.useCleanup, let provider = providers.activeProvider {
                Text(provider.dataNotice)
                    .voqoraFont(.bodySmall)
                    .foregroundStyle(theme.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: hasProvider) { _, available in
            if !available {
                form.useCleanup = false
            }
        }
    }

    @ViewBuilder
    private var providerRow: some View {
        if providers.connectedProviders.isEmpty {
            SettingsButtonRow(
                title: "Provider",
                detail: "Add an AI provider to use this.",
                buttonTitle: "Add Provider…",
                action: addProvider
            )
        } else {
            SettingsPickerRow(
                title: "Provider",
                detail: providers.activeProvider == nil ? "Choose which provider audiobooks use." : nil,
                valueLabel: providerMenuTitle
            ) {
                ForEach(providers.connectedProviders) { provider in
                    Button {
                        providers.use(provider)
                        providerChosen()
                    } label: {
                        if provider == providers.activeProvider {
                            Label(provider.displayName, systemImage: "checkmark")
                        } else {
                            Text(provider.displayName)
                        }
                    }
                }
                Divider()
                Button("Add Provider…", action: addProvider)
            }
            .disabled(bookVM.startingProcessing)
        }
    }

    private var providerMenuTitle: String {
        guard let credential = providers.activeCredential else {
            return providers.activeProvider?.displayName ?? "Choose a Provider"
        }
        let model = credential.resolvedModel
        return model.isEmpty ? credential.provider.displayName : "\(credential.provider.displayName) · \(model)"
    }
}
