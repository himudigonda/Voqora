import SwiftUI

struct VoiceBlendEditorSheet: View {
    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @ObservedObject var store: VoiceBlendStore
    let editing: VoiceBlend?
    @State private var draft: VoiceBlendDraft
    @State private var hasEdited = false
    @State private var saving = false
    @State private var errorMessage: String?
    @FocusState private var nameFocused: Bool

    init(store: VoiceBlendStore, editing: VoiceBlend?) {
        self.store = store
        self.editing = editing
        _draft = State(initialValue: editing.map(VoiceBlendDraft.init(blend:)) ?? VoiceBlendDraft())
    }

    private var accent: Color {
        vm.accentColor(scheme: colorScheme, contrast: contrast)
    }

    private var visibleMessage: String? {
        errorMessage ?? (hasEdited ? draft.validationMessage : nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
            Text(editing == nil ? "New Voice" : "Edit Voice")
                .font(vm.font(.sectionHeader))
                .foregroundStyle(accent)
                .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: 6) {
                Text("Name")
                    .font(vm.font(.rowSubtitle))
                    .foregroundStyle(Palette.textSecondary)
                TextField("My Narrator", text: $draft.name)
                    .textFieldStyle(.roundedBorder)
                    .font(vm.font(.rowTitle))
                    .focused($nameFocused)
                    .accessibilityLabel("Voice name")
            }

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                Text("Voices")
                    .font(vm.font(.rowSubtitle))
                    .foregroundStyle(Palette.textSecondary)
                ForEach($draft.components) { $component in
                    componentRow($component)
                }
                Button {
                    draft.addComponent()
                } label: {
                    Label("Add Voice", systemImage: "plus")
                }
                .buttonStyle(.voqoraSecondary)
                .disabled(!draft.canAddComponent)
                .help("Blends mix up to \(VoiceBlendRules.maxComponents) voices.")
            }

            Text("Weights are relative: two voices at 50% sound the same as two at 100%. Choose voices that speak the same language for the most natural result.")
                .font(vm.font(.rowSubtitle))
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let visibleMessage {
                Label(visibleMessage, systemImage: "exclamationmark.circle.fill")
                    .font(vm.font(.rowSubtitle))
                    .foregroundStyle(errorMessage == nil ? Palette.warning : Palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: DesignTokens.Spacing.md) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.voqoraSecondary)
                    .keyboardShortcut(.cancelAction)
                Button {
                    save()
                } label: {
                    if saving {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(editing == nil ? "Save Voice" : "Save Changes")
                    }
                }
                .buttonStyle(.voqoraPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.isValid || saving)
            }
        }
        .padding(28)
        .frame(width: 520)
        .voqoraSurface(.floating, in: Rectangle())
        .onChange(of: draft) { _, _ in
            hasEdited = true
            errorMessage = nil
        }
        .onAppear { nameFocused = editing == nil }
    }

    private func componentRow(_ component: Binding<VoiceBlendDraft.Component>) -> some View {
        let value = component.wrappedValue
        let position = (draft.components.firstIndex { $0.id == value.id } ?? 0) + 1
        return HStack(spacing: DesignTokens.Spacing.md) {
            GroupedVoicePicker(title: "Voice \(position)", selection: component.voice, includesBlends: false)
            Slider(value: component.weight, in: VoiceBlendRules.minWeight ... VoiceBlendRules.maxWeight, step: 0.05)
                .tint(accent)
                .accessibilityLabel("Weight for voice \(position)")
                .accessibilityValue("\(Self.percent(value.weight)), \(Self.percent(draft.share(of: value))) of the blend")
            Text(Self.percent(draft.share(of: value)))
                .font(vm.appFont(size: 12, weight: .bold).monospaced())
                .foregroundStyle(accent)
                .frame(width: 44, alignment: .trailing)
                .accessibilityHidden(true)
            PlayerCircleButton(
                systemName: "minus",
                label: "Remove voice \(position)",
                isEnabled: draft.canRemoveComponent
            ) {
                draft.removeComponent(value.id)
            }
        }
    }

    static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    private func save() {
        guard !saving else { return }
        hasEdited = true
        guard draft.isValid else { return }
        saving = true
        errorMessage = nil
        Task {
            defer { saving = false }
            do {
                try await store.save(draft, editing: editing?.id)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
