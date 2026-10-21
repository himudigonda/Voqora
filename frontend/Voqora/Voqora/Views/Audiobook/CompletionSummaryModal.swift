import SwiftUI

struct CompletionSummaryModal: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var bookVM: AudiobookViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.voqoraTheme) private var theme

    let book: Audiobook
    var onListenNow: ((Audiobook) -> Void)?

    var body: some View {
        VoqoraSheet(title: "Ready to Listen", supporting: book.displayTitle) {
            VStack(alignment: .leading, spacing: Theme.Space.card) {
                if !book.failedPages.isEmpty {
                    failedPagesWarning
                }
                VoqoraCard {
                    VStack(spacing: Theme.Space.item) {
                        statRow("Pages", "\(book.pageCount)", "doc.text")
                        statRow("Words", numberFormat(book.actual?.words ?? 0), "textformat")
                        statRow("Length", DurationFormatter.short(book.totalAudioSeconds), "waveform")
                        statRow("Processing", DurationFormatter.short(book.actual?.processingSeconds ?? 0), "clock")
                        if book.sections.count > 1 {
                            statRow("Sections", "\(book.sections.count)", "list.bullet.rectangle")
                        }
                        if let cost = book.actual?.costUsd, cost > 0 {
                            statRow("Cost", cost < 0.01 ? "Under $0.01" : String(format: "$%.2f", cost), "dollarsign.circle")
                        }
                    }
                }
                actions
            }
        }
    }

    private var actions: some View {
        HStack(spacing: Theme.Space.item) {
            Spacer(minLength: 0)
            Button("Later") { dismiss() }
                .buttonStyle(.voqoraText)
                .keyboardShortcut(.cancelAction)
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
            }
            .buttonStyle(.voqoraFilled)
            .keyboardShortcut(.defaultAction)
        }
    }

    private var failedPagesWarning: some View {
        HStack(alignment: .top, spacing: Theme.Space.item) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(theme.warning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Space.unit) {
                Text("\(book.failedPages.count) \(book.failedPages.count == 1 ? "page" : "pages") didn't process fully")
                    .font(vm.font(.label))
                    .foregroundStyle(theme.onSurface)
                Button {
                    let snapshot = book
                    dismiss()
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(250))
                        bookVM.retry(snapshot)
                    }
                } label: {
                    Label(
                        "Retry \(book.failedPages.count) failed \(book.failedPages.count == 1 ? "page" : "pages")",
                        systemImage: "arrow.clockwise"
                    )
                }
                .buttonStyle(.voqoraTonal)
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Space.item + 4)
        .background(theme.warning.opacity(0.14), in: RoundedRectangle(cornerRadius: Theme.Shape.md, style: .continuous))
    }

    private func statRow(_ label: String, _ value: String, _ icon: String) -> some View {
        HStack(spacing: Theme.Space.item) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(theme.onPrimaryContainer)
                .frame(width: 28, height: 28)
                .background(theme.primaryContainer.opacity(0.65), in: Circle())
                .accessibilityHidden(true)
            Text(label)
                .font(vm.font(.body))
                .foregroundStyle(theme.onSurfaceVariant)
            Spacer(minLength: 0)
            Text(value)
                .font(vm.font(.label))
                .monospacedDigit()
                .foregroundStyle(theme.onSurface)
                .contentTransition(.numericText())
        }
        .accessibilityElement(children: .combine)
    }

    private func numberFormat(_ n: Int) -> String {
        n.formatted(.number)
    }
}
