import SwiftUI

struct ScriptsView: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var studio: StudioViewModel
    @EnvironmentObject var bookVM: AudiobookViewModel
    @ObservedObject var drafts: StudioDraftStore
    @Environment(\.voqoraTheme) private var theme
    @State private var pendingDeletion: PodcastDraft?

    private var podcasts: [Audiobook] {
        bookVM.books.filter(\.isPodcast)
    }

    var body: some View {
        PageScaffold(
            title: "Scripts",
            subtitle: "Write your own multi-voice script, or edit one the AI wrote.",
            accessory: {
                Button {
                    studio.startBlankScript()
                } label: {
                    Label("New Script", systemImage: "plus")
                }
                .buttonStyle(.voqoraFilled)
                .keyboardShortcut("b", modifiers: [.command, .shift])
            }
        ) {
            VStack(alignment: .leading, spacing: Theme.Space.section) {
                if let notice = studio.notice {
                    StudioBanner(message: notice) { studio.notice = nil }
                }
                if let error = drafts.persistenceError {
                    StudioBanner(message: error)
                }
                if drafts.drafts.isEmpty, podcasts.isEmpty {
                    EmptyStateView(
                        symbol: "text.badge.plus",
                        title: "No scripts yet",
                        message: "Scripts you generate or write are saved here as you edit. Rendered podcasts show up here too.",
                        action: EmptyStateAction(title: "New Script") { studio.startBlankScript() }
                    )
                } else {
                    draftsSection
                    podcastsSection
                }
            }
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

    private var draftsSection: some View {
        SettingsSection(title: "Drafts") {
            if drafts.drafts.isEmpty {
                emptyRow("Scripts you generate or write are saved here as you edit.")
            } else {
                ForEach(drafts.drafts) { draft in
                    ListItem(
                        title: draft.script.title.isEmpty ? "Untitled Script" : draft.script.title,
                        supporting: draftDetail(draft),
                        systemImage: "text.document",
                        trailing: {
                            HStack(spacing: 8) {
                                Button("Open") { studio.open(draft) }
                                    .buttonStyle(.voqoraTonal)
                                    .accessibilityLabel("Open \(draft.script.title)")
                                Menu {
                                    Button("Open") { studio.open(draft) }
                                    Divider()
                                    Button("Delete…", role: .destructive) { pendingDeletion = draft }
                                } label: {
                                    Image(systemName: "ellipsis")
                                }
                                .menuStyle(.button)
                                .buttonStyle(.voqoraIcon)
                                .menuIndicator(.hidden)
                                .fixedSize()
                                .accessibilityLabel("More options for \(draft.script.title)")
                            }
                        }
                    )
                }
            }
        }
    }

    private var podcastsSection: some View {
        SettingsSection(
            title: "Rendered podcasts",
            footer: podcasts.isEmpty ? nil : "Opening one edits a copy of its script. Rendering makes a new podcast and keeps the original."
        ) {
            if podcasts.isEmpty {
                emptyRow("Rendered podcasts appear in your Library with a Podcast badge. Open one here to edit its script.")
            } else {
                ForEach(podcasts) { book in
                    ListItem(
                        title: book.displayTitle,
                        supporting: book.creditLine,
                        systemImage: "waveform",
                        trailing: {
                            HStack(spacing: 8) {
                                Button(studio.openingBookID == book.bookID ? "Opening…" : "Edit Script") {
                                    studio.openRenderedPodcast(bookID: book.bookID)
                                }
                                .buttonStyle(.voqoraTonal)
                                .disabled(studio.openingBookID != nil)
                                Menu {
                                    Button("Show in Library") { vm.showLibrary() }
                                } label: {
                                    Image(systemName: "ellipsis")
                                }
                                .menuStyle(.button)
                                .buttonStyle(.voqoraIcon)
                                .menuIndicator(.hidden)
                                .fixedSize()
                                .accessibilityLabel("More options for \(book.displayTitle)")
                            }
                        }
                    )
                }
            }
        }
    }

    private func emptyRow(_ message: String) -> some View {
        Text(message)
            .voqoraFont(.body)
            .foregroundStyle(theme.onSurfaceVariant)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.card)
            .background(theme.surfaceContainer, in: RoundedRectangle(cornerRadius: Theme.Shape.md, style: .continuous))
    }

    private func draftDetail(_ draft: PodcastDraft) -> String {
        let turns = draft.script.turns.count
        let speakers = draft.script.speakers.count
        let edited = draft.updatedAt.formatted(.relative(presentation: .named))
        return "\(turns) \(turns == 1 ? "turn" : "turns") · \(speakers) \(speakers == 1 ? "speaker" : "speakers") · Edited \(edited)"
    }
}
