import SwiftUI

struct VaultView: View {
    @EnvironmentObject var history: HistoryManager
    @EnvironmentObject var dashboardVM: DashboardViewModel
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.colorSchemeContrast) var colorSchemeContrast
    @State private var searchText = ""
    @State private var showOnlyFavorites = false
    @State private var selectedEntry: HistoryEntry? = nil
    @State private var showClearHistoryConfirmation = false

    private var accentColor: Color {
        dashboardVM.accentColor(scheme: colorScheme, contrast: colorSchemeContrast)
    }

    /// Group entries by day
    private var groupedEntries: [(Date, [HistoryEntry])] {
        let sorted = history.history.filter { entry in
            let matchesSearch = searchText.isEmpty || entry.text.localizedCaseInsensitiveContains(searchText)
            let matchesFavorite = !showOnlyFavorites || entry.isFavorite
            return matchesSearch && matchesFavorite
        }

        let groups = Dictionary(grouping: sorted) { entry in
            Calendar.current.startOfDay(for: entry.timestamp)
        }
        return groups.sorted { $0.key > $1.key }
    }

    /// Distinguishes "genuinely no history yet" from "search/filter matched
    /// nothing" — VaultView previously had neither state at all; an empty
    /// or filtered-to-nothing list just rendered blank with no explanation,
    /// unlike AudiobookLibraryView's equivalent three-tier state handling.
    private var showsNoResultsState: Bool {
        groupedEntries.isEmpty && !(searchText.isEmpty && !showOnlyFavorites)
    }

    var body: some View {
        Group {
            if groupedEntries.isEmpty {
                if showsNoResultsState {
                    noResultsState
                } else {
                    emptyState
                }
            } else {
                List {
                    ForEach(groupedEntries, id: \.0) { date, entries in
                        Section(header: Text(date, style: .date)
                            .font(dashboardVM.font(.sectionHeader))
                            .foregroundStyle(Palette.textSecondary)
                            .kerning(0.6))
                        {
                            ForEach(entries) { entry in
                                VaultEntryRow(entry: entry, selectedEntry: $selectedEntry)
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        Button(role: .destructive) {
                                            history.delete(entry: entry)
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }

                                        Button {
                                            history.toggleFavorite(entry: entry)
                                        } label: {
                                            Label(entry.isFavorite ? "Unstar" : "Star", systemImage: entry.isFavorite ? "star.slash" : "star.fill")
                                        }
                                        .tint(.yellow)
                                    }
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .overlay(alignment: .top) {
            if let persistenceError = history.persistenceError {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Palette.warning)
                    Text(persistenceError)
                        .font(dashboardVM.font(.rowSubtitle))
                        .foregroundStyle(Palette.textPrimary)
                    Spacer()
                    Button("Try again") { history.retryPersistence() }
                        .buttonStyle(.voqoraSecondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Palette.warning.opacity(0.12))
            }
        }
        .navigationTitle("Vault")
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search spoken text...")
        .sheet(item: $selectedEntry) { entry in
            VaultEntryDetailView(entry: entry)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 15) {
                    Button { showOnlyFavorites.toggle() } label: {
                        Image(systemName: showOnlyFavorites ? "star.fill" : "star")
                            .foregroundStyle(showOnlyFavorites ? .yellow : Palette.textSecondary)
                    }
                    .help("Show starred snippets only")
                    // A bare star glyph carries no name at all, so VoiceOver
                    // announced this filter as an unlabelled "button". The
                    // label states the action the press performs, and the
                    // trait carries the state the fill/outline conveys
                    // visually — matching `AccentSwatchButton`'s pattern.
                    .accessibilityLabel(showOnlyFavorites ? "Show all snippets" : "Show starred snippets only")
                    .accessibilityAddTraits(showOnlyFavorites ? [.isSelected] : [])

                    Button(role: .destructive) {
                        showClearHistoryConfirmation = true
                    } label: {
                        Label("Clear All", systemImage: "trash.slash")
                    }
                    .help("Clear entire history")
                    // macOS collapses a toolbar `Label` to its icon, so name
                    // it explicitly rather than relying on the title survivng
                    // that collapse.
                    .accessibilityLabel("Clear All")
                    .disabled(history.history.isEmpty)
                }
            }
        }
        .confirmationDialog(
            "Clear all spoken history?",
            isPresented: $showClearHistoryConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear History", role: .destructive) {
                history.clearHistory()
            }
        } message: {
            Text("This removes your saved spoken-text history from this Mac.")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 22) {
            Image(systemName: "text.bubble")
                .font(.system(size: 96, weight: .ultraLight))
                .foregroundStyle(Palette.textTertiary.opacity(0.5))
            VStack(spacing: 6) {
                Text("YOUR VAULT IS EMPTY")
                    .font(dashboardVM.font(.sectionTitle))
                    .kerning(0.4)
                    .foregroundStyle(Palette.textSecondary)
                Text("Select text in any app and press Cmd+Shift+. to hear it — spoken passages are saved here.")
                    .font(dashboardVM.font(.rowTitle))
                    .foregroundStyle(Palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noResultsState: some View {
        VStack(spacing: 22) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 96, weight: .ultraLight))
                .foregroundStyle(Palette.textTertiary.opacity(0.5))
            VStack(spacing: 6) {
                Text("NO MATCHES")
                    .font(dashboardVM.font(.sectionTitle))
                    .kerning(0.4)
                    .foregroundStyle(Palette.textSecondary)
                Text(searchText.isEmpty ? "No starred snippets yet." : "No spoken text matches \u{201C}\(searchText)\u{201D}. Try a different search.")
                    .font(dashboardVM.font(.rowTitle))
                    .foregroundStyle(Palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct VaultEntryRow: View {
    @EnvironmentObject var history: HistoryManager
    @EnvironmentObject var dashboardVM: DashboardViewModel
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.colorSchemeContrast) var colorSchemeContrast
    let entry: HistoryEntry
    @Binding var selectedEntry: HistoryEntry?

    private var accentColor: Color {
        dashboardVM.accentColor(scheme: colorScheme, contrast: colorSchemeContrast)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(entry.timestamp, style: .time)
                    .font(dashboardVM.font(.caption))
                    .foregroundColor(accentColor)
                Spacer()

                if entry.isFavorite {
                    Image(systemName: "star.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.yellow)
                }

                Text(entry.voice)
                    .font(dashboardVM.appFont(size: 8, weight: .regular))
                    .foregroundColor(Palette.textSecondary)
            }
            Text(entry.text)
                .lineLimit(3)
                .font(dashboardVM.appFont(size: 15, weight: .medium))
                .foregroundStyle(Palette.textPrimary.opacity(0.9))
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            selectedEntry = entry
        }
        .contextMenu {
            Button("Re-Speak") {
                Task { await dashboardVM.speak(text: entry.text) }
            }
            Button(entry.isFavorite ? "Unstar" : "Star") {
                history.toggleFavorite(entry: entry)
            }
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.text, forType: .string)
            }
            Divider()
            Button(role: .destructive) {
                history.delete(entry: entry)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

struct VaultEntryDetailView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.colorSchemeContrast) var colorSchemeContrast
    let entry: HistoryEntry

    private var accentColor: Color {
        vm.accentColor(scheme: colorScheme, contrast: colorSchemeContrast)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.timestamp, style: .date)
                        .font(vm.appFont(size: 12, weight: .bold))
                        .foregroundStyle(Palette.textPrimary)
                    Text(entry.voice.uppercased())
                        .font(vm.font(.sectionHeader))
                        .kerning(0.6)
                        .foregroundStyle(accentColor)
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(Palette.textSecondary)
                }
                .buttonStyle(.plain)
                // The only way out of this sheet, and it was nameless —
                // matching `UploadEstimateModal`'s already-labelled close.
                .accessibilityLabel("Close")
                .help("Close")
            }
            .padding(24)
            .voqoraSurface(.raised, in: Rectangle())

            ScrollView {
                Text(entry.text)
                    .font(vm.appFont(size: 18, weight: .regular))
                    .foregroundStyle(Palette.textPrimary)
                    .lineSpacing(8)
                    .padding(32)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 16) {
                Button {
                    Task {
                        dismiss()
                        await vm.speak(text: entry.text)
                    }
                } label: {
                    Label("RE-SPEAK", systemImage: "play.fill")
                }
                .buttonStyle(.voqoraPrimary)

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.text, forType: .string)
                } label: {
                    Label("COPY", systemImage: "doc.on.doc.fill")
                }
                .buttonStyle(.voqoraSecondary)
            }
            .padding(24)
            .voqoraSurface(.raised, in: Rectangle())
        }
        .frame(minWidth: 500, minHeight: 400)
        .background(Palette.surfaceBase)
    }
}
