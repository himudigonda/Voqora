import SwiftUI
import UniformTypeIdentifiers

enum AudiobookRoute: Hashable {
    case player(String)
}

enum LibrarySheet: Identifiable {
    case completion(Audiobook)
    case fixProvider(AudiobookViewModel.ProviderFix)

    var id: String {
        switch self {
        case let .fixProvider(fix): "fix-\(fix.id)"
        case let .completion(book): "completion-\(book.bookID)"
        }
    }

    static func honorsDismissal(presentedID: String?, currentID: String?) -> Bool {
        guard let presentedID, let currentID else { return false }
        return presentedID == currentID
    }
}

@MainActor
final class LibrarySheetPresentation {
    private(set) var presentedID: String?

    func didAppear(_ id: String) {
        presentedID = id
    }

    func didDisappear(_ id: String) {
        if presentedID == id {
            presentedID = nil
        }
    }
}

struct AudiobookLibraryView: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var bookVM: AudiobookViewModel
    @Environment(\.voqoraTheme) private var theme

    @State private var hoveringDrop = false
    @State private var searchText = ""
    @State private var filter: LibraryFilter = .all
    @AppStorage("librarySortMode") private var sort: LibrarySortMode = .recent
    @State private var showDeleteAllConfirmation = false
    @State private var sheetPresentation = LibrarySheetPresentation()

    private let columns = [GridItem(.adaptive(minimum: 170), spacing: Theme.Space.section - 8, alignment: .top)]

    var body: some View {
        ZStack {
            switch bookVM.libraryPath.last {
            case let .player(bookID):
                playerDestination(bookID)
                    .transition(.opacity)
            case nil:
                browser
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: bookVM.libraryPath)
        .sheet(item: librarySheetBinding, onDismiss: { bookVM.offerResumeAfterFix() }) { sheet in
            sheetContent(sheet)
                .onAppear { sheetPresentation.didAppear(sheet.id) }
                .onDisappear { sheetPresentation.didDisappear(sheet.id) }
        }
        .confirmationDialog(
            retryPromptTitle,
            isPresented: retryPromptBinding,
            titleVisibility: .visible,
            presenting: bookVM.retryPrompt
        ) { prompt in
            retryPromptActions(prompt)
        } message: { prompt in
            Text(retryPromptMessage(prompt))
        }
        .alert(
            "Resume \"\(bookVM.resumeOffer?.book.displayTitle ?? "this audiobook")\"?",
            isPresented: resumeOfferBinding,
            presenting: bookVM.resumeOffer
        ) { fix in
            Button("Resume") { bookVM.resumeAfterFix(fix) }
            Button("Not Now", role: .cancel) { bookVM.resumeOffer = nil }
        } message: { fix in
            Text(resumeMessage(fix))
        }
        .onAppear { bookVM.startPolling() }
        .onDisappear { bookVM.stopPolling() }
    }

    private var browser: some View {
        ZStack {
            content
            if hoveringDrop {
                dropOverlay.transition(.opacity)
            }
        }
        .navigationTitle("Library")
        .onDrop(of: [.fileURL], isTargeted: $hoveringDrop) { providers in
            bookVM.importDroppedDocuments(providers, defaultVoice: vm.selectedVoice, defaultSpeed: vm.speechSpeed)
        }
        .alert("Delete All Audiobooks?", isPresented: $showDeleteAllConfirmation) {
            Button("Delete All", role: .destructive) { bookVM.deleteAllBooks() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes every audiobook and its source file. You can't undo this action.")
        }
    }

    private func playerDestination(_ bookID: String) -> some View {
        Group {
            if let book = bookVM.books.first(where: { $0.bookID == bookID }) {
                AudiobookPlayerView(book: book, onBack: closePlayer)
            } else if bookVM.hasLoadedOnce {
                Color.clear.onAppear { closePlayer() }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("")
        .background {
            Button("Back to Library", action: closePlayer)
                .keyboardShortcut("[", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .onExitCommand(perform: closePlayer)
    }

    private func closePlayer() {
        bookVM.libraryPath = []
    }

    @ViewBuilder
    private func sheetContent(_ sheet: LibrarySheet) -> some View {
        switch sheet {
        case let .completion(book):
            CompletionSummaryModal(book: book, onListenNow: { bookVM.openPlayer(for: $0.bookID) })
                .environmentObject(vm)
                .environmentObject(bookVM)
        case let .fixProvider(fix):
            AddProviderSheet(provider: fix.provider, cleaningCount: bookVM.cleaningBookCount(using:))
                .environmentObject(vm)
                .environmentObject(bookVM.providers)
        }
    }

    private var currentLibrarySheet: LibrarySheet? {
        if let book = bookVM.completionSummary {
            return .completion(book)
        }
        if let fix = bookVM.providerFix {
            return .fixProvider(fix)
        }
        return nil
    }

    private var librarySheetBinding: Binding<LibrarySheet?> {
        Binding(
            get: { currentLibrarySheet },
            set: { newValue in
                guard newValue == nil,
                      LibrarySheet.honorsDismissal(
                          presentedID: sheetPresentation.presentedID,
                          currentID: currentLibrarySheet?.id
                      )
                else { return }
                if bookVM.completionSummary != nil {
                    bookVM.completionSummary = nil
                } else if bookVM.providerFix != nil {
                    bookVM.endProviderFix()
                }
            }
        )
    }

    private var retryPromptBinding: Binding<Bool> {
        Binding(
            get: { bookVM.retryPrompt != nil },
            set: {
                if !$0 {
                    bookVM.retryPrompt = nil
                }
            }
        )
    }

    private var resumeOfferBinding: Binding<Bool> {
        Binding(
            get: { bookVM.resumeOffer != nil },
            set: {
                if !$0 {
                    bookVM.resumeOffer = nil
                }
            }
        )
    }

    private var retryPromptTitle: String {
        switch bookVM.retryPrompt {
        case let .switchProvider(_, startedWith, active, _):
            "This audiobook was cleaned with \(startedWith.displayName). Continue with \(active.displayName)?"
        case let .needsProvider(book, _):
            "Choose how to continue \"\(book.displayTitle)\""
        case nil:
            ""
        }
    }

    private func retryPromptMessage(_ prompt: AudiobookViewModel.RetryPrompt) -> String {
        switch prompt {
        case .switchProvider:
            "Pages already cleaned stay as they are. Only the remaining pages use the provider you choose."
        case .needsProvider:
            "This audiobook needs AI cleanup to continue. Choose a provider, or finish it without AI."
        }
    }

    @ViewBuilder
    private func retryPromptActions(_ prompt: AudiobookViewModel.RetryPrompt) -> some View {
        switch prompt {
        case let .switchProvider(book, startedWith, active, startedWithConnected):
            Button("Use \(active.displayName)") { bookVM.retry(book, using: active) }
            if startedWithConnected {
                Button("Use \(startedWith.displayName)") { bookVM.retry(book, using: startedWith) }
            }
            Button("Cancel", role: .cancel) {}
        case let .needsProvider(book, connected):
            ForEach(connected) { provider in
                Button("Use \(provider.displayName)") { bookVM.retry(book, using: provider) }
            }
            Button("Add Provider…") { bookVM.addProviderToResume(book) }
            Button("Finish Without AI") { bookVM.finishWithoutAI(book) }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func resumeMessage(_ fix: AudiobookViewModel.ProviderFix) -> String {
        let name = (fix.provider ?? bookVM.providers.activeProvider)?.displayName
        return name.map { "Voqora will continue where it stopped, using \($0)." } ?? "Voqora will continue where it stopped."
    }

    private var librarySubtitle: String {
        guard bookVM.hasLoadedOnce, !bookVM.books.isEmpty else {
            return "Documents, articles, and podcasts you turned into audio."
        }
        let count = bookVM.books.count
        return "\(count) \(count == 1 ? "item" : "items") on this Mac."
    }

    private var content: some View {
        PageScaffold(title: "Library", subtitle: librarySubtitle) {
            accessory
        } content: {
            VStack(alignment: .leading, spacing: Theme.Space.card) {
                if bookVM.hasLoadedOnce, !bookVM.books.isEmpty {
                    filterRow
                }
                libraryBody
            }
        }
    }

    private var accessory: some View {
        HStack(spacing: Theme.Space.item) {
            SearchField(text: $searchText, prompt: "Search library")
                .frame(minWidth: 120, maxWidth: 220)
            Menu {
                Picker("Sort By", selection: $sort) {
                    ForEach(LibrarySortMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(theme.onPrimaryContainer)
                    .frame(width: 40, height: 40)
                    .background(theme.primaryContainer.opacity(0.65), in: Circle())
                    .contentShape(Circle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Sort By")
            .accessibilityLabel("Sort By")
            Menu {
                Button("Delete All Audiobooks…", role: .destructive) { showDeleteAllConfirmation = true }
                    .disabled(bookVM.books.isEmpty || bookVM.deletingAllBooks)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(theme.onPrimaryContainer)
                    .frame(width: 40, height: 40)
                    .background(theme.primaryContainer.opacity(0.65), in: Circle())
                    .contentShape(Circle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
            .accessibilityLabel("More")
            Button {
                vm.selectedTab = TabKey.createAudiobook
            } label: {
                Label("New Audiobook", systemImage: "plus")
            }
            .buttonStyle(.voqoraFilled)
        }
    }

    private var filterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(LibraryFilter.allCases) { option in
                    FilterChip(title: option.title, isSelected: filter == option) {
                        filter = option
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private var libraryBody: some View {
        if !bookVM.hasLoadedOnce {
            skeletonGrid
        } else if bookVM.loadFailed, bookVM.books.isEmpty {
            loadFailedState
        } else if bookVM.books.isEmpty {
            emptyState
        } else if Self.showsNoResultsState(searchText: searchText, matchCount: filteredSorted.count) {
            noResultsState
        } else if filteredSorted.isEmpty {
            EmptyStateView(symbol: "line.3.horizontal.decrease.circle", title: "Nothing in \(filter.title)", message: filter.emptyMessage)
        } else {
            LazyVGrid(columns: columns, spacing: Theme.Space.section - 4) {
                ForEach(filteredSorted, id: \.id) { book in
                    AudiobookCardView(book: book) { openBook(book) }
                }
            }
        }
    }

    private var skeletonGrid: some View {
        LazyVGrid(columns: columns, spacing: Theme.Space.section - 4) {
            ForEach(0 ..< 6, id: \.self) { _ in SkeletonCard() }
        }
    }

    static func showsNoResultsState(searchText: String, matchCount: Int) -> Bool {
        !searchText.isEmpty && matchCount == 0
    }

    static func matches(_ book: Audiobook, searchText: String) -> Bool {
        book.displayTitle.localizedCaseInsensitiveContains(searchText)
            || (book.displayAuthor?.localizedCaseInsensitiveContains(searchText) ?? false)
    }

    private var filteredSorted: [Audiobook] {
        var result = bookVM.books
        if !searchText.isEmpty {
            result = result.filter { Self.matches($0, searchText: searchText) }
        }
        if filter != .all {
            result = result.filter { book in
                filter.includes(
                    book,
                    status: bookVM.processingState[book.bookID] ?? book.displayStatus,
                    listenedFraction: bookVM.listenedFraction(for: book)
                )
            }
        }
        return sort.sorted(result)
    }

    private func openBook(_ book: Audiobook) {
        if (bookVM.processingState[book.bookID] ?? book.displayStatus).isReady {
            bookVM.openPlayer(for: book.bookID)
        }
    }

    private var dropOverlay: some View {
        DocumentDropOverlay(subtitle: AudiobookImportStaging.supportedFormatsDescription, appFont: vm.appFont)
            .animation(.easeInOut(duration: 0.25), value: hoveringDrop)
    }

    private var emptyState: some View {
        EmptyStateView(
            symbol: "books.vertical",
            title: "Your library is empty",
            message: "Turn a document, web page, or pasted text into an audiobook. You can also drop a PDF, EPUB, Word, HTML, text, or Markdown file anywhere in this window.",
            action: EmptyStateAction(title: "New Audiobook") { vm.selectedTab = TabKey.createAudiobook }
        )
    }

    private var loadFailedState: some View {
        EmptyStateView(
            symbol: "exclamationmark.triangle",
            title: "Couldn't Load Library",
            message: "The speech engine isn't responding.",
            action: EmptyStateAction(title: "Try Again") { Task { await bookVM.refresh() } }
        )
    }

    private var noResultsState: some View {
        EmptyStateView(
            symbol: "magnifyingglass",
            title: "No Results",
            message: "No items match “\(searchText)”."
        )
    }
}

private struct SkeletonCard: View {
    @Environment(\.voqoraTheme) private var theme
    @State private var phase: CGFloat = -1

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RoundedRectangle(cornerRadius: Theme.Shape.md, style: .continuous)
                .fill(theme.surfaceContainerHigh)
                .aspectRatio(BookCover.aspectRatio, contentMode: .fit)
                .overlay(shimmer)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Shape.md, style: .continuous))
            Capsule()
                .fill(theme.surfaceContainerHigh)
                .frame(width: 130, height: 12)
                .overlay(shimmer)
                .clipShape(Capsule())
            Capsule()
                .fill(theme.surfaceContainerHigh)
                .frame(width: 90, height: 10)
                .overlay(shimmer)
                .clipShape(Capsule())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                phase = 1.5
            }
        }
        .accessibilityHidden(true)
    }

    private var shimmer: some View {
        GeometryReader { geo in
            LinearGradient(
                colors: [.clear, theme.surfaceContainerHighest.opacity(0.9), .clear],
                startPoint: .leading, endPoint: .trailing
            )
            .offset(x: geo.size.width * phase)
        }
        .allowsHitTesting(false)
    }
}
