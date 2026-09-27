import SwiftUI
import UniformTypeIdentifiers

enum AudiobookRoute: Hashable {
    case player(String)
}

enum LibrarySheet: Identifiable {
    case upload(URL)
    case completion(Audiobook)

    var id: String {
        switch self {
        case let .upload(url): "upload-\(url.absoluteString)"
        case let .completion(book): "completion-\(book.bookID)"
        }
    }
}

struct AudiobookLibraryView: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var bookVM: AudiobookViewModel

    @State private var hoveringDrop = false
    @State private var showImporter = false
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

    private var supportedDocumentTypes: [UTType] {
        var types: [UTType] = [
            .pdf,
            .plainText,
            .init(importedAs: "org.openxmlformats.wordprocessingml.document"),
        ]
        if let markdown = UTType(filenameExtension: "md") {
            types.append(markdown)
        }
        return types
    }

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
        .fileImporter(isPresented: $showImporter, allowedContentTypes: supportedDocumentTypes) { result in
            switch result {
            case let .success(url):
                stageAndPresentDocument(url)
            case let .failure(error):
                bookVM.showToast("Could not open that document: \(error.localizedDescription)", kind: .error)
            }
        }
        .sheet(item: librarySheetBinding) { sheet in
            switch sheet {
            case let .upload(url):
                UploadEstimateModal(documentURL: url)
                    .environmentObject(vm)
                    .environmentObject(bookVM)
            case let .completion(book):
                CompletionSummaryModal(book: book, onListenNow: { bookVM.openPlayer(for: $0.bookID) })
                    .environmentObject(vm)
                    .environmentObject(bookVM)
            }
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
        .onDrop(of: [.fileURL], isTargeted: $hoveringDrop, perform: handleDrop)
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
                if let url = bookVM.pendingDocument {
                    return .upload(url)
                }
                return nil
            },
            set: { newValue in
                guard newValue == nil else { return }
                if bookVM.completionSummary != nil {
                    bookVM.completionSummary = nil
                } else if bookVM.pendingDocument != nil {
                    bookVM.cancelUpload()
                }
            }
        )
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

    private var filteredSorted: [Audiobook] {
        var result = bookVM.books
        if !searchText.isEmpty {
            result = result.filter { $0.displayTitle.localizedCaseInsensitiveContains(searchText) }
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
            Button { showImporter = true } label: {
                Label("Add Book", systemImage: "plus")
            }
            .keyboardShortcut("o", modifiers: .command)
            .help("Add Book")

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
        case .failed, .cancelled: bookVM.retry(book)
        case .needsKey: bookVM.resumeNeedsKey(book)
        default: break
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let url = (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) } ?? (item as? URL)
            Task { @MainActor in
                guard let url else {
                    bookVM.showToast("Voqora could not read that dropped file.", kind: .error)
                    return
                }
                guard AudiobookImportStaging.supports(url) else {
                    bookVM.showToast("Voqora audiobooks support \(AudiobookImportStaging.supportedFormatsDescription) files.", kind: .info)
                    return
                }
                stageAndPresentDocument(url)
            }
        }
        return true
    }

    private func stageAndPresentDocument(_ sourceURL: URL) {
        do {
            let stagedURL = try AudiobookImportStaging.stageDocument(from: sourceURL)
            bookVM.presentEstimate(for: stagedURL, defaultVoice: vm.selectedVoice, defaultSpeed: vm.speechSpeed)
        } catch {
            bookVM.showToast("Could not prepare that document: \(error.localizedDescription)", kind: .error)
        }
    }

    private var dropOverlay: some View {
        DocumentDropOverlay(subtitle: "PDF, Word, text, or Markdown", appFont: vm.appFont)
            .animation(.easeInOut(duration: 0.25), value: hoveringDrop)
    }

    private var emptyState: some View {
        LibraryPlaceholder(
            systemImage: "books.vertical",
            title: "No Audiobooks",
            message: "Add a PDF, Word, text, or Markdown file, or drop one here."
        ) {
            Button { showImporter = true } label: {
                Label("Add File…", systemImage: "plus")
            }
            .buttonStyle(.voqoraPrimary)
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
