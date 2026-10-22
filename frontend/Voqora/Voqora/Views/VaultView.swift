import KeyboardShortcuts
import SwiftUI

struct VaultView: View {
    @EnvironmentObject var history: HistoryManager
    @EnvironmentObject var dashboardVM: DashboardViewModel
    @Environment(\.voqoraTheme) private var theme
    @State private var searchText = ""
    @State private var showOnlyFavorites = false
    @State private var selectedEntry: HistoryEntry?
    @State private var showClearHistoryConfirmation = false

    private var groupedEntries: [(Date, [HistoryEntry])] {
        let matching = history.history.filter { entry in
            (searchText.isEmpty || entry.text.localizedCaseInsensitiveContains(searchText))
                && (!showOnlyFavorites || entry.isFavorite)
        }
        let groups = Dictionary(grouping: matching) { Calendar.current.startOfDay(for: $0.timestamp) }
        return groups.sorted { $0.key > $1.key }
    }

    private var shortcut: String {
        KeyboardShortcuts.getShortcut(for: .playText)?.description ?? "⌘⇧."
    }

    var body: some View {
        let groups = groupedEntries
        PageScaffold(title: "History", subtitle: "Text you listened to with \(shortcut), saved on this Mac.") {
            HStack(spacing: Theme.Space.item) {
                SearchField(text: $searchText, prompt: "Search history")
                    .frame(width: 220)
                FilterChip(title: "Starred", isSelected: showOnlyFavorites, systemImage: "star") {
                    showOnlyFavorites.toggle()
                }
                .help(showOnlyFavorites ? "Show all" : "Show starred only")
                PageActionsMenu {
                    Button("Clear History…", role: .destructive) { showClearHistoryConfirmation = true }
                        .disabled(history.history.isEmpty)
                }
            }
        } content: {
            if let persistenceError = history.persistenceError {
                persistenceBanner(persistenceError)
            }
            if groups.isEmpty {
                emptyState
            } else {
                ForEach(groups, id: \.0) { date, entries in
                    daySection(date: date, entries: entries)
                }
            }
        }
        .navigationTitle("History")
        .sheet(item: $selectedEntry) { entry in
            VaultEntryDetailView(entry: entry)
                .environmentObject(dashboardVM)
                .voqoraTheme()
        }
        .confirmationDialog("Clear History?", isPresented: $showClearHistoryConfirmation, titleVisibility: .visible) {
            Button("Clear History", role: .destructive) { history.clearHistory() }
        } message: {
            Text("This removes everything in History from this Mac.")
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if history.history.isEmpty {
            EmptyStateView(
                symbol: "clock.arrow.circlepath",
                title: "No history yet",
                message: "Text you listen to with \(shortcut) is saved here."
            )
        } else {
            EmptyStateView(
                symbol: showOnlyFavorites && searchText.isEmpty ? "star" : "magnifyingglass",
                title: "No results",
                message: searchText.isEmpty ? "No starred items." : "Nothing in History matches “\(searchText)”."
            )
        }
    }

    private func daySection(date: Date, entries: [HistoryEntry]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.item) {
            Text(Self.dayTitle(for: date))
                .font(dashboardVM.font(.titleSmall))
                .foregroundStyle(theme.primary)
                .padding(.horizontal, Theme.Space.unit)
                .accessibilityAddTraits(.isHeader)
            ListGroup {
                ForEach(entries) { entry in
                    VaultEntryRow(entry: entry, selectedEntry: $selectedEntry)
                }
            }
        }
    }

    private func persistenceBanner(_ message: String) -> some View {
        HStack(spacing: Theme.Space.item) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(theme.warning)
                .accessibilityHidden(true)
            Text(message)
                .font(dashboardVM.font(.body))
                .foregroundStyle(theme.onSurface)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Try Again") { history.retryPersistence() }
                .buttonStyle(.voqoraTonal)
        }
        .padding(Theme.Space.item + 4)
        .background(theme.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.Shape.md, style: .continuous))
    }

    private static func dayTitle(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "Today"
        }
        if calendar.isDateInYesterday(date) {
            return "Yesterday"
        }
        return date.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
    }
}

struct VaultEntryRow: View {
    @EnvironmentObject var history: HistoryManager
    @EnvironmentObject var dashboardVM: DashboardViewModel
    @Environment(\.voqoraTheme) private var theme
    let entry: HistoryEntry
    @Binding var selectedEntry: HistoryEntry?
    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.item + 4) {
            Button(action: play) {
                Image(systemName: "play.fill")
                    .font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(.voqoraIconTonal)
            .help("Play")
            .accessibilityLabel("Play")
            Button { selectedEntry = entry } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.text)
                        .font(dashboardVM.font(.body))
                        .foregroundStyle(theme.onSurface)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text("\(DashboardViewModel.voiceName(for: entry.voice)) · \(entry.timestamp.formatted(.relative(presentation: .named)))")
                        .font(dashboardVM.font(.bodySmall))
                        .foregroundStyle(theme.onSurfaceVariant)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open details")
            Button { history.toggleFavorite(entry: entry) } label: {
                Image(systemName: entry.isFavorite ? "star.fill" : "star")
                    .foregroundStyle(entry.isFavorite ? theme.warning : theme.onSurfaceVariant)
            }
            .buttonStyle(.voqoraIcon)
            .help(entry.isFavorite ? "Remove star" : "Star")
            .accessibilityLabel(entry.isFavorite ? "Unstar" : "Star")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: 72)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isHovering ? theme.surfaceContainerHigh : theme.surfaceContainer,
            in: RoundedRectangle(cornerRadius: Theme.Shape.md, style: .continuous)
        )
        .animation(Theme.Motion.hover, value: isHovering)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Play") { play() }
            Button(entry.isFavorite ? "Unstar" : "Star") { history.toggleFavorite(entry: entry) }
            Button("Copy") { copy(entry.text) }
            Divider()
            Button("Delete", role: .destructive) { history.delete(entry: entry) }
        }
        .accessibilityAction(named: "Play") { play() }
    }

    private func play() {
        Task { await SpeechSource.$current.withValue(.history) { await dashboardVM.speak(text: entry.text) } }
        dashboardVM.selectedTab = TabKey.home
    }
}

struct VaultEntryDetailView: View {
    @Environment(\.dismiss) var dismiss
    @Environment(\.voqoraTheme) private var theme
    @EnvironmentObject var vm: DashboardViewModel
    let entry: HistoryEntry

    var body: some View {
        VoqoraSheet(
            title: entry.timestamp.formatted(.dateTime.month().day().year().hour().minute()),
            supporting: "Narrated by \(DashboardViewModel.voiceName(for: entry.voice))",
            width: 640
        ) {
            VStack(alignment: .leading, spacing: Theme.Space.card) {
                ScrollView {
                    Text(entry.text)
                        .font(vm.font(.body))
                        .foregroundStyle(theme.onSurface)
                        .lineSpacing(6)
                        .textSelection(.enabled)
                        .padding(Theme.Space.card)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 320)
                .background(theme.surfaceContainer, in: RoundedRectangle(cornerRadius: Theme.Shape.lg, style: .continuous))
                HStack(spacing: Theme.Space.item) {
                    Spacer()
                    Button {
                        copy(entry.text)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.voqoraTonal)
                    Button {
                        dismiss()
                        vm.selectedTab = TabKey.home
                        Task { await SpeechSource.$current.withValue(.history) { await vm.speak(text: entry.text) } }
                    } label: {
                        Label("Play", systemImage: "play.fill")
                    }
                    .buttonStyle(.voqoraFilled)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
    }
}

private func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}
