import PDFKit
import SwiftUI

struct AudiobookCardView: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var bookVM: AudiobookViewModel
    let book: Audiobook
    @State private var hovering = false
    @State private var showDeleteConfirmation = false
    @State private var showCostApproval = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    /// The app's accent, resolved once per body pass — matches
    /// `VoqoraWindow.accentColor`'s pattern rather than a hardcoded `.cyan`.
    private var accentColor: Color {
        vm.accentColor(scheme: colorScheme, contrast: colorSchemeContrast)
    }

    /// The full five-shade ramp, needed for the cover placeholder's gradient
    /// (opaque `subtle`/`muted` shades rather than a translucent cyan wash).
    private var accentRamp: AccentRamp {
        Palette.accentRamp(
            for: vm.accentColorID,
            appearance: colorScheme,
            increaseContrast: colorSchemeContrast == .increased
        )
    }

    /// T-16: cover width/height ratio (was a hardcoded 180x252 that didn't
    /// track the grid's adaptive column). Applied via `.aspectRatio` so the
    /// cover fills whatever width `AudiobookLibraryView`'s
    /// `GridItem(.adaptive(...))` offers instead of a fixed pixel width.
    static let coverAspectRatio: CGFloat = 180.0 / 252.0

    var status: ProcessingStatus {
        bookVM.processingState[book.bookID] ?? book.displayStatus
    }

    /// Live progress fraction derived from SSE state, falling back to book model.
    private var progressFraction: Double {
        switch status {
        case let .extracting(p, t), let .cleaning(p, t), let .generating(p, t),
             let .sectioning(p, t):
            guard t > 0 else { return 0 }
            return Double(p) / Double(t)
        default:
            return book.progressFraction
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            cover
            if status.isProcessing {
                processingWaveform
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(prettyTitle)
                    .font(vm.appFont(size: 13, weight: .bold))
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                caption
            }
            .padding(.horizontal, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .scaleEffect(hovering && status.isReady ? 1.03 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hovering)
        .onHover { hovering = $0 }
        .contextMenu {
            if status.isProcessing {
                Button { bookVM.cancel(book) } label: {
                    Label("Cancel Processing", systemImage: "xmark.circle")
                }
                Divider()
            }
            if case .failed = status {
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

    private var cover: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                .fill(Palette.surfaceRaised)
                .aspectRatio(Self.coverAspectRatio, contentMode: .fit)
                .overlay {
                    AuthenticatedBackendImage(path: "audiobook/\(book.bookID)/cover") { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        placeholderCover
                    }
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous))
                }
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous)
                        .stroke(Palette.separator, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.25), radius: hovering ? 18 : 12, y: hovering ? 10 : 6)
                .overlay(stateOverlay)

            if hovering, status.isReady {
                Circle()
                    .fill(accentColor)
                    .frame(width: 44, height: 44)
                    .overlay(
                        Image(systemName: "play.fill")
                            .font(.system(size: 16, weight: .black))
                            .foregroundStyle(vm.onAccentColor(scheme: colorScheme, contrast: colorSchemeContrast))
                    )
                    .shadow(color: accentColor.opacity(0.5), radius: 12)
                    .padding(14)
                    .transition(.scale.combined(with: .opacity))
            }
        }
    }

    private var placeholderCover: some View {
        ZStack {
            // Opaque ramp shades rather than a translucent cyan wash — a
            // `subtle`/`muted` fill reads the same regardless of what's
            // behind it, and the ink below is `textPrimary` (rather than a
            // hardcoded `.white`) precisely because `subtle`/`muted` flip
            // from light-on-light to dark-on-dark between appearances, the
            // same way `textPrimary` itself does.
            LinearGradient(
                colors: [Color(accentRamp.muted), Color(accentRamp.subtle)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            VStack(spacing: 6) {
                Image(systemName: "book.fill")
                    .font(.system(size: 36, weight: .ultraLight))
                    .foregroundStyle(Palette.textPrimary.opacity(0.7))
                Text(prettyTitle)
                    .font(vm.appFont(size: 11, weight: .bold))
                    .foregroundStyle(Palette.textPrimary.opacity(0.85))
                    .lineLimit(3)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
            }
        }
    }

    @ViewBuilder
    private var stateOverlay: some View {
        switch status {
        case .queued:
            ZStack {
                RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous).fill(.black.opacity(0.4))
                ProgressView().tint(accentColor).scaleEffect(0.8)
            }
        case .extracting, .cleaning, .generating, .sectioning:
            ZStack {
                RoundedRectangle(cornerRadius: DesignTokens.Radius.md, style: .continuous).fill(.black.opacity(0.35))
                progressRing
                    .frame(width: 56, height: 56)
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        case .needsKey:
            cornerBadge(systemName: "key.fill", color: Palette.warning)
        case .needsCostApproval:
            cornerBadge(systemName: "dollarsign.circle.fill", color: Palette.warning)
        case .failed:
            cornerBadge(systemName: "exclamationmark.triangle.fill", color: Palette.danger)
        case .cancelled:
            cornerBadge(systemName: "stop.circle.fill", color: Palette.textSecondary)
        case .ready:
            EmptyView()
        }
    }

    @ViewBuilder
    private var progressRing: some View {
        let pct = progressFraction
        ZStack {
            Circle()
                .fill(Palette.surfaceRaised)
            Circle()
                .stroke(Palette.separator, lineWidth: 3)
            Circle()
                .trim(from: 0, to: pct)
                .stroke(accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.4), value: pct)
            Text("\(Int(pct * 100))%")
                .font(vm.appFont(size: 11, weight: .black).monospaced())
                .foregroundStyle(accentColor)
        }
    }

    private func cornerBadge(systemName: String, color: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 18, weight: .black))
            .foregroundStyle(color)
            .padding(8)
            .voqoraSurface(.floating, in: Circle())
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }

    // P8: Use TimelineView instead of a per-card Timer.publish so all processing
    // cards share the system animation compositor — zero extra timers regardless
    // of how many cards are visible simultaneously.
    private var processingWaveform: some View {
        TimelineView(.animation) { ctx in
            let phase = ctx.date.timeIntervalSinceReferenceDate * 2.9
            HStack(spacing: 3) {
                ForEach(0 ..< 16, id: \.self) { i in
                    let height = 4 + 14 * abs(sin(phase + Double(i) * 0.4))
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(accentColor.opacity(0.85))
                        .frame(width: 3, height: height)
                }
            }
            .frame(height: 18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 2)
        }
    }

    @ViewBuilder
    private var caption: some View {
        switch status {
        case .ready:
            HStack(spacing: 4) {
                if !book.failedPages.isEmpty {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(Palette.warning)
                }
                Text("\(DurationFormatter.short(book.totalAudioSeconds))  •  \(book.pageCount) PAGES")
                    .font(vm.font(.chip).monospaced())
                    .kerning(0.6)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
            }
            .help(book.failedPages.isEmpty ? "" : "\(book.failedPages.count) page\(book.failedPages.count == 1 ? "" : "s") had trouble during cleaning or narration")
        case .failed:
            Text(status.caption)
                .font(vm.font(.chip))
                .kerning(0.6)
                .foregroundStyle(Palette.danger)
                .lineLimit(1)
        case .cancelled:
            Text(status.caption)
                .font(vm.font(.chip))
                .kerning(0.6)
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
        case .needsKey:
            Text(status.caption)
                .font(vm.font(.chip))
                .kerning(0.6)
                .foregroundStyle(Palette.warning)
                .lineLimit(1)
        case let .needsCostApproval(requiredCap):
            Button {
                showCostApproval = true
            } label: {
                Text(requiredCap.map { "APPROVE $\(String(format: "%.2f", $0)) OR FINISH LOCALLY" } ?? status.caption)
                    .font(vm.font(.chip))
                    .kerning(0.6)
                    .foregroundStyle(Palette.warning)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
        default:
            Text(status.caption)
                .font(vm.font(.chip).monospaced())
                .kerning(0.6)
                .foregroundStyle(accentColor)
                .contentTransition(.numericText())
                .lineLimit(1)
        }
    }
}
