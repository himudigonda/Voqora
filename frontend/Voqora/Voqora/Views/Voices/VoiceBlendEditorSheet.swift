import SwiftUI

struct VoiceBlendEditorSheet: View {
    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.voqoraTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: VoiceBlendStore
    let editing: VoiceBlend?
    @State private var draft: VoiceBlendDraft
    @StateObject private var previewer = VoiceBlendPreviewer()
    @State private var hasEdited = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(store: VoiceBlendStore, editing: VoiceBlend?) {
        self.store = store
        self.editing = editing
        _draft = State(initialValue: editing.map(VoiceBlendDraft.init(blend:)) ?? VoiceBlendDraft())
    }

    private var visibleMessage: String? {
        errorMessage ?? previewer.errorMessage ?? (hasEdited ? draft.validationMessage : nil)
    }

    var body: some View {
        VoqoraSheet(
            title: editing == nil ? "Blend voices" : "Edit blend",
            supporting: "Mix built-in voices into one. Weights are relative: two voices at 50% sound the same as two at 100%.",
            primaryTitle: isSaving ? "Saving…" : (editing == nil ? "Save Voice" : "Save Changes"),
            isPrimaryEnabled: draft.isValid && !isSaving,
            width: 600,
            onPrimary: save
        ) {
            VStack(alignment: .leading, spacing: Theme.Space.card) {
                VoiceTextField(title: "Name", prompt: "My Narrator", text: $draft.name)
                VoiceFormField(title: "Voices") {
                    VStack(spacing: Theme.Space.item) {
                        ForEach($draft.components) { $component in
                            componentRow($component)
                        }
                        HStack {
                            Button {
                                draft.addComponent()
                            } label: {
                                Label("Add Voice", systemImage: "plus")
                            }
                            .buttonStyle(.voqoraTonal)
                            .disabled(!draft.canAddComponent)
                            .help("Blends mix up to \(VoiceBlendRules.maxComponents) voices.")
                            Spacer(minLength: 0)
                            Button(action: preview) {
                                switch previewer.phase {
                                case .idle:
                                    Label("Preview", systemImage: "play.fill")
                                case .loading:
                                    HStack(spacing: Theme.Space.unit) {
                                        ProgressView().controlSize(.small)
                                        Text("Stop")
                                    }
                                case .playing:
                                    Label("Stop", systemImage: "stop.fill")
                                }
                            }
                            .buttonStyle(.voqoraOutlined)
                            .disabled(previewer.isBusy ? false : !draft.isPreviewable || isSaving || !vm.isBackendOnline)
                            .help(previewer.isBusy ? "Stop the preview" : "Play a sample of this mix without saving")
                        }
                    }
                }
                if let visibleMessage {
                    VoicesBanner(message: visibleMessage, isError: errorMessage != nil)
                }
            }
            .padding(.bottom, Theme.Space.unit)
        }
        .onChange(of: draft) { _, _ in
            hasEdited = true
            errorMessage = nil
            previewer.reset()
        }
        .onDisappear { previewer.stop() }
    }

    private func componentRow(_ component: Binding<VoiceBlendDraft.Component>) -> some View {
        let value = component.wrappedValue
        let position = (draft.components.firstIndex { $0.id == value.id } ?? 0) + 1
        return HStack(spacing: Theme.Space.item) {
            BlendVoiceMenu(
                selection: component.voice,
                taken: Set(draft.components.map(\.voice)).subtracting([value.voice]),
                position: position
            )
            Slider(value: component.weight, in: VoiceBlendRules.minWeight ... VoiceBlendRules.maxWeight, step: 0.05)
                .tint(theme.primary)
                .accessibilityLabel("Weight for voice \(position)")
                .accessibilityValue("\(Self.percent(value.weight)), \(Self.percent(draft.share(of: value))) of the blend")
            Text(Self.percent(draft.share(of: value)))
                .font(vm.font(.label).monospacedDigit())
                .foregroundStyle(theme.onPrimaryContainer)
                .frame(width: 52, height: 28)
                .background(theme.primaryContainer.opacity(0.65), in: Capsule())
                .accessibilityHidden(true)
            Button {
                draft.removeComponent(value.id)
            } label: {
                Image(systemName: "minus")
            }
            .buttonStyle(.voqoraIcon)
            .disabled(!draft.canRemoveComponent)
            .help("Remove voice \(position)")
            .accessibilityLabel("Remove voice \(position)")
        }
    }

    static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    private func save() {
        guard !isSaving else { return }
        hasEdited = true
        guard draft.isValid else { return }
        previewer.stop()
        errorMessage = nil
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                try await store.save(draft, editing: editing?.id)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func preview() {
        if !previewer.isBusy {
            vm.stopPlayback()
        }
        previewer.toggle(draft)
    }
}

private struct BlendVoiceMenu: View {
    @Binding var selection: String
    let taken: Set<String>
    let position: Int

    var body: some View {
        Menu {
            ForEach(DashboardViewModel.languageGroups) { group in
                Section(group.beta ? "\(group.id) (Beta)" : group.id) {
                    ForEach(group.voices) { voice in
                        Button(voice.display) { selection = voice.id }
                            .disabled(taken.contains(voice.id))
                    }
                }
            }
        } label: {
            TonalMenuLabel(text: DashboardViewModel.voiceName(for: selection), minWidth: 116)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Voice \(position)")
        .accessibilityValue(DashboardViewModel.voiceName(for: selection))
    }
}
