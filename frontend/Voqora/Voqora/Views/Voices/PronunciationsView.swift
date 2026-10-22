import SwiftUI

struct PronunciationBookOption: Identifiable, Hashable {
    let id: String
    let title: String

    static func disambiguated(_ books: [(id: String, title: String)]) -> [PronunciationBookOption] {
        let ordered = books.sorted {
            let order = $0.title.localizedCaseInsensitiveCompare($1.title)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
        var seen: [String: Int] = [:]
        return ordered.map { book in
            let key = book.title.lowercased()
            let occurrence = (seen[key] ?? 0) + 1
            seen[key] = occurrence
            return PronunciationBookOption(id: book.id, title: occurrence == 1 ? book.title : "\(book.title) (\(occurrence))")
        }
    }
}

struct PronunciationsView: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var bookVM: AudiobookViewModel
    @StateObject private var store: PronunciationStore
    @State private var editor: PronunciationEditorTarget?
    @State private var pendingDeletion: PronunciationEntry?
    @State private var testText = ""
    @State private var notice: PronunciationNotice?
    @State private var transferring = false
    private let bookTitle: String?

    init(bookID: String? = nil, bookTitle: String? = nil) {
        _store = StateObject(wrappedValue: PronunciationStore(bookID: bookID))
        self.bookTitle = bookTitle
    }

    private var isBookScoped: Bool {
        store.bookID != nil
    }

    private var bookOptions: [PronunciationBookOption] {
        PronunciationBookOption.disambiguated(
            bookVM.books
                .filter { PronunciationRules.isHexID($0.bookID) }
                .map { (id: $0.bookID, title: $0.displayTitle) }
        )
    }

    private var pageTitle: String {
        isBookScoped ? "Pronunciations for \(bookTitle ?? "This Book")" : VoicesPage.pronunciations.title
    }

    private var pageSubtitle: String {
        isBookScoped
            ? "Used only when Voqora narrates this book, on top of your everyday pronunciations. Changes apply to pages narrated from now on."
            : VoicesPage.pronunciations.subtitle
    }

    var body: some View {
        PageScaffold(title: pageTitle, subtitle: pageSubtitle) {
            accessory
        } content: {
            PronunciationTestCard(store: store, text: $testText)
            if let notice {
                VoicesBanner(
                    message: notice.message,
                    systemImage: notice.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill",
                    isError: notice.isError,
                    actionTitle: "Dismiss"
                ) { self.notice = nil }
            }
            controls
            entriesSection
        }
        .navigationTitle(VoicesPage.pronunciations.title)
        .sheet(item: $editor) { target in
            PronunciationEditorSheet(
                store: store,
                editing: target.entry,
                initialScope: store.defaultScope,
                books: bookOptions
            )
            .voqoraSheetContent(vm)
        }
        .confirmationDialog(
            "Delete this pronunciation?",
            isPresented: isConfirmingDeletion,
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { entry in
            Button("Delete", role: .destructive) { delete(entry) }
        } message: { entry in
            Text("Voqora will read “\(entry.match)” as written again.")
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

    private var accessory: some View {
        HStack(spacing: Theme.Space.item) {
            Button { editor = .new } label: {
                Label("Add Rule", systemImage: "plus")
            }
            .buttonStyle(.voqoraFilled)
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(store.state != .loaded || store.isFull)
            .help(store.isFull ? "You can save up to \(store.maxEntries) pronunciations." : "Add a pronunciation rule")
            PageActionsMenu(label: "Import or export a pronunciation list") {
                Button("Import…") { importList() }
                    .disabled(store.state != .loaded || transferring)
                Button("Export…") { exportList() }
                    .disabled(store.visibleEntries.isEmpty || transferring)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: Theme.Space.item) {
            if !isBookScoped {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        FilterChip(title: "All", isSelected: store.filter == .all) { store.filter = .all }
                        FilterChip(title: "Everywhere", isSelected: store.filter == .scope(.global)) { store.filter = .scope(.global) }
                        ForEach(bookOptions) { book in
                            FilterChip(title: book.title, isSelected: store.filter == .scope(.book(book.id)), systemImage: "book") {
                                store.filter = .scope(.book(book.id))
                            }
                        }
                    }
                }
            } else {
                Spacer(minLength: 0)
            }
            SearchField(text: $store.searchText, prompt: "Search rules")
                .frame(width: 240)
        }
    }

    @ViewBuilder
    private var entriesSection: some View {
        switch store.state {
        case .idle, .loading:
            VoicesLoadingRow(text: "Loading pronunciations…")
        case let .failed(message):
            VoicesBanner(message: message, actionTitle: "Try Again") {
                Task { await store.refresh() }
            }
        case .loaded:
            let entries = store.visibleEntries
            if entries.isEmpty {
                emptyState
            } else {
                VStack(alignment: .leading, spacing: Theme.Space.item) {
                    VoicesSectionHeader(title: entries.count == 1 ? "1 rule" : "\(entries.count) rules")
                    ListGroup {
                        ForEach(entries) { entry in
                            PronunciationRow(
                                entry: entry,
                                scopeName: scopeName(for: entry.scopeValue),
                                showsScope: !isBookScoped,
                                onEdit: { editor = .edit(entry) },
                                onDelete: { pendingDeletion = entry }
                            )
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if store.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            EmptyStateView(
                symbol: "text.bubble",
                title: "No pronunciations yet",
                message: emptyMessage,
                action: store.isFull ? nil : EmptyStateAction(title: "Add Rule") { editor = .new }
            )
        } else {
            EmptyStateView(symbol: "magnifyingglass", title: "No matches", message: emptyMessage)
        }
    }

    private var emptyMessage: String {
        if !store.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "No pronunciations match “\(store.searchText)”."
        }
        if isBookScoped {
            return "Add one for a character name or a term only this book uses."
        }
        return "Add one to say “SQL” as “sequel” or to get a name right every time."
    }

    private func scopeName(for scope: PronunciationScope) -> String {
        switch scope {
        case .global:
            "Everywhere"
        case let .book(id):
            bookOptions.first { $0.id == id }?.title ?? "Removed book"
        }
    }

    private func delete(_ entry: PronunciationEntry) {
        pendingDeletion = nil
        Task {
            do {
                try await store.delete(entry)
            } catch {
                notice = PronunciationNotice(message: error.localizedDescription, isError: true)
            }
        }
    }

    private func importList() {
        guard let url = PronunciationFilePanels.chooseImportFile() else { return }
        transferring = true
        notice = nil
        Task {
            defer { transferring = false }
            do {
                let data = try PronunciationFilePanels.readImport(from: url)
                let summary = try await store.importFile(data)
                notice = PronunciationNotice(message: summary.message, isError: false)
            } catch {
                VoqoraLog.warn("PronunciationsView", "Pronunciation import failed")
                notice = PronunciationNotice(message: error.localizedDescription, isError: true)
            }
        }
    }

    private func exportList() {
        notice = nil
        do {
            let data = try store.exportData()
            let suggested = isBookScoped ? "\(bookTitle ?? "Book") Pronunciations.json" : "Voqora Pronunciations.json"
            guard let url = PronunciationFilePanels.chooseExportDestination(suggestedName: suggested) else { return }
            try data.write(to: url, options: .atomic)
            notice = PronunciationNotice(message: "Exported \(url.lastPathComponent).", isError: false)
        } catch {
            VoqoraLog.warn("PronunciationsView", "Pronunciation export failed")
            notice = PronunciationNotice(message: error.localizedDescription, isError: true)
        }
    }
}

struct PronunciationNotice: Equatable {
    let message: String
    let isError: Bool
}

enum PronunciationEditorTarget: Identifiable {
    case new
    case edit(PronunciationEntry)

    var id: String {
        switch self {
        case .new: "new"
        case let .edit(entry): entry.id
        }
    }

    var entry: PronunciationEntry? {
        if case let .edit(entry) = self {
            return entry
        }
        return nil
    }
}

private struct PronunciationRow: View {
    let entry: PronunciationEntry
    let scopeName: String
    let showsScope: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void

    private var spokenAs: String {
        entry.replacement.isEmpty ? "skipped" : entry.replacement
    }

    var body: some View {
        ListItem(
            title: "\(entry.match) → \(spokenAs)",
            systemImage: "text.bubble",
            trailing: {
                HStack(spacing: 8) {
                    if showsScope {
                        StatusChip(text: scopeName, kind: .info)
                    }
                    if entry.wholeWord {
                        StatusChip(text: "Whole word")
                    }
                    if entry.caseSensitive {
                        StatusChip(text: "Match case")
                    }
                    Button(action: onEdit) {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.voqoraIcon)
                    .help("Edit \(entry.match)")
                    .accessibilityLabel("Edit \(entry.match)")
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.voqoraIcon)
                    .help("Delete \(entry.match)")
                    .accessibilityLabel("Delete \(entry.match)")
                }
            }
        )
        .onTapGesture(count: 2, perform: onEdit)
        .contextMenu {
            Button("Edit…", action: onEdit)
            Divider()
            Button("Delete…", role: .destructive, action: onDelete)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(entry.match), said as \(spokenAs)")
    }
}

struct BookPronunciationsSheet: View {
    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.dismiss) private var dismiss
    let book: Audiobook

    var body: some View {
        VStack(spacing: 0) {
            PronunciationsView(bookID: book.bookID, bookTitle: book.displayTitle)
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.voqoraFilled)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(Theme.Space.card)
        }
        .frame(width: 860, height: 700)
        .background(vm.theme.surface)
        .voqoraTheme()
    }
}
