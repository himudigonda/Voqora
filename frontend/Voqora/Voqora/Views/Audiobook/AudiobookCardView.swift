import PDFKit
import SwiftUI

struct AudiobookCardView: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var bookVM: AudiobookViewModel
    let book: Audiobook
    @State private var hovering = false

    private let baseURL = URL(string: "http://127.0.0.1:10101")!

    var status: ProcessingStatus {
        bookVM.processingState[book.bookID] ?? book.displayStatus
    }

    /// Live progress fraction derived from SSE state, falling back to book model.
    private var progressFraction: Double {
        switch status {
        case .extracting(let p, let t), .cleaning(let p, let t), .generating(let p, let t):
            guard t > 0 else { return 0 }
            return Double(p) / Double(t)
        default:
            return book.progressFraction
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            cover
            if status.isProcessing { processingWaveform }
            VStack(alignment: .leading, spacing: 4) {
                Text(prettyTitle)
                    .font(vm.appFont(size: 13, weight: .bold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                caption
            }
            .padding(.horizontal, 2)
        }
        .frame(width: 180)
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
            Button(role: .destructive) { bookVM.delete(book) } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private var prettyTitle: String {
        var t = book.title
        for ext in [".pdf", ".docx", ".txt", ".md"] {
            if t.lowercased().hasSuffix(ext) { return String(t.dropLast(ext.count)) }
        }
        return t
    }

    @ViewBuilder
    private var cover: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
                .frame(width: 180, height: 252)
                .overlay {
                    AsyncImage(url: baseURL.appendingPathComponent("audiobook/\(book.bookID)/cover")) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().aspectRatio(contentMode: .fill)
                        case .failure, .empty:
                            placeholderCover
                        @unknown default:
                            placeholderCover
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.25), radius: hovering ? 18 : 12, y: hovering ? 10 : 6)
                .overlay(stateOverlay)

            if hovering && status.isReady {
                Circle()
                    .fill(.cyan)
                    .frame(width: 44, height: 44)
                    .overlay(Image(systemName: "play.fill").font(.system(size: 16, weight: .black)).foregroundStyle(.white))
                    .shadow(color: .cyan.opacity(0.5), radius: 12)
                    .padding(14)
                    .transition(.scale.combined(with: .opacity))
            }
        }
    }

    @ViewBuilder
    private var placeholderCover: some View {
        ZStack {
            LinearGradient(
                colors: [.cyan.opacity(0.6), .cyan.opacity(0.1)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            VStack(spacing: 6) {
                Image(systemName: "book.fill")
                    .font(.system(size: 36, weight: .ultraLight))
                    .foregroundStyle(.white.opacity(0.7))
                Text(prettyTitle)
                    .font(vm.appFont(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.85))
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
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.black.opacity(0.4))
                ProgressView().tint(.cyan).scaleEffect(0.8)
            }
        case .extracting, .cleaning, .generating:
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.black.opacity(0.35))
                progressRing
                    .frame(width: 56, height: 56)
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        case .needsKey:
            cornerBadge(systemName: "key.fill", color: .yellow)
        case .failed:
            cornerBadge(systemName: "exclamationmark.triangle.fill", color: .red)
        case .cancelled:
            cornerBadge(systemName: "stop.circle.fill", color: .secondary)
        case .ready:
            EmptyView()
        }
    }

    @ViewBuilder
    private var progressRing: some View {
        let pct = progressFraction
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
            Circle()
                .stroke(Color.primary.opacity(0.08), lineWidth: 3)
            Circle()
                .trim(from: 0, to: pct)
                .stroke(Color.cyan, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.4), value: pct)
            Text("\(Int(pct * 100))%")
                .font(vm.appFont(size: 11, weight: .black).monospaced())
                .foregroundStyle(.cyan)
        }
    }

    private func cornerBadge(systemName: String, color: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 18, weight: .black))
            .foregroundStyle(color)
            .padding(8)
            .background(.ultraThinMaterial, in: Circle())
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
                ForEach(0..<16, id: \.self) { i in
                    let height = 4 + 14 * abs(sin(phase + Double(i) * 0.4))
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(Color.cyan.opacity(0.85))
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
            Text("\(DurationFormatter.short(book.totalAudioSeconds))  •  \(book.pageCount) PAGES")
                .font(vm.appFont(size: 9, weight: .black).monospaced())
                .kerning(0.8)
                .foregroundStyle(.secondary)
        case .failed:
            Text(status.caption)
                .font(vm.appFont(size: 9, weight: .black))
                .kerning(1)
                .foregroundStyle(.red)
        case .cancelled:
            Text(status.caption)
                .font(vm.appFont(size: 9, weight: .black))
                .kerning(1)
                .foregroundStyle(.secondary)
        case .needsKey:
            Text(status.caption)
                .font(vm.appFont(size: 9, weight: .black))
                .kerning(1)
                .foregroundStyle(.yellow)
        default:
            Text(status.caption)
                .font(vm.appFont(size: 9, weight: .black).monospaced())
                .kerning(1)
                .foregroundStyle(.cyan)
                .contentTransition(.numericText())
        }
    }
}
