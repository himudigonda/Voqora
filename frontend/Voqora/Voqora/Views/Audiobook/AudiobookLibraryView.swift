import SwiftUI
import UniformTypeIdentifiers

/// Routes pushed by the library: only the player today, but easy to extend.
enum AudiobookRoute: Hashable {
    case player(String) // book_id
}

/// Single source-of-truth for which (mutually exclusive) sheet the library is
/// presenting. Replaces three stacked `.sheet(item:)` modifiers — macOS only
/// fires one of those, which was hiding the upload + completion modals.
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
    @State private var sort: SortMode = .recent
    @State private var path: [AudiobookRoute] = []

    enum SortMode: String, CaseIterable, Identifiable {
        case recent, alpha, duration
        var id: String {
            rawValue
        }

        var label: String {
            switch self {
            case .recent: "Recent"
            case .alpha: "A→Z"
            case .duration: "Duration"
            }
        }

        var icon: String {
            switch self {
            case .recent: "clock"
            case .alpha: "textformat"
            case .duration: "timer"
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
        if let markdown = UTType(filenameExtension: "md") { types.append(markdown) }
        return types
    }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                content
                if hoveringDrop {
                    dropOverlay.transition(.opacity)
                }
            }
            .navigationTitle("Audiobooks")
            .toolbar { toolbarContent }
            .onDrop(of: [.fileURL], isTargeted: $hoveringDrop, perform: handleDrop)
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: supportedDocumentTypes
            ) { result in
                switch result {
                case .success(let url):
                    stageAndPresentDocument(url)
                case .failure(let error):
                    bookVM.showToast("Could not open that document: \(error.localizedDescription)", kind: .error)
                }
            }
            // ONE sheet, driven by a computed binding that prefers the
            // completion modal over an in-flight upload modal. Dismissal
            // (X, Cmd+W, click-outside) routes through the appropriate
            // VM cleanup so we never orphan a staged book on disk.
            .sheet(item: librarySheetBinding) { sheet in
                switch sheet {
                case let .upload(url):
                    UploadEstimateModal(pdfURL: url)
                        .environmentObject(vm)
                        .environmentObject(bookVM)
                case let .completion(book):
                    CompletionSummaryModal(book: book, onListenNow: { openPlayer($0) })
                        .environmentObject(vm)
                        .environmentObject(bookVM)
                }
            }
            .navigationDestination(for: AudiobookRoute.self) { route in
                switch route {
                case let .player(bookID):
                    if let book = bookVM.books.first(where: { $0.bookID == bookID }) {
                        AudiobookPlayerView(book: book)
                            .environmentObject(vm)
                            .environmentObject(bookVM)
                            .navigationBarBackButtonHidden(false)
                    } else {
                        // Book vanished underneath us (deletion race). Pop back.
                        Color.clear.onAppear { path.removeLast() }
                    }
                }
            }
            .task {
                await bookVM.refresh()
                bookVM.startPolling()
            }
            .onDisappear { bookVM.stopPolling() }
            // E13: resolving must retry on the next `books` update too, not
            // just when `pendingDeepLink` itself changes — otherwise a deep
            // link that arrives before its target book is loaded is lost
            // forever instead of resolving once the book appears.
            .onChange(of: bookVM.pendingDeepLink) { _, _ in resolveDeepLinkIfPossible() }
            .onChange(of: bookVM.books) { _, _ in resolveDeepLinkIfPossible() }
        }
    }

    /// See `AudiobookDeepLinkResolver`'s doc comment (the v1.1 design notes Sprint 7,
    /// T7.12/E13) for why the resolve-or-stay-armed decision lives there as
    /// pure logic rather than inline here.
    private func resolveDeepLinkIfPossible() {
        let result = AudiobookDeepLinkResolver.resolve(
            pendingDeepLink: bookVM.pendingDeepLink,
            books: bookVM.books,
            currentPath: path
        )
        if let route = result.route {
            path.append(route)
        }
        if result.clear {
            bookVM.pendingDeepLink = nil
        }
    }

    /// Single binding the .sheet modifier uses. Reads from VM publishers,
    /// writes back to clear them on dismiss (handles C4 — orphan cleanup).
    private var librarySheetBinding: Binding<LibrarySheet?> {
        Binding(
            get: {
                if let book = bookVM.completionSummary {
                    return .completion(book)
                }
                if let url = bookVM.pendingPDF {
                    return .upload(url)
                }
                return nil
            },
            set: { newValue in
                if newValue != nil {
                    return
                }
                if bookVM.completionSummary != nil {
                    bookVM.completionSummary = nil
                } else if bookVM.pendingPDF != nil {
                    bookVM.cancelUpload()
                }
            }
        )
    }

    private func openPlayer(_ book: Audiobook) {
        path.append(.player(book.bookID))
    }

    @ViewBuilder
    private var content: some View {
        if !bookVM.hasLoadedOnce {
            skeletonGrid
        } else if bookVM.books.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 32) {
                    ForEach(filteredSorted, id: \.id) { book in
                        let isProcessing = (bookVM.processingState[book.bookID] ?? book.displayStatus).isProcessing
                        Button { openBook(book) } label: {
                            AudiobookCardView(book: book)
                                .environmentObject(vm)
                                .environmentObject(bookVM)
                        }
                        .buttonStyle(.plain)
                        // P7: without contentShape, macOS hit-testing fires only over
                        // visible pixels. This extends hover/click to the full card rect.
                        .contentShape(Rectangle())
                        // E5: .allowsHitTesting(false) blocked the entire subtree,
                        // including the card's own .contextMenu "Cancel Processing"
                        // item — .disabled scopes the block to just this Button's
                        // own tap action, leaving the context menu reachable.
                        .disabled(isProcessing)
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

    private var filteredSorted: [Audiobook] {
        var result = bookVM.books
        if !searchText.isEmpty {
            result = result.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
        }
        switch sort {
        case .recent:
            result.sort { $0.createdAt > $1.createdAt }
        case .alpha:
            result.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .duration:
            result.sort { $0.totalAudioSeconds > $1.totalAudioSeconds }
        }
        return result
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Picker("", selection: $sort) {
                ForEach(SortMode.allCases) { mode in
                    Label(mode.label, systemImage: mode.icon).tag(mode)
                }
            }
            .pickerStyle(.menu)

            Button { showImporter = true } label: {
                Label("Add Book", systemImage: "plus.circle.fill")
            }
        }
    }

    private func openBook(_ book: Audiobook) {
        switch book.displayStatus {
        case .ready: openPlayer(book)
        case .failed: bookVM.retry(book)
        case .cancelled: bookVM.retry(book)
        case .needsKey: bookVM.resumeNeedsKey(book)
        default:
            // Processing — clicking through is a no-op for now (future: progress drawer).
            break
        }
    }

    /// E10: delegates to `AudiobookDropHandler`, which iterates every
    /// provider (not just `.first`) — see its doc comment for why the
    /// iteration logic itself lives there instead of inline here.
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        AudiobookDropHandler.handle(providers: providers) { url in
            Task { @MainActor in presentEstimate(for: url) }
        } onError: { url, error in
            Task { @MainActor in
                bookVM.showToast("Couldn't read '\(url.lastPathComponent)': \(error.localizedDescription)", kind: .error)
            }
        }
    }

    /// Finder grants can be security-scoped and duplicate filenames are common.
    /// Stage each accepted document before handing it to the asynchronous book
    /// pipeline, then let that pipeline own the narrow cleanup path.
    private func stageAndPresentDocument(_ sourceURL: URL) {
        do {
            presentEstimate(for: try AudiobookImportStaging.stageDocument(from: sourceURL))
        } catch {
            bookVM.showToast("Could not prepare that document: \(error.localizedDescription)", kind: .error)
        }
    }

    private func presentEstimate(for pdf: URL) {
        // Prefer the audiobook-specific defaults from Preferences; fall back to
        // the user's live clipboard-TTS voice if they haven't set one.
        let voice = bookVM.defaultBookVoice.isEmpty ? vm.selectedVoice : bookVM.defaultBookVoice
        let speed = bookVM.defaultBookSpeed > 0 ? bookVM.defaultBookSpeed : vm.speechSpeed
        bookVM.presentEstimate(
            for: pdf,
            voice: voice,
            speed: speed,
            engine: "kokoro"
        )
    }

    // MARK: - Drop overlay

    private var dropOverlay: some View {
        ZStack {
            Color.primary.opacity(0.18).ignoresSafeArea()
                .background(.ultraThinMaterial)
            VStack(spacing: 24) {
                Image(systemName: "arrow.down.doc.fill")
                    .font(.system(size: 72, weight: .ultraLight))
                    .foregroundStyle(.cyan)
                Text("DROP TO ADD AUDIOBOOK")
                    .font(vm.appFont(size: 14, weight: .black))
                    .kerning(3)
                    .foregroundStyle(.cyan)
                Text("PDF, TXT, DOCX, or MD — up to 400 pages")
                    .font(vm.appFont(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(48)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(.cyan.opacity(0.6), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            )
            .padding(60)
        }
        .animation(.easeInOut(duration: 0.25), value: hoveringDrop)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 22) {
            Image(systemName: "books.vertical")
                .font(.system(size: 96, weight: .ultraLight))
                .foregroundStyle(.secondary.opacity(0.4))
            VStack(spacing: 6) {
                Text("YOUR SHELF IS EMPTY")
                    .font(vm.appFont(size: 12, weight: .black))
                    .kerning(2)
                    .foregroundStyle(.secondary)
                Text("Drop a PDF, TXT, DOCX, or Markdown file anywhere on this window to begin.")
                    .font(vm.appFont(size: 14))
                    .foregroundStyle(.secondary)
            }
            Button { showImporter = true } label: {
                Label("Choose a File", systemImage: "plus")
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(.cyan)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Allow URL? to drive .sheet(item:)
extension URL: @retroactive Identifiable {
    public var id: String {
        absoluteString
    }
}

private struct SkeletonCard: View {
    @State private var phase: CGFloat = -1

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
                // Same grid-matching fix as AudiobookCardView (the v1.1 design notes
                // Sprint 6, T6.3) — fixed aspect ratio, flexible width, so
                // the skeleton doesn't flash a different width than the
                // real cards that replace it once loaded.
                .aspectRatio(180.0 / 252.0, contentMode: .fit)
                .overlay(shimmer)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(.ultraThinMaterial)
                .frame(width: 130, height: 12)
                .overlay(shimmer)
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(.ultraThinMaterial)
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
