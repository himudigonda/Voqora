import SwiftUI

struct CompletionSummaryModal: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var bookVM: AudiobookViewModel
    @Environment(\.dismiss) private var dismiss

    let book: Audiobook
    var onListenNow: ((Audiobook) -> Void)? = nil
    @State private var bouncing = false

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.cyan)
                .symbolEffect(.bounce, value: bouncing)
                .padding(.top, 12)

            VStack(spacing: 4) {
                Text("YOUR AUDIOBOOK IS READY")
                    .font(vm.appFont(size: 11, weight: .black))
                    .kerning(2)
                    .foregroundStyle(.cyan)
                Text(prettyTitle)
                    .font(vm.appFont(size: 20, weight: .bold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, 16)
            }

            if !book.failedPages.isEmpty {
                failedPagesWarning
            }

            statsGrid

            Spacer(minLength: 0)

            HStack(spacing: 12) {
                Button { dismiss() } label: {
                    Text("Listen Later")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.bordered)

                Button {
                    let callback = onListenNow
                    let snapshot = book
                    dismiss()
                    // Defer the navigation push until after the sheet finishes
                    // dismissing — pushing during dismissal can leave the
                    // NavigationStack in a half-dismissed state on macOS.
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(250))
                        callback?(snapshot)
                    }
                } label: {
                    Label("Listen Now", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .font(vm.appFont(size: 13, weight: .bold))
                }
                .buttonStyle(.borderedProminent)
                .tint(.cyan)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        // T-16: match UploadEstimateModal's frame so the two modals in the
        // same upload -> completion flow don't visibly change size.
        .frame(width: 520, height: 640)
        .background(.ultraThinMaterial)
        .onAppear { bouncing.toggle() }
    }

    /// The backend already tracks exactly which pages failed to clean or
    /// narrate (book.failedPages), but nothing surfaced it here — a book
    /// with degraded pages completed with the same unqualified celebration
    /// as a fully clean one, and the only way to discover a problem was to
    /// open the transcript and scroll to the specific page.
    private var failedPagesWarning: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 14))
            VStack(alignment: .leading, spacing: 2) {
                Text("\(book.failedPages.count) page\(book.failedPages.count == 1 ? "" : "s") had trouble")
                    .font(vm.appFont(size: 12, weight: .bold))
                Text("Cleaning or narration failed for some pages — check the transcript to see which ones.")
                    .font(vm.appFont(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
        )
        .padding(.horizontal, 4)
    }

    private var statsGrid: some View {
        VStack(spacing: 10) {
            statRow("PAGES", "\(book.pageCount)", "doc.text")
            statRow("WORDS", numberFormat(book.actual?.words ?? 0), "textformat")
            statRow("AUDIO", DurationFormatter.short(book.totalAudioSeconds), "waveform")
            statRow("PROCESSING", DurationFormatter.short(book.actual?.processingSeconds ?? 0), "clock")
            statRow("SECTIONS", "\(book.sections.count)", "list.bullet.rectangle")
            if let cost = book.actual?.costUsd, cost > 0 {
                statRow("COST", String(format: "$%.2f", cost), "dollarsign.circle")
            }
        }
        .padding(16)
        .background(.ultraThinMaterial.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.large, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.large, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        )
    }

    private func statRow(_ label: String, _ value: String, _ icon: String) -> some View {
        HStack {
            Image(systemName: icon).foregroundStyle(.cyan).font(.system(size: 11)).frame(width: 18)
            Text(label)
                .font(vm.appFont(size: 9, weight: .black))
                .kerning(1.5)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(vm.appFont(size: 14, weight: .bold).monospaced())
                .contentTransition(.numericText())
        }
    }

    private var prettyTitle: String { book.displayTitle }

    private func numberFormat(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}
