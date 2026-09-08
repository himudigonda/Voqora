import SwiftUI
import UniformTypeIdentifiers

/// Routes pushed by the library: only the player today, but easy to extend.
enum AudiobookRoute: Hashable {
    case player(String)  // book_id
}

/// Single source-of-truth for which (mutually exclusive) sheet the library is
/// presenting. Replaces three stacked `.sheet(item:)` modifiers — macOS only
/// fires one of those, which was hiding the upload + completion modals.
enum LibrarySheet: Identifiable {
    case upload(URL)
    case completion(Audiobook)

    var id: String {
        switch self {
        case .upload(let url): return "upload-\(url.absoluteString)"
        case .completion(let book): return "completion-\(book.bookID)"
        }
    }
}

struct AudiobookLibraryView: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var bookVM: AudiobookViewModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    @State private var hoveringDrop = false
    @State private var showImporter = false
    @State private var searchText = ""
    @State private var sort: SortMode = .recent
    @State private var path: [AudiobookRoute] = []

    /// The app's accent, resolved once per body pass — matches
    /// `VoqoraWindow.accentColor`'s pattern rather than a hardcoded `.cyan`.
    private var accentColor: Color {
        vm.accentColor(scheme: colorScheme, contrast: colorSchemeContrast)
    }

    enum SortMode: String, CaseIterable, Identifiable {
        case recent, alpha, duration
        var id: String { rawValue }
        var label: String {
            switch self {
            case .recent: return "Recent"
            case .alpha: return "A→Z"
            case .duration: return "Duration"
            }
        }
        var icon: String {
            switch self {
            case .recent: return "clock"
            case .alpha: return "textformat"
            case .duration: return "timer"
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
                if hoveringDrop { dropOverlay.transition(.opacity) }
            }
            .navigationTitle("Audiobooks")
            // T-14: search field was fully wired (`filteredSorted`, `searchText`)
            // but never rendered anywhere. Matches VaultView.swift's convention.
            .searchable(text: $searchText, placement: .sidebar, prompt: "Search audiobooks...")
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
                case .upload(let url):
                    UploadEstimateModal(documentURL: url)
                        .environmentObject(vm)
                        .environmentObject(bookVM)
                case .completion(let book):
                    CompletionSummaryModal(book: book, onListenNow: { openPlayer($0) })
                        .environmentObject(vm)
                        .environmentObject(bookVM)
                }
            }
            .navigationDestination(for: AudiobookRoute.self) { route in
                switch route {
                case .player(let bookID):
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
            .onChange(of: bookVM.pendingDeepLink) { _, newValue in
                guard let bookID = newValue else { return }
                if let book = bookVM.books.first(where: { $0.bookID == bookID }) {
                    if !path.contains(.player(bookID)) {
                        path.append(.player(book.bookID))
                    }
                }
                bookVM.pendingDeepLink = nil
            }
        }
    }

    /// Single binding the .sheet modifier uses. Reads from VM publishers,
    /// writes back to clear them on dismiss (handles C4 — orphan cleanup).
    private var librarySheetBinding: Binding<LibrarySheet?> {
        Binding(
            get: {
                if let book = bookVM.completionSummary { return .completion(book) }
                if let url = bookVM.pendingDocument { return .upload(url) }
                return nil
            },
            set: { newValue in
                if newValue != nil { return }
                if bookVM.completionSummary != nil { bookVM.completionSummary = nil }
                else if bookVM.pendingDocument != nil { bookVM.cancelUpload() }
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
        } else if bookVM.loadFailed && bookVM.books.isEmpty {
            // T-17: a first-load failure (e.g. backend unreachable) must read
            // as distinctly different from a genuinely empty library.
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
                        // T-15: gate only the tap-to-open action, not hit-testing for the
                        // whole subtree. `.allowsHitTesting(!isProcessing)` here used to
                        // disable AudiobookCardView's own `.contextMenu` too, making its
                        // only "Cancel Processing" affordance unreachable by right-click
                        // exactly when a card was processing.
                        Button {
                            guard !isProcessing else { return }
                            openBook(book)
                        } label: {
                            AudiobookCardView(book: book)
                                .environmentObject(vm)
                                .environmentObject(bookVM)
                        }
                        .buttonStyle(.plain)
                        // P7: without contentShape, macOS hit-testing fires only over
                        // visible pixels. This extends hover/click to the full card rect.
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
                ForEach(0..<6, id: \.self) { _ in SkeletonCard() }
            }
            .padding(36)
        }
    }

    /// T-14: pure trigger condition for the "no results" empty state, kept
    /// testable without a live view per the `AudiobookPlayerLayout`/
    /// `AudiobookPlayerView.shouldAutoScroll` precedent. A non-empty search
    /// that matches nothing is distinct from a genuinely empty library.
    static func showsNoResultsState(searchText: String, matchCount: Int) -> Bool {
        !searchText.isEmpty && matchCount == 0
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
            // T-20: an empty title left this control unlabeled for
            // VoiceOver. `.menu` style still shows only the selected value's
            // icon, so the title change is accessibility-only.
            Picker("Sort audiobooks", selection: $sort) {
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

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            var url: URL?
            if let data = item as? Data {
                url = URL(dataRepresentation: data, relativeTo: nil)
            } else if let u = item as? URL {
                url = u
            }
            guard let url else {
                Task { @MainActor in
                    bookVM.showToast("Voqora could not read that dropped file.", kind: .error)
                }
                return
            }
            guard AudiobookImportStaging.supports(url) else {
                Task { @MainActor in
                    bookVM.showToast("Voqora audiobooks support \(AudiobookImportStaging.supportedFormatsDescription) files.", kind: .info)
                }
                return
            }
            Task { @MainActor in stageAndPresentDocument(url) }
        }
        return true
    }

    /// A Finder-selected file can be security-scoped. Copy it before the
    /// selection callback ends, preserving the filename inside a unique
    /// temporary folder so two documents with the same name never overwrite each
    /// other while they wait in the upload queue.
    private func stageAndPresentDocument(_ sourceURL: URL) {
        do {
            let stagedURL = try AudiobookImportStaging.stageDocument(from: sourceURL)
            presentEstimate(for: stagedURL)
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
        DocumentDropOverlay(
            subtitle: "PDF, TXT, DOCX, or Markdown — up to 400 pages",
            appFont: vm.appFont
        )
        .animation(.easeInOut(duration: 0.25), value: hoveringDrop)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 22) {
            Image(systemName: "books.vertical")
                .font(.system(size: 96, weight: .ultraLight))
                .foregroundStyle(Palette.textTertiary.opacity(0.4))
            VStack(spacing: 6) {
                // Heavy black-weight kerned all-caps was the old techy
                // aesthetic; a semibold sectionTitle with a light kern reads
                // much closer to GRiT's tone for a headline this size.
                Text("YOUR SHELF IS EMPTY")
                    .font(vm.font(.sectionTitle))
                    .kerning(0.6)
                    .foregroundStyle(Palette.textSecondary)
                Text("Drop a PDF, TXT, DOCX, or Markdown file anywhere on this window to begin.")
                    .font(vm.font(.rowTitle))
                    .foregroundStyle(Palette.textSecondary)
            }
            Button { showImporter = true } label: {
                Label("Choose a File", systemImage: "plus")
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(accentColor)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Load-failure state (T-17)

    private var loadFailedState: some View {
        VStack(spacing: 22) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 96, weight: .ultraLight))
                .foregroundStyle(Palette.danger.opacity(0.6))
            VStack(spacing: 6) {
                Text("COULDN'T LOAD YOUR LIBRARY")
                    .font(vm.font(.sectionTitle))
                    .kerning(0.6)
                    .foregroundStyle(Palette.textSecondary)
                Text("Voqora couldn't reach the backend. Check that it's running and try again.")
                    .font(vm.font(.rowTitle))
                    .foregroundStyle(Palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
            Button { Task { await bookVM.refresh() } } label: {
                Label("Try Again", systemImage: "arrow.clockwise")
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(Palette.danger)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - No-results state (T-14)

    private var noResultsState: some View {
        VStack(spacing: 22) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 96, weight: .ultraLight))
                .foregroundStyle(Palette.textTertiary.opacity(0.4))
            VStack(spacing: 6) {
                Text("NO MATCHES")
                    .font(vm.font(.sectionTitle))
                    .kerning(0.6)
                    .foregroundStyle(Palette.textSecondary)
                Text("No audiobooks match “\(searchText)”. Try a different search.")
                    .font(vm.font(.rowTitle))
                    .foregroundStyle(Palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// Allow URL? to drive .sheet(item:)
extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

private struct SkeletonCard: View {
    @State private var phase: CGFloat = -1

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // T-16: track the grid's adaptive column instead of a hard 180pt,
            // matching AudiobookCardView's cover fix. An opaque neutral fill
            // (rather than `.ultraThinMaterial`) so the shimmer placeholder
            // reads as a stable flat shape, not a smeared blur of whatever
            // scrolls beneath it.
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
