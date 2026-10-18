import SwiftUI

struct PronunciationBookOption: Identifiable, Hashable {
    let id: String
    let title: String
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
        bookVM.books
            .filter { PronunciationRules.isHexID($0.bookID) }
            .map { PronunciationBookOption(id: $0.bookID, title: $0.displayTitle) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Layout.sectionGap) {
                if isBookScoped {
                    bookHeader
                } else {
                    VoicesPageHeader(page: .pronunciations)
                }
                controls
                if let notice {
                    PronunciationNoticeRow(notice: notice) { self.notice = nil }
                }
                entriesSection
                PronunciationTestCard(store: store, text: $testText)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: 800, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Pronunciations")
        .sheet(item: $editor) { target in
            PronunciationEditorSheet(
                store: store,
                editing: target.entry,
                initialScope: store.defaultScope,
                books: bookOptions
            )
            .environmentObject(vm)
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

    private var bookHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Pronunciations for \(bookTitle ?? "This Book")")
                .font(vm.font(.paneTitle))
                .foregroundStyle(Palette.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text("Used only when Voqora narrates this book, on top of your everyday pronunciations. Changes apply to pages narrated from now on.")
                .font(vm.font(.rowSubtitle))
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var controls: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Palette.textTertiary)
                    .accessibilityHidden(true)
                TextField("Search Pronunciations", text: $store.searchText)
                    .textFieldStyle(.plain)
                    .font(vm.font(.rowTitle))
                    .accessibilityLabel("Search pronunciations")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .voqoraSurface(.control, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous))
            .frame(maxWidth: 260)

            if !isBookScoped {
                Picker("Show", selection: $store.filter) {
                    Text("All").tag(PronunciationFilter.all)
                    Text("Everywhere").tag(PronunciationFilter.scope(.global))
                    if !bookOptions.isEmpty {
                        Divider()
                        ForEach(bookOptions) { book in
                            Text(book.title).tag(PronunciationFilter.scope(.book(book.id)))
                        }
                    }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("Show pronunciations for")
            }

            Spacer(minLength: 0)

            Menu {
                Button("Import…") { importList() }
                    .disabled(store.state != .loaded || transferring)
                Button("Export…") { exportList() }
                    .disabled(store.visibleEntries.isEmpty || transferring)
            } label: {
                Label("Import or Export", systemImage: "square.and.arrow.up.on.square")
            }
            .fixedSize()
            .help("Import or export a pronunciation list")

            Button { editor = .new } label: {
                Label("Add", systemImage: "plus")
            }
            .buttonStyle(.voqoraPrimary)
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(store.state != .loaded || store.isFull)
            .help(store.isFull ? "You can save up to \(store.maxEntries) pronunciations." : "Add Pronunciation")
        }
    }

    @ViewBuilder
    private var entriesSection: some View {
        switch store.state {
        case .idle, .loading:
            HStack(spacing: DesignTokens.Spacing.sm) {
                ProgressView().controlSize(.small)
                Text("Loading pronunciations…")
                    .font(vm.font(.rowTitle))
                    .foregroundStyle(Palette.textSecondary)
            }
            .padding(DesignTokens.Layout.cardInset)
        case let .failed(message):
            VoicesStatusCard(systemImage: "exclamationmark.triangle.fill", message: message, actionTitle: "Try Again") {
                Task { await store.refresh() }
            }
        case .loaded:
            let entries = store.visibleEntries
            if entries.isEmpty {
                VoicesStatusCard(systemImage: "text.bubble", message: emptyMessage)
            } else {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                    PaneSectionHeader(title: entries.count == 1 ? "1 Pronunciation" : "\(entries.count) Pronunciations")
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(entries) { entry in
                            PronunciationRow(
                                entry: entry,
                                scopeName: scopeName(for: entry.scopeValue),
                                showsScope: !isBookScoped,
                                onEdit: { editor = .edit(entry) },
                                onDelete: { pendingDeletion = entry }
                            )
                            if entry.id != entries.last?.id {
                                Divider()
                            }
                        }
                    }
                    .voqoraSurface(.raised, in: RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.xLarge, style: .continuous))
                }
            }
        }
    }

    private var emptyMessage: String {
        if !store.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "No pronunciations match “\(store.searchText)”."
        }
        if isBookScoped {
            return "No pronunciations for this book yet. Add one for a character name or a term only this book uses."
        }
        return "No pronunciations yet. Add one to say “SQL” as “sequel” or to get a name right every time."
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

private struct PronunciationNoticeRow: View {
    @EnvironmentObject var vm: DashboardViewModel
    let notice: PronunciationNotice
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: notice.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(notice.isError ? Palette.warning : Palette.success)
                .accessibilityHidden(true)
            Text(notice.message)
                .font(vm.font(.rowSubtitle))
                .foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button { onDismiss() } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(DesignTokens.Layout.cardInset)
        .background(
            (notice.isError ? Palette.warning : Palette.success).opacity(0.12),
            in: RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.medium, style: .continuous)
        )
    }
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
    @EnvironmentObject var vm: DashboardViewModel
    let entry: PronunciationEntry
    let scopeName: String
    let showsScope: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    private var spokenAs: String {
        entry.replacement.isEmpty ? "Skipped" : entry.replacement
    }

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(entry.match)
                        .font(vm.appFont(size: 14, weight: .semibold))
                        .foregroundStyle(Palette.textPrimary)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Palette.textTertiary)
                        .accessibilityHidden(true)
                    Text(spokenAs)
                        .font(vm.appFont(size: 14))
                        .foregroundStyle(entry.replacement.isEmpty ? Palette.textTertiary : Palette.textPrimary)
                        .italic(entry.replacement.isEmpty)
                }
                .textSelection(.enabled)
                HStack(spacing: 6) {
                    if showsScope {
                        VoicesChip(text: scopeName)
                    }
                    if entry.wholeWord {
                        VoicesChip(text: "Whole word")
                    }
                    if entry.caseSensitive {
                        VoicesChip(text: "Match case")
                    }
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: DesignTokens.Spacing.sm) {
                PlayerCircleButton(systemName: "pencil", label: "Edit \(entry.match)", action: onEdit)
                PlayerCircleButton(systemName: "trash", label: "Delete \(entry.match)", action: onDelete)
            }
            .opacity(hovering ? 1 : 0.5)
        }
        .padding(.horizontal, DesignTokens.Layout.cardInset)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
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
    @Environment(\.dismiss) private var dismiss
    let book: Audiobook

    var body: some View {
        VStack(spacing: 0) {
            PronunciationsView(bookID: book.bookID, bookTitle: book.displayTitle)
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.voqoraPrimary)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(DesignTokens.Spacing.lg)
        }
        .frame(width: 680, height: 620)
        .voqoraSurface(.floating, in: Rectangle())
    }
}
