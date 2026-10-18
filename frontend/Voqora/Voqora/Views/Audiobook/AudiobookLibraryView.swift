import SwiftUI
import UniformTypeIdentifiers

enum AudiobookRoute: Hashable {
    case player(String)
}

enum LibrarySheet: Identifiable {
    case upload(AudiobookImportSource)
    case addFromURL
    case completion(Audiobook)
    case fixProvider(AudiobookViewModel.ProviderFix)

    var id: String {
        switch self {
        case let .upload(source): "upload-\(source.identifier)"
        case .addFromURL: "add-from-url"
        case let .fixProvider(fix): "fix-\(fix.id)"
        case let .completion(book): "completion-\(book.bookID)"
        }
    }
}

struct AudiobookLibraryView: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var bookVM: AudiobookViewModel

    @State private var hoveringDrop = false
    @State private var searchText = ""
    @AppStorage("librarySortMode") private var sort: SortMode = .recent
    @State private var showDeleteAllConfirmation = false

    enum SortMode: String, CaseIterable, Identifiable {
        case recent, alpha, duration
        var id: String {
            rawValue
        }

        var label: String {
            switch self {
            case .recent: "Date Added"
            case .alpha: "Title"
            case .duration: "Length"
            }
        }
    }

    private let columns = [GridItem(.adaptive(minimum: 200, maximum: 240), spacing: 28)]

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
            switch sheet {
            case let .upload(source):
                UploadEstimateModal(source: source)
                    .environmentObject(vm)
                    .environmentObject(bookVM)
                    .environmentObject(bookVM.providers)
            case .addFromURL:
                AddFromURLSheet(
                    initialAddress: bookVM.webPageDraft,
                    voice: bookVM.importVoice(fallback: vm.selectedVoice),
                    speed: bookVM.importSpeed(fallback: vm.speechSpeed)
                )
                .environmentObject(vm)
                .environmentObject(bookVM)
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
        .navigationTitle("Audiobooks")
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search Audiobooks")
        .toolbar { toolbarContent }
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
                AudiobookPlayerView(book: book)
            } else if bookVM.hasLoadedOnce {
                Color.clear.onAppear { bookVM.libraryPath = [] }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    bookVM.libraryPath = []
                } label: {
                    Label("Library", systemImage: "chevron.backward")
                }
                .keyboardShortcut("[", modifiers: .command)
                .help("Back to Library")
            }
        }
        .onExitCommand { bookVM.libraryPath = [] }
    }

    private var librarySheetBinding: Binding<LibrarySheet?> {
        Binding(
            get: {
                if let book = bookVM.completionSummary {
                    return .completion(book)
                }
                if let fix = bookVM.providerFix {
                    return .fixProvider(fix)
                }
                if let source = bookVM.pendingSource {
                    return .upload(source)
                }
                if bookVM.isWebPageImportPresented {
                    return .addFromURL
                }
                return nil
            },
            set: { newValue in
                guard newValue == nil else { return }
                if bookVM.completionSummary != nil {
                    bookVM.completionSummary = nil
                } else if bookVM.providerFix != nil {
                    bookVM.endProviderFix()
                } else if bookVM.pendingSource != nil {
                    bookVM.cancelUpload()
                } else if bookVM.isWebPageImportPresented {
                    bookVM.dismissWebPageImport()
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

    @ViewBuilder
    private var content: some View {
        if !bookVM.hasLoadedOnce {
            skeletonGrid
        } else if bookVM.loadFailed, bookVM.books.isEmpty {
            loadFailedState
        } else if bookVM.books.isEmpty {
            emptyState
        } else if Self.showsNoResultsState(searchText: searchText, matchCount: filteredSorted.count) {
            noResultsState
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 32) {
                    ForEach(filteredSorted, id: \.id) { book in
                        let isProcessing = (bookVM.processingState[book.bookID] ?? book.displayStatus).isProcessing
                        Button {
                            guard !isProcessing else { return }
                            openBook(book)
                        } label: {
                            AudiobookCardView(book: book)
                        }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())
                    }
                }
                .padding(36)
            }
        }
    }

    private var skeletonGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 32) {
                ForEach(0 ..< 6, id: \.self) { _ in SkeletonCard() }
            }
            .padding(36)
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
        switch sort {
        case .recent:
            result.sort { $0.createdAt > $1.createdAt }
        case .alpha:
            result.sort { $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending }
        case .duration:
            result.sort { $0.totalAudioSeconds > $1.totalAudioSeconds }
        }
        return result
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { bookVM.isImporterPresented = true } label: {
                Label("Add Book", systemImage: "plus")
            }
            .keyboardShortcut("o", modifiers: .command)
            .help("Add Book")

            Button { bookVM.presentWebPageImport() } label: {
                Label("Add from URL", systemImage: "link")
            }
            .keyboardShortcut("u", modifiers: [.command, .shift])
            .help("Add from URL")

            Menu {
                Picker("Sort By", selection: $sort) {
                    ForEach(SortMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.inline)
                Divider()
                Button("Delete All Audiobooks…", role: .destructive) { showDeleteAllConfirmation = true }
                    .disabled(bookVM.books.isEmpty || bookVM.deletingAllBooks)
            } label: {
                Label("View Options", systemImage: "ellipsis.circle")
            }
            .help("View Options")
        }
    }

    private func openBook(_ book: Audiobook) {
        switch book.displayStatus {
        case .ready: bookVM.openPlayer(for: book.bookID)
        case .failed where book.providerToFix != nil: bookVM.fixProvider(for: book)
        case .failed, .cancelled: bookVM.retry(book)
        case .needsKey: bookVM.resumeNeedsKey(book)
        default: break
        }
    }

    private var dropOverlay: some View {
        DocumentDropOverlay(subtitle: AudiobookImportStaging.supportedFormatsDescription, appFont: vm.appFont)
            .animation(.easeInOut(duration: 0.25), value: hoveringDrop)
    }

    private var emptyState: some View {
        LibraryPlaceholder(
            systemImage: "books.vertical",
            title: "No Audiobooks",
            message: "Turn a PDF, EPUB, Word, HTML, text, or Markdown file, or a web article, into an audiobook you can follow line by line. Drop a file here to begin."
        ) {
            HStack(spacing: 12) {
                Button { bookVM.isImporterPresented = true } label: {
                    Label("Add a Document…", systemImage: "plus")
                }
                .buttonStyle(.voqoraPrimary)
                Button { bookVM.presentWebPageImport() } label: {
                    Label("Add from URL…", systemImage: "link")
                }
                .buttonStyle(.voqoraSecondary)
            }
        }
    }

    private var loadFailedState: some View {
        LibraryPlaceholder(
            systemImage: "exclamationmark.triangle",
            title: "Couldn't Load Library",
            message: "The speech engine isn't responding."
        ) {
            Button { Task { await bookVM.refresh() } } label: {
                Label("Try Again", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.voqoraSecondary)
        }
    }

    private var noResultsState: some View {
        LibraryPlaceholder(
            systemImage: "magnifyingglass",
            title: "No Results",
            message: "No audiobooks match “\(searchText)”."
        ) {
            EmptyView()
        }
    }
}

private struct LibraryPlaceholder<Actions: View>: View {
    @EnvironmentObject var vm: DashboardViewModel
    let systemImage: String
    let title: String
    let message: String
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: systemImage)
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(Palette.textTertiary)
            VStack(spacing: 6) {
                Text(title)
                    .font(vm.font(.sectionTitle))
                    .foregroundStyle(Palette.textPrimary)
                Text(message)
                    .font(vm.font(.rowTitle))
                    .foregroundStyle(Palette.textSecondary)
                    .multilineTextAlignment(.center)
            }
            actions
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SkeletonCard: View {
    @State private var phase: CGFloat = -1

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                .fill(Palette.controlFill)
                .aspectRatio(AudiobookCardView.coverAspectRatio, contentMode: .fit)
                .overlay(shimmer)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous))
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Palette.controlFill)
                .frame(width: 130, height: 12)
                .overlay(shimmer)
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Palette.controlFill)
                .frame(width: 90, height: 9)
                .overlay(shimmer)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                phase = 1.5
            }
        }
    }

    private var shimmer: some View {
        GeometryReader { geo in
            LinearGradient(
                colors: [.clear, .white.opacity(0.18), .clear],
                startPoint: .leading, endPoint: .trailing
            )
            .offset(x: geo.size.width * phase)
        }
        .blendMode(.plusLighter)
        .allowsHitTesting(false)
    }
}
