import SwiftUI

struct MyVoicesView: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var bookVM: AudiobookViewModel
    @ObservedObject private var store = VoiceBlendStore.shared
    @State private var editor: VoiceBlendEditorTarget?
    @State private var pendingDeletion: VoiceBlend?
    @State private var actionError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Layout.sectionGap) {
                VoicesPageHeader(page: .myVoices)
                if let actionError {
                    VoicesStatusCard(systemImage: "exclamationmark.triangle.fill", message: actionError)
                }
                content
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: 800, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("My Voices")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { editor = .new } label: {
                    Label("New Voice", systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(!canCreate)
                .help(store.canCreateMore ? "New Voice" : "You can save up to \(store.maxBlends) custom voices.")
            }
        }
        .sheet(item: $editor) { target in
            VoiceBlendEditorSheet(store: store, editing: target.blend)
                .environmentObject(vm)
        }
        .confirmationDialog(
            "Delete \(pendingDeletion?.name ?? "Voice")?",
            isPresented: isConfirmingDeletion,
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { blend in
            Button("Delete Voice", role: .destructive) { delete(blend) }
        } message: { blend in
            Text("Anything set to \(blend.name) switches to \(DashboardViewModel.voiceName(for: blend.fallbackVoice)), including audiobooks still being narrated.")
        }
        .task(id: vm.isBackendOnline) {
            if vm.isBackendOnline {
                await store.refresh()
            }
        }
    }

    private var isConfirmingDeletion: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { presented in
                if !presented {
                    pendingDeletion = nil
                }
            }
        )
    }

    private var canCreate: Bool {
        store.canCreateMore && store.state == .loaded
    }

    @ViewBuilder
    private var content: some View {
        switch store.state {
        case .idle, .loading:
            HStack(spacing: DesignTokens.Spacing.sm) {
                ProgressView().controlSize(.small)
                Text("Loading your voices…")
                    .font(vm.font(.rowTitle))
                    .foregroundStyle(Palette.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DesignTokens.Layout.cardInset)
        case let .failed(message):
            VoicesStatusCard(systemImage: "exclamationmark.triangle.fill", message: message, actionTitle: "Try Again") {
                Task { await store.refresh() }
            }
        case .loaded:
            if store.blends.isEmpty {
                emptyState
            } else {
                blendList
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            Text("No custom voices yet")
                .font(vm.font(.sectionTitle))
                .foregroundStyle(Palette.textPrimary)
            Text("Blend a warm narrator with a brighter one, or mix accents. Weights control how much of each voice you hear.")
                .font(vm.font(.rowTitle))
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button { editor = .new } label: {
                Label("Create a Voice", systemImage: "plus")
            }
            .buttonStyle(.voqoraPrimary)
        }
        .padding(DesignTokens.Layout.cardInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .voqoraSurface(.raised, in: RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.xLarge, style: .continuous))
    }

    private var blendList: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            PaneSectionHeader(title: "\(store.blends.count) of \(store.maxBlends) Voices")
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(store.blends) { blend in
                    VoiceBlendRow(
                        blend: blend,
                        isSpeechVoice: vm.selectedVoice == blend.id,
                        isBookVoice: bookVM.defaultBookVoice == blend.id,
                        actions: VoiceBlendRow.Actions(
                            preview: { preview(blend) },
                            edit: { editor = .edit(blend) },
                            delete: { pendingDeletion = blend },
                            useForSpeech: { vm.selectedVoice = blend.id },
                            useForBooks: { bookVM.defaultBookVoice = blend.id }
                        )
                    )
                    if blend.id != store.blends.last?.id {
                        Divider()
                    }
                }
            }
            .voqoraSurface(.raised, in: RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.xLarge, style: .continuous))
        }
    }

    private func preview(_ blend: VoiceBlend) {
        Task { await vm.speak(text: DashboardViewModel.sampleSentence(forVoice: blend.id), voice: blend.id) }
    }

    private func delete(_ blend: VoiceBlend) {
        pendingDeletion = nil
        actionError = nil
        Task {
            do {
                try await store.delete(blend)
            } catch {
                actionError = error.localizedDescription
            }
        }
    }
}

enum VoiceBlendEditorTarget: Identifiable {
    case new
    case edit(VoiceBlend)

    var id: String {
        switch self {
        case .new: "new"
        case let .edit(blend): blend.id
        }
    }

    var blend: VoiceBlend? {
        if case let .edit(blend) = self {
            return blend
        }
        return nil
    }
}

struct VoiceBlendRow: View {
    struct Actions {
        let preview: () -> Void
        let edit: () -> Void
        let delete: () -> Void
        let useForSpeech: () -> Void
        let useForBooks: () -> Void
    }

    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    let blend: VoiceBlend
    let isSpeechVoice: Bool
    let isBookVoice: Bool
    let actions: Actions
    @State private var hovering = false

    static func summary(of blend: VoiceBlend) -> String {
        blend.components
            .map { "\(DashboardViewModel.voiceName(for: $0.voice)) \(Int(($0.normalizedWeight * 100).rounded()))%" }
            .joined(separator: " · ")
    }

    var body: some View {
        let accent = vm.accentColor(scheme: colorScheme, contrast: contrast)
        HStack(alignment: .center, spacing: DesignTokens.Spacing.md) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    Text(blend.name)
                        .font(vm.appFont(size: 15, weight: .semibold))
                        .foregroundStyle(Palette.textPrimary)
                    if isSpeechVoice {
                        VoicesChip(text: "Speech", tint: accent)
                    }
                    if isBookVoice {
                        VoicesChip(text: "Audiobooks", tint: accent)
                    }
                }
                Text(Self.summary(of: blend))
                    .font(vm.font(.rowSubtitle))
                    .foregroundStyle(Palette.textSecondary)
            }
            Spacer(minLength: 0)
            HStack(spacing: DesignTokens.Spacing.sm) {
                PlayerCircleButton(systemName: "play.fill", label: "Preview \(blend.name)", isEnabled: vm.isBackendOnline, action: actions.preview)
                PlayerCircleButton(systemName: "pencil", label: "Edit \(blend.name)", action: actions.edit)
                PlayerCircleMenu(systemName: "ellipsis", label: "More actions for \(blend.name)") {
                    menuItems
                }
            }
            .opacity(hovering ? 1 : 0.6)
        }
        .padding(.horizontal, DesignTokens.Layout.cardInset)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu { menuItems }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(blend.name), \(Self.summary(of: blend))")
    }

    @ViewBuilder
    private var menuItems: some View {
        Button("Preview", action: actions.preview)
            .disabled(!vm.isBackendOnline)
        Button("Edit…", action: actions.edit)
        Divider()
        Button("Use for Speech", action: actions.useForSpeech)
            .disabled(isSpeechVoice)
        Button("Use for Audiobooks", action: actions.useForBooks)
            .disabled(isBookVoice)
        Divider()
        Button("Delete…", role: .destructive, action: actions.delete)
    }
}
