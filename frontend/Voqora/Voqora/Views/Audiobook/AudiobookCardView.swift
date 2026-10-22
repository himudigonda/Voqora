import SwiftUI

struct AudiobookCardView: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var bookVM: AudiobookViewModel
    @EnvironmentObject var studio: StudioViewModel
    let book: Audiobook
    var onOpen: () -> Void = {}
    @State private var hovering = false
    @State private var showFailureDetail = false
    @State private var showDeleteConfirmation = false
    @State private var showCostApproval = false
    @Environment(\.voqoraTheme) private var theme

    static let coverAspectRatio = BookCover.aspectRatio

    var status: ProcessingStatus {
        bookVM.processingState[book.bookID] ?? book.displayStatus
    }

    private var progressFraction: Double {
        switch status {
        case let .extracting(p, t), let .cleaning(p, t), let .generating(p, t),
             let .sectioning(p, t):
            guard t > 0 else { return 0 }
            return Double(p) / Double(t)
        case .finishing:
            return 1
        default:
            return book.progressFraction
        }
    }

    var body: some View {
        Button(action: handleTap) {
            VStack(alignment: .leading, spacing: 10) {
                cover
                VStack(alignment: .leading, spacing: 6) {
                    Text(prettyTitle)
                        .font(vm.font(.titleSmall))
                        .foregroundStyle(theme.onSurface)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .help(prettyTitle)
                    meta
                    if let progress = listeningProgress {
                        PlayerProgressBar(fraction: progress, height: 4)
                    }
                    if let chip = statusChip {
                        chip
                    }
                }
                .padding(.horizontal, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .scaleEffect(hovering && status.isReady ? 1.02 : 1.0)
        .animation(Theme.Motion.selection, value: hovering)
        .onHover { hovering = $0 }
        .popover(isPresented: $showFailureDetail, arrowEdge: .bottom) { failureDetail }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityAddTraits(.isButton)
        .contextMenu {
            if let reason = status.failureReason {
                Button {} label: {
                    Label(reason, systemImage: "exclamationmark.triangle")
                }
                .disabled(true)
            }
            if let name = book.cleanedWithName {
                Button {} label: {
                    Label("Cleaned with \(name)", systemImage: "sparkles")
                }
                .disabled(true)
            }
            if status.failureReason != nil || book.cleanedWithName != nil {
                Divider()
            }
            if status.isProcessing {
                Button { bookVM.cancel(book) } label: {
                    Label("Cancel Processing", systemImage: "xmark.circle")
                }
                Divider()
            }
            if case .failed = status {
                if let provider = book.providerToFix {
                    Button { bookVM.fixProvider(for: book) } label: {
                        Label("Fix \(provider.displayName)…", systemImage: "key")
                    }
                }
                Button { bookVM.retry(book) } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                Divider()
            }
            if case .cancelled = status {
                Button { bookVM.retry(book) } label: {
                    Label("Restart", systemImage: "arrow.clockwise")
                }
                Divider()
            }
            if case .needsKey = status {
                Button { bookVM.resumeNeedsKey(book) } label: {
                    Label("Resume", systemImage: "play.fill")
                }
                Divider()
            }
            if case .needsCostApproval = status {
                Button { showCostApproval = true } label: {
                    Label("Review cost choice", systemImage: "dollarsign.circle")
                }
                Divider()
            }
            if status.isReady, !book.failedPages.isEmpty {
                Button { bookVM.retry(book) } label: {
                    Label("Retry \(book.failedPages.count) \(book.failedPages.count == 1 ? "Page" : "Pages")", systemImage: "arrow.clockwise")
                }
                Divider()
            }
            if status.isReady {
                Menu {
                    AudiobookExportMenuItems(exports: bookVM.exports, book: book)
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                Divider()
            }
            if book.isPodcast {
                Button {
                    studio.openRenderedPodcast(bookID: book.bookID)
                    vm.selectedTab = TabKey.createScripts
                } label: {
                    Label("Edit Script", systemImage: "pencil")
                }
                Divider()
            } else if status.isReady {
                Button {
                    studio.startNewPodcast(source: .book(book.bookID))
                    vm.selectedTab = TabKey.createPodcast
                } label: {
                    Label("Make a Podcast…", systemImage: "waveform.and.mic")
                }
                Divider()
            }
            Button(role: .destructive) { showDeleteConfirmation = true } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .confirmationDialog(
            "Delete \"\(prettyTitle)\"?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                bookVM.delete(book)
            }
        } message: {
            Text("This permanently deletes the audiobook and its narration. This can't be undone.")
        }
        .confirmationDialog(
            "Choose how to finish \(prettyTitle)",
            isPresented: $showCostApproval,
            titleVisibility: .visible
        ) {
            if let required = book.budget?.costApproval?.requiredCapUsd {
                Button("Approve Standard tier (cap $\(String(format: "%.2f", required)))") {
                    bookVM.resolveCostApproval(book, approveStandard: true)
                }
            }
            Button("Finish remaining work locally") {
                bookVM.resolveCostApproval(book, approveStandard: false)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Flex capacity was unavailable. Standard work is sent only if you approve the displayed absolute per-book cap. Finishing locally sends no more document content to Gemini.")
        }
    }

    private var prettyTitle: String {
        book.displayTitle
    }

    private func handleTap() {
        switch status {
        case .ready: onOpen()
        case .failed: showFailureDetail = true
        case .cancelled: bookVM.retry(book)
        case .needsKey: bookVM.resumeNeedsKey(book)
        case .needsCostApproval: showCostApproval = true
        default: break
        }
    }

    private var failureDetail: some View {
        VStack(alignment: .leading, spacing: Theme.Space.item) {
            Label("Processing failed", systemImage: "exclamationmark.triangle.fill")
                .font(vm.font(.titleSmall))
                .foregroundStyle(theme.danger)
            Text(status.failureReason ?? "Something went wrong while processing this audiobook.")
                .font(vm.font(.body))
                .foregroundStyle(theme.onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Theme.Space.item) {
                Spacer(minLength: 0)
                if let provider = book.providerToFix {
                    Button("Fix \(provider.displayName)…") {
                        showFailureDetail = false
                        bookVM.fixProvider(for: book)
                    }
                    .buttonStyle(.voqoraTonal)
                }
                Button {
                    showFailureDetail = false
                    bookVM.retry(book)
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.voqoraFilled)
            }
        }
        .padding(Theme.Space.card)
        .frame(width: 320)
    }

    private var cover: some View {
        BookCover(bookID: book.bookID)
            .aspectRatio(Self.coverAspectRatio, contentMode: .fit)
            .overlay(stateOverlay)
            .overlay(alignment: .topLeading) {
                if book.isPodcast {
                    podcastBadge
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if hovering, status.isReady {
                    Image(systemName: "play.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(theme.onPrimary)
                        .frame(width: 44, height: 44)
                        .background(theme.primary, in: Circle())
                        .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
                        .padding(12)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .shadow(color: .black.opacity(hovering ? 0.18 : 0.08), radius: hovering ? 14 : 6, y: hovering ? 8 : 3)
    }

    private var podcastBadge: some View {
        Label("Podcast", systemImage: "waveform.and.mic")
            .font(vm.font(.labelSmall))
            .foregroundStyle(theme.onSurface)
            .padding(.horizontal, 10)
            .frame(minHeight: 24)
            .background(theme.surfaceContainerHigh, in: Capsule())
            .padding(10)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Podcast")
    }

    @ViewBuilder
    private var stateOverlay: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Shape.md, style: .continuous)
        switch status {
        case .queued, .reconnecting:
            ZStack {
                shape.fill(.black.opacity(0.4))
                ProgressView().controlSize(.regular).tint(.white)
            }
        case .extracting, .cleaning, .generating, .sectioning, .finishing:
            ZStack {
                shape.fill(.black.opacity(0.4))
                progressRing.frame(width: 64, height: 64)
            }
        default:
            EmptyView()
        }
    }

    private var progressRing: some View {
        let pct = progressFraction
        return ZStack {
            Circle().fill(theme.surfaceContainerHigh)
            Circle().stroke(theme.outlineVariant, lineWidth: 4)
            Circle()
                .trim(from: 0, to: pct)
                .stroke(theme.primary, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(Theme.Motion.selection, value: pct)
            Text("\(Int(pct * 100))%")
                .font(vm.font(.label).monospacedDigit())
                .foregroundStyle(theme.onSurface)
        }
    }

    private var listeningProgress: Double? {
        guard status.isReady else { return nil }
        let fraction = bookVM.listenedFraction(for: book)
        return fraction > LibraryFilter.startedThreshold ? fraction : nil
    }

    private var statusChip: StatusChip? {
        switch status {
        case let .extracting(p, t), let .cleaning(p, t), let .generating(p, t), let .sectioning(p, t):
            StatusChip(text: t > 0 ? "Processing \(Int(Double(p) / Double(t) * 100))%" : "Processing", kind: .info, systemImage: "hourglass")
        case .finishing, .queued, .reconnecting:
            StatusChip(text: status.caption, kind: .info, systemImage: "hourglass")
        case .failed:
            StatusChip(text: "Failed", kind: .danger, systemImage: "exclamationmark.triangle.fill")
        case .needsKey:
            StatusChip(text: "Needs AI provider", kind: .warning, systemImage: "key.fill")
        case .needsCostApproval:
            StatusChip(text: "Needs approval", kind: .warning, systemImage: "dollarsign.circle.fill")
        case .cancelled, .notStarted:
            StatusChip(text: "Stopped", kind: .neutral, systemImage: "stop.circle.fill")
        case .ready:
            book.failedPages.isEmpty ? nil : StatusChip(text: incompleteLabel, kind: .warning, systemImage: "exclamationmark.triangle.fill")
        }
    }

    private var meta: some View {
        Text(metaText)
            .font(vm.font(.bodySmall))
            .foregroundStyle(theme.onSurfaceVariant)
            .monospacedDigit()
            .lineLimit(1)
            .help(failureHelp)
    }

    private var metaText: String {
        switch status {
        case .ready:
            readyCaption
        case .failed:
            status.detailedCaption
        case let .needsCostApproval(requiredCap):
            requiredCap.map { "Approve $\(String(format: "%.2f", $0)) or finish locally" } ?? status.caption
        default:
            statusCaption
        }
    }

    private var statusCaption: String {
        if book.isPodcast, case let .generating(turn, total) = status, total > 0 {
            return "Narrating turn \(min(turn + 1, total)) of \(total)"
        }
        return status.caption
    }

    private var failureHelp: String {
        guard case .failed = status else { return metaText }
        let action = book.providerToFix.map { "Click to fix \($0.displayName)." } ?? "Click to retry."
        return [status.failureReason, action].compactMap(\.self).joined(separator: " ")
    }

    private var readyCaption: String {
        let pages = book.isPodcast
            ? "\(book.pageCount) \(book.pageCount == 1 ? "turn" : "turns")"
            : "\(book.pageCount) \(book.pageCount == 1 ? "page" : "pages")"
        let listened = bookVM.listenedFraction(for: book)
        guard listened > LibraryFilter.startedThreshold else {
            return "\(DurationFormatter.listing(book.totalAudioSeconds)) · \(pages)"
        }
        let remaining = book.totalAudioSeconds * (1 - listened)
        guard remaining >= 1 else { return "Finished · \(pages)" }
        return "\(DurationFormatter.listing(remaining)) left · \(pages)"
    }

    private var incompleteLabel: String {
        let count = book.failedPages.count
        return "\(count) \(count == 1 ? "page needs" : "pages need") a retry"
    }

    private var accessibilitySummary: String {
        var parts = [prettyTitle]
        if let author = book.displayAuthor {
            parts.append("by \(author)")
        }
        parts.append(metaText)
        if let progress = listeningProgress {
            parts.append("\(Int(progress * 100)) percent listened")
        }
        return parts.joined(separator: ", ")
    }
}
