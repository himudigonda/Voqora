import KeyboardShortcuts
import SwiftUI

struct VaultView: View {
    @EnvironmentObject var history: HistoryManager
    @EnvironmentObject var dashboardVM: DashboardViewModel
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
        Group {
            if groups.isEmpty {
                if history.history.isEmpty {
                    VaultPlaceholder(
                        systemImage: "clock.arrow.circlepath",
                        title: "The Vault Is Empty",
                        message: "Text you listen to with \(shortcut) is saved here."
                    )
                } else {
                    VaultPlaceholder(
                        systemImage: showOnlyFavorites && searchText.isEmpty ? "star" : "magnifyingglass",
                        title: "No Results",
                        message: searchText.isEmpty ? "No starred items." : "Nothing in The Vault matches “\(searchText)”."
                    )
                }
            } else {
                List {
                    ForEach(groups, id: \.0) { date, entries in
                        Section {
                            ForEach(entries) { entry in
                                VaultEntryRow(entry: entry, selectedEntry: $selectedEntry)
                            }
                        } header: {
                            Text(date, style: .date)
                                .font(dashboardVM.font(.sectionHeader))
                                .foregroundStyle(Palette.textSecondary)
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
                    Button("Try Again") { history.retryPersistence() }
                        .buttonStyle(.voqoraSecondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Palette.warning.opacity(0.12))
            }
        }
        .navigationTitle("The Vault")
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search Spoken Text")
        .sheet(item: $selectedEntry) { entry in
            VaultEntryDetailView(entry: entry)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Toggle(isOn: $showOnlyFavorites) {
                    Label("Starred", systemImage: showOnlyFavorites ? "star.fill" : "star")
                }
                .toggleStyle(.button)
                .help(showOnlyFavorites ? "Show All" : "Show Starred Only")
                .accessibilityLabel("Show Starred Only")

                Menu {
                    Button("Clear History…", role: .destructive) { showClearHistoryConfirmation = true }
                        .disabled(history.history.isEmpty)
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .help("More")
            }
        }
        .confirmationDialog("Clear History?", isPresented: $showClearHistoryConfirmation, titleVisibility: .visible) {
            Button("Clear History", role: .destructive) { history.clearHistory() }
        } message: {
            Text("This removes everything in The Vault from this Mac.")
        }
    }
}

private struct VaultPlaceholder: View {
    @EnvironmentObject var dashboardVM: DashboardViewModel
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: systemImage)
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(Palette.textTertiary)
            VStack(spacing: 6) {
                Text(title)
                    .font(dashboardVM.font(.sectionTitle))
                    .foregroundStyle(Palette.textPrimary)
                Text(message)
                    .font(dashboardVM.font(.rowTitle))
                    .foregroundStyle(Palette.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct VaultEntryRow: View {
    @EnvironmentObject var history: HistoryManager
    @EnvironmentObject var dashboardVM: DashboardViewModel
    let entry: HistoryEntry
    @Binding var selectedEntry: HistoryEntry?
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(entry.timestamp, style: .time)
                    Text("·")
                    Text(DashboardViewModel.voiceName(for: entry.voice))
                    if entry.isFavorite {
                        Image(systemName: "star.fill")
                            .foregroundStyle(Palette.warning)
                    }
                }
                .font(dashboardVM.font(.caption))
                .foregroundStyle(Palette.textSecondary)
                Text(entry.text)
                    .lineLimit(3)
                    .font(dashboardVM.appFont(size: 15, weight: .medium))
                    .foregroundStyle(Palette.textPrimary)
            }
            Spacer(minLength: 0)
            PlayerCircleButton(systemName: "play.fill", label: "Play") { play() }
                .opacity(hovering ? 1 : 0)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { play() }
        .onTapGesture { selectedEntry = entry }
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
        Task { await dashboardVM.speak(text: entry.text) }
        dashboardVM.selectedTab = "home"
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
                    Text(entry.timestamp, format: .dateTime.month().day().year().hour().minute())
                        .font(vm.appFont(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.textPrimary)
                    Text("Narrated by \(DashboardViewModel.voiceName(for: entry.voice))")
                        .font(vm.font(.caption))
                        .foregroundStyle(Palette.textSecondary)
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(Palette.textSecondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
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
                    .textSelection(.enabled)
                    .padding(32)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 12) {
                Spacer()
                Button {
                    copy(entry.text)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.voqoraSecondary)
                Button {
                    dismiss()
                    vm.selectedTab = "home"
                    Task { await vm.speak(text: entry.text) }
                } label: {
                    Label("Play", systemImage: "play.fill")
                }
                .buttonStyle(.voqoraPrimary)
                .keyboardShortcut(.defaultAction)
            }
            .padding(24)
            .voqoraSurface(.raised, in: Rectangle())
        }
        .frame(minWidth: 500, minHeight: 400)
        .background(Palette.surfaceBase)
    }
}

private func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}
