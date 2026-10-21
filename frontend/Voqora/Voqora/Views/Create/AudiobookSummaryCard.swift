import SwiftUI

struct AudiobookSummaryCard: View {
    @ObservedObject var form: AudiobookCreateForm
    let create: () -> Void

    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var bookVM: AudiobookViewModel
    @EnvironmentObject var providers: LLMProviderStore
    @Environment(\.voqoraTheme) private var theme

    private var estimate: AudiobookEstimateResponse? {
        bookVM.pendingEstimate
    }

    private var hasProvider: Bool {
        providers.activeCredential != nil
    }

    private var providerName: String {
        providers.activeProvider?.displayName ?? "The AI provider"
    }

    private var canCreate: Bool {
        guard let estimate, !bookVM.uploadInProgress, !form.isCreating else { return false }
        return !AudiobookCreateSummary.isStartDisabled(
            startingProcessing: bookVM.startingProcessing,
            isImageOnly: estimate.isImageOnly,
            useCleanup: form.useCleanup,
            hasProvider: hasProvider,
            providerReadsImages: estimate.readsImages
        )
    }

    var body: some View {
        SummaryCard {
            header
            if let estimate {
                stats(for: estimate)
                notices(for: estimate)
            } else {
                status
            }
            Button(action: create) {
                if form.isCreating || bookVM.startingProcessing {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Starting…")
                    }
                } else {
                    Text("Create Audiobook")
                }
            }
            .buttonStyle(.voqoraFilled)
            .frame(maxWidth: .infinity)
            .disabled(!canCreate)
            .accessibilityHint(canCreate ? "" : "Add a source first")
            if bookVM.pendingSource != nil {
                Button("Discard") { form.discardDraft(library: bookVM) }
                    .buttonStyle(.voqoraText)
                    .frame(maxWidth: .infinity)
                    .disabled(form.isCreating || bookVM.startingProcessing)
                    .help("Remove this source and start over")
            }
            if estimate == nil, bookVM.pendingSource == nil {
                Text("Add a source to see the length and processing time.")
                    .voqoraFont(.bodySmall)
                    .foregroundStyle(theme.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: Theme.Space.item + 4) {
            SourceCover(source: bookVM.pendingSource, size: CGSize(width: 64, height: 90))
            VStack(alignment: .leading, spacing: 4) {
                Text(headerTitle)
                    .voqoraFont(.titleSmall)
                    .foregroundStyle(theme.onSurface)
                    .lineLimit(3)
                    .help(headerTitle)
                if let byline = headerByline {
                    Text(byline)
                        .voqoraFont(.bodySmall)
                        .foregroundStyle(theme.onSurfaceVariant)
                        .lineLimit(1)
                }
            }
        }
    }

    private var headerTitle: String {
        if let estimate {
            return AudiobookImportStaging.displayName(from: estimate.title)
        }
        return bookVM.pendingSource?.displayName ?? "New audiobook"
    }

    private var headerByline: String? {
        if let author = estimate?.displayAuthor {
            return "by \(author)"
        }
        guard estimate != nil, let url = bookVM.pendingSource?.webPageURL else { return nil }
        return WebPageLink.siteName(of: url)
    }

    @ViewBuilder
    private var status: some View {
        if bookVM.uploadInProgress {
            HStack(spacing: Theme.Space.item) {
                ProgressView().controlSize(.small)
                Text("Reading your source…")
                    .voqoraFont(.body)
                    .foregroundStyle(theme.onSurfaceVariant)
            }
        } else if bookVM.pendingSource != nil {
            Label(
                bookVM.loadingError ?? "Could not read this source.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .voqoraFont(.bodySmall)
            .foregroundStyle(theme.danger)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func stats(for estimate: AudiobookEstimateResponse) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.item) {
            statRow("Length", AudiobookCreateSummary.approximate(estimate.estimatedAudioSeconds), systemImage: "waveform")
            statRow(
                "Processing",
                AudiobookCreateSummary.approximate(AudiobookCreateSummary.processingSeconds(for: estimate, voice: form.voice)),
                systemImage: "clock"
            )
            if let note = ProcessingTimeEstimate.note(forVoice: form.voice) {
                Text(note)
                    .voqoraFont(.bodySmall)
                    .foregroundStyle(theme.onSurfaceVariant)
            }
            if form.useCleanup {
                statRow("AI cleanup", AudiobookCreateSummary.cleanupCostLabel(for: estimate, useCleanup: true), systemImage: "dollarsign.circle")
                Text(providerNote(for: estimate))
                    .voqoraFont(.bodySmall)
                    .foregroundStyle(theme.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if bookVM.uploadInProgress {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Updating estimate…")
                        .voqoraFont(.bodySmall)
                        .foregroundStyle(theme.onSurfaceVariant)
                }
            }
        }
    }

    @ViewBuilder
    private func notices(for estimate: AudiobookEstimateResponse) -> some View {
        let items = AudiobookCreateSummary.notices(
            for: estimate,
            useCleanup: form.useCleanup,
            hasProvider: hasProvider,
            providerName: providerName,
            isWebPage: bookVM.pendingSource?.webPageURL != nil
        )
        ForEach(items, id: \.self) { item in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: item.icon)
                    .foregroundStyle(theme.warning)
                    .accessibilityHidden(true)
                Text(item.text)
                    .voqoraFont(.bodySmall)
                    .foregroundStyle(theme.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func providerNote(for estimate: AudiobookEstimateResponse) -> String {
        let tokens = AudiobookCreateSummary.formattedCount(estimate.estimatedTokenCount)
        return "\(providerName) · about \(tokens) tokens"
    }

    private func statRow(_ title: String, _ value: String, systemImage: String) -> some View {
        HStack(spacing: 8) {
            Label(title, systemImage: systemImage)
                .voqoraFont(.label)
                .foregroundStyle(theme.onSurfaceVariant)
            Spacer(minLength: 8)
            Text(value)
                .voqoraFont(.label)
                .monospacedDigit()
                .foregroundStyle(theme.onSurface)
                .contentTransition(.numericText())
        }
    }
}
