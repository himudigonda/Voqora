import SwiftUI

struct DictationView: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var dictation: DictationController
    @EnvironmentObject var transcripts: DictationTranscriptStore
    @State private var searchText = ""
    @State private var confirmingClear = false

    var body: some View {
        let matches = DictationTranscriptStore.matching(transcripts.transcripts, query: searchText)
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Layout.sectionGap) {
                header
                if dictation.phase == .idle, let issue = dictation.issue {
                    DictationMessageRow(
                        systemImage: "exclamationmark.triangle.fill",
                        tint: Palette.warning,
                        message: issue.message,
                        settingsPane: issue.settingsPane
                    )
                    .padding(DesignTokens.Layout.cardInset)
                    .background(Palette.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.medium, style: .continuous))
                }
                DictationSettingsCard()
                transcriptSection(matches)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: 800, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Dictation")
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search Transcripts")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Button("Clear Transcripts…", role: .destructive) { confirmingClear = true }
                        .disabled(transcripts.transcripts.isEmpty)
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .help("More")
            }
        }
        .confirmationDialog("Clear Transcripts?", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Clear Transcripts", role: .destructive) { transcripts.clear() }
        } message: {
            Text("This removes every saved dictation transcript from this Mac.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Dictation")
                .font(vm.font(.pageTitle))
                .foregroundStyle(Palette.textPrimary)
            Text("Press \(DictationController.shortcutLabel) in any app, speak, then press it again. Voqora types what you said where your cursor is.")
                .font(vm.appFont(size: 14))
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func transcriptSection(_ matches: [DictationTranscript]) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            PaneSectionHeader(title: "Recent Transcripts")
            if let persistenceError = transcripts.persistenceError {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Palette.warning)
                    Text(persistenceError)
                        .font(vm.font(.rowSubtitle))
                        .foregroundStyle(Palette.textPrimary)
                    Spacer()
                    Button("Try Again") { transcripts.retryPersistence() }
                        .buttonStyle(.voqoraSecondary)
                }
            }
            if matches.isEmpty {
                Text(emptyMessage)
                    .font(vm.font(.rowTitle))
                    .foregroundStyle(Palette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DesignTokens.Layout.cardInset)
                    .voqoraSurface(.raised, in: RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.xLarge, style: .continuous))
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(matches) { transcript in
                        DictationTranscriptRow(transcript: transcript)
                        if transcript.id != matches.last?.id {
                            Divider()
                        }
                    }
                }
                .voqoraSurface(.raised, in: RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.xLarge, style: .continuous))
            }
        }
    }

    private var emptyMessage: String {
        guard transcripts.transcripts.isEmpty else {
            return "No transcripts match “\(searchText)”."
        }
        return "What you dictate appears here. Voqora keeps the last \(DictationTranscriptStore.capacity) transcripts on this Mac."
    }
}

struct DictationTranscriptRow: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var transcripts: DictationTranscriptStore
    let transcript: DictationTranscript
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.md) {
            VStack(alignment: .leading, spacing: 5) {
                Text(transcript.createdAt, format: .dateTime.month().day().hour().minute())
                    .font(vm.font(.caption))
                    .foregroundStyle(Palette.textSecondary)
                Text(transcript.text)
                    .font(vm.appFont(size: 15, weight: .medium))
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
            HStack(spacing: DesignTokens.Spacing.sm) {
                PlayerCircleButton(systemName: "doc.on.doc", label: "Copy") { copy() }
                PlayerCircleButton(systemName: "trash", label: "Delete") { transcripts.delete(transcript) }
            }
            .opacity(hovering ? 1 : 0.35)
        }
        .padding(.horizontal, DesignTokens.Layout.cardInset)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Copy") { copy() }
            Divider()
            Button("Delete", role: .destructive) { transcripts.delete(transcript) }
        }
    }

    private func copy() {
        SystemPasteboard().write(transcript.text, transient: false)
    }
}
