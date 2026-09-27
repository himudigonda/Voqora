import SwiftUI

struct CompletionSummaryModal: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var bookVM: AudiobookViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    let book: Audiobook
    var onListenNow: ((Audiobook) -> Void)?
    @State private var bouncing = false

    private var accentColor: Color {
        vm.accentColor(scheme: colorScheme, contrast: colorSchemeContrast)
    }

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(accentColor)
                .symbolEffect(.bounce, value: bouncing)
                .padding(.top, 12)

            VStack(spacing: 4) {
                Text("Ready to Listen")
                    .font(vm.font(.sectionHeader))
                    .foregroundStyle(accentColor)
                Text(prettyTitle)
                    .font(vm.appFont(size: 20, weight: .bold))
                    .foregroundStyle(Palette.textPrimary)
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
                    Text("Later")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.voqoraSecondary)

                Button {
                    let callback = onListenNow
                    let snapshot = book
                    dismiss()
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(250))
                        callback?(snapshot)
                    }
                } label: {
                    Label("Listen Now", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.voqoraPrimary)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 520, height: 640)
        .voqoraSurface(.floating, in: Rectangle())
        .onAppear { bouncing.toggle() }
    }

    private var failedPagesWarning: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Palette.warning)
                .font(.system(size: 14))
            VStack(alignment: .leading, spacing: 2) {
                Text("\(book.failedPages.count) \(book.failedPages.count == 1 ? "page" : "pages") didn't process fully")
                    .font(vm.appFont(size: 12, weight: .bold))
                    .foregroundStyle(Palette.textPrimary)
                Text("Right-click the book in your library to retry.")
                    .font(vm.appFont(size: 11))
                    .foregroundStyle(Palette.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Palette.warning.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.medium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.medium, style: .continuous)
                .stroke(Palette.warning.opacity(0.3), lineWidth: 1)
        )
        .padding(.horizontal, 4)
    }

    private var statsGrid: some View {
        VStack(spacing: 10) {
            statRow("Pages", "\(book.pageCount)", "doc.text")
            statRow("Words", numberFormat(book.actual?.words ?? 0), "textformat")
            statRow("Length", DurationFormatter.short(book.totalAudioSeconds), "waveform")
            statRow("Processing", DurationFormatter.short(book.actual?.processingSeconds ?? 0), "clock")
            statRow("Sections", "\(book.sections.count)", "list.bullet.rectangle")
            if let cost = book.actual?.costUsd, cost > 0 {
                statRow("Cost", String(format: "$%.2f", cost), "dollarsign.circle")
            }
        }
        .padding(16)
        .voqoraSurface(.raised, in: RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.large, style: .continuous))
    }

    private func statRow(_ label: String, _ value: String, _ icon: String) -> some View {
        HStack {
            Image(systemName: icon).foregroundStyle(accentColor).font(.system(size: 11)).frame(width: 18)
            Text(label)
                .font(vm.font(.chip))
                .foregroundStyle(Palette.textSecondary)
            Spacer()
            Text(value)
                .font(vm.appFont(size: 14, weight: .bold).monospaced())
                .foregroundStyle(Palette.textPrimary)
                .contentTransition(.numericText())
        }
    }

    private var prettyTitle: String {
        book.displayTitle
    }

    private func numberFormat(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}
