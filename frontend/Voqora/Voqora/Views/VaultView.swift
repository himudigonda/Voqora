import SwiftUI

struct VaultView: View {
    @EnvironmentObject var history: HistoryManager
    @EnvironmentObject var dashboardVM: DashboardViewModel
    @State private var searchText = ""
    @State private var showOnlyFavorites = false
    @State private var selectedEntry: HistoryEntry? = nil

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

    var body: some View {
        List {
            ForEach(groupedEntries, id: \.0) { date, entries in
                Section(header: Text(date, style: .date)
                    .font(dashboardVM.appFont(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .kerning(1))
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
                            .foregroundStyle(showOnlyFavorites ? .yellow : .secondary)
                    }
                    .help("Show starred snippets only")

                    Button(role: .destructive) {
                        history.clearHistory()
                    } label: {
                        Label("Clear All", systemImage: "trash.slash")
                    }
                    .help("Clear entire history")
                    .disabled(history.history.isEmpty)
                }
            }
        }
    }
}

struct VaultEntryRow: View {
    @EnvironmentObject var history: HistoryManager
    @EnvironmentObject var dashboardVM: DashboardViewModel
    let entry: HistoryEntry
    @Binding var selectedEntry: HistoryEntry?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(entry.timestamp, style: .time)
                    .font(dashboardVM.appFont(size: 10, weight: .regular))
                    .foregroundColor(.cyan)
                Spacer()

                if entry.isFavorite {
                    Image(systemName: "star.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.yellow)
                }

                Text(entry.voice)
                    .font(dashboardVM.appFont(size: 8, weight: .regular))
                    .foregroundColor(.secondary)
            }
            Text(entry.text)
                .lineLimit(3)
                .font(dashboardVM.appFont(size: 15, weight: .medium))
                .foregroundStyle(.primary.opacity(0.9))
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
    let entry: HistoryEntry

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.timestamp, style: .date)
                        .font(vm.appFont(size: 12, weight: .bold))
                    Text(entry.voice.uppercased())
                        .font(vm.appFont(size: 10, weight: .black))
                        .foregroundStyle(.cyan)
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(24)
            .background(.ultraThinMaterial)

            ScrollView {
                Text(entry.text)
                    .font(vm.appFont(size: 18, weight: .regular))
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
                        .font(vm.appFont(size: 12, weight: .black))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Color.cyan)
                        .foregroundStyle(.black)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.text, forType: .string)
                } label: {
                    Label("COPY", systemImage: "doc.on.doc.fill")
                        .font(vm.appFont(size: 12, weight: .bold))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(24)
            .background(.ultraThinMaterial)
        }
        .frame(minWidth: 500, minHeight: 400)
        .background(Color(NSColor.windowBackgroundColor))
    }
}
