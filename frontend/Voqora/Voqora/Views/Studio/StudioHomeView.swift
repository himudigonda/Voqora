import SwiftUI

struct StudioHomeView: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var studio: StudioViewModel
    @EnvironmentObject var bookVM: AudiobookViewModel
    @ObservedObject var drafts: StudioDraftStore
    @State private var pendingDeletion: PodcastDraft?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Layout.sectionGap) {
                StudioPageHeader(
                    title: "Studio",
                    subtitle: "Turn anything you read into a podcast, or write a script for several voices yourself."
                ) {
                    EmptyView()
                }
                if let notice = studio.notice {
                    StudioBanner(message: notice) { studio.notice = nil }
                }
                if let error = drafts.persistenceError {
                    StudioBanner(message: error)
                }
                actions
                draftsSection
                podcastsSection
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: 800, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .confirmationDialog(
            "Delete \u{201C}\(pendingDeletion?.script.title ?? "")\u{201D}?",
            isPresented: Binding(get: { pendingDeletion != nil }, set: {
                if !$0 {
                    pendingDeletion = nil
                }
            }),
            titleVisibility: .visible
        ) {
            Button("Delete Script", role: .destructive) {
                if let draft = pendingDeletion {
                    studio.deleteDraft(draft.id)
                }
                pendingDeletion = nil
            }
        } message: {
            Text("This removes the script from this Mac. Podcasts you already rendered stay in your Library.")
        }
    }

    private var actions: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            StudioActionCard(
                title: "New Podcast",
                detail: "AI hosts talk through a Library item or any text you paste.",
                systemImage: "waveform.and.mic",
                shortcut: KeyboardShortcut("n", modifiers: [.command, .shift])
            ) {
                studio.startNewPodcast()
            }
            StudioActionCard(
                title: "New Blank Script",
                detail: "Write your own multi-voice script, turn by turn.",
                systemImage: "text.badge.plus",
                shortcut: KeyboardShortcut("b", modifiers: [.command, .shift])
            ) {
                studio.startBlankScript()
            }
        }
    }

    private var draftsSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            PaneSectionHeader(title: "Scripts")
            if drafts.drafts.isEmpty {
                emptyRow("Scripts you generate or write are saved here as you edit.")
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(drafts.drafts) { draft in
                        StudioListRow(
                            title: draft.script.title.isEmpty ? "Untitled Script" : draft.script.title,
                            detail: draftDetail(draft),
                            primaryLabel: "Open",
                            primaryAction: { studio.open(draft) },
                            deleteAction: { pendingDeletion = draft }
                        )
                        if draft.id != drafts.drafts.last?.id {
                            Divider()
                        }
                    }
                }
                .voqoraSurface(.raised, in: RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.xLarge, style: .continuous))
            }
        }
    }

    private var podcastsSection: some View {
        let podcasts = bookVM.books.filter(\.isPodcast)
        return VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            PaneSectionHeader(title: "Rendered Podcasts")
            if podcasts.isEmpty {
                emptyRow("Rendered podcasts appear in your Library with a Podcast badge. Open one here to edit its script and render a new version.")
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(podcasts) { book in
                        StudioListRow(
                            title: book.displayTitle,
                            detail: book.creditLine,
                            primaryLabel: studio.openingBookID == book.bookID ? "Opening…" : "Edit Script",
                            primaryAction: { studio.openRenderedPodcast(bookID: book.bookID) },
                            deleteAction: nil
                        )
                        .disabled(studio.openingBookID != nil)
                        if book.id != podcasts.last?.id {
                            Divider()
                        }
                    }
                }
                .voqoraSurface(.raised, in: RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.xLarge, style: .continuous))
            }
        }
    }

    private func emptyRow(_ message: String) -> some View {
        Text(message)
            .font(vm.font(.rowTitle))
            .foregroundStyle(Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DesignTokens.Layout.cardInset)
            .voqoraSurface(.raised, in: RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.xLarge, style: .continuous))
    }

    private func draftDetail(_ draft: PodcastDraft) -> String {
        let turns = draft.script.turns.count
        let speakers = draft.script.speakers.count
        let edited = draft.updatedAt.formatted(.relative(presentation: .named))
        return "\(turns) \(turns == 1 ? "turn" : "turns") · \(speakers) \(speakers == 1 ? "speaker" : "speakers") · Edited \(edited)"
    }
}

private struct StudioActionCard: View {
    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    let title: String
    let detail: String
    let systemImage: String
    let shortcut: KeyboardShortcut
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                Image(systemName: systemImage)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(vm.accentColor(scheme: colorScheme, contrast: colorSchemeContrast))
                    .accessibilityHidden(true)
                Text(title)
                    .font(vm.font(.sectionTitle))
                    .foregroundStyle(Palette.textPrimary)
                Text(detail)
                    .font(vm.font(.rowSubtitle))
                    .foregroundStyle(Palette.textSecondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(DesignTokens.Layout.cardInset)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(hovering ? Palette.controlFill : Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.xLarge, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.xLarge, style: .continuous)
                .strokeBorder(Palette.separator, lineWidth: 1)
        )
        .onHover { hovering = $0 }
        .keyboardShortcut(shortcut)
        .accessibilityLabel(title)
        .accessibilityHint(detail)
    }
}

private struct StudioListRow: View {
    @EnvironmentObject var vm: DashboardViewModel
    let title: String
    let detail: String
    let primaryLabel: String
    let primaryAction: () -> Void
    let deleteAction: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(vm.appFont(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                Text(detail)
                    .font(vm.font(.rowSubtitle))
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: DesignTokens.Spacing.md)
            Button(primaryLabel, action: primaryAction)
                .buttonStyle(.voqoraSecondary)
                .accessibilityLabel("\(primaryLabel): \(title)")
            if let deleteAction {
                Button(action: deleteAction) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Palette.textSecondary)
                .opacity(hovering ? 1 : 0.5)
                .help("Delete script")
                .accessibilityLabel("Delete \(title)")
            }
        }
        .padding(.horizontal, DesignTokens.Layout.cardInset)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2, perform: primaryAction)
        .contextMenu {
            Button(primaryLabel, action: primaryAction)
            if let deleteAction {
                Divider()
                Button("Delete", role: .destructive, action: deleteAction)
            }
        }
    }
}
