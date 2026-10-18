import PDFKit
import SwiftUI

struct UploadEstimateModal: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var bookVM: AudiobookViewModel
    @EnvironmentObject var providers: LLMProviderStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    let source: AudiobookImportSource

    @State private var useCleanup = false
    @State private var addingProvider = false

    private var accentColor: Color {
        vm.accentColor(scheme: colorScheme, contrast: colorSchemeContrast)
    }

    var body: some View {
        VStack(spacing: 18) {
            header
            if let est = bookVM.pendingEstimate {
                ScrollView {
                    VStack(spacing: 18) {
                        cover
                        statsGrid(for: est)
                        notices(for: est)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 1)
                }
                .frame(maxHeight: .infinity)
                cleanupOption
                actions
            } else if bookVM.uploadInProgress {
                loadingState
                Spacer(minLength: 0)
            } else {
                errorState
                Spacer(minLength: 0)
                actionsCancelOnly
            }
        }
        .padding(28)
        .frame(width: 520, height: 640)
        .voqoraSurface(.floating, in: Rectangle())
        .sheet(isPresented: $addingProvider, onDismiss: refreshEstimateIfStale) {
            AddProviderSheet(cleaningCount: bookVM.cleaningBookCount(using:))
                .environmentObject(vm)
                .environmentObject(providers)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("New Audiobook")
                    .font(vm.font(.sectionHeader))
                    .foregroundStyle(accentColor)
                Text(prettyTitle)
                    .font(vm.appFont(size: 18, weight: .bold))
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                if let byline {
                    Text(byline)
                        .font(vm.appFont(size: 12))
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Button { cancel() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Palette.textSecondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Close")
        }
    }

    private var cover: some View {
        ZStack {
            Color.clear
                .frame(width: 140, height: 196)
                .voqoraSurface(.floating, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            if let documentURL = source.documentURL,
               documentURL.pathExtension.lowercased() == "pdf",
               let pdf = PDFDocument(url: documentURL),
               let page = pdf.page(at: 0)
            {
                let nsImage = page.thumbnail(of: NSSize(width: 280, height: 392), for: .cropBox)
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 140, height: 196)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else {
                Image(systemName: placeholderSymbol)
                    .font(.system(size: 40))
                    .foregroundStyle(accentColor.opacity(0.5))
            }
        }
        .padding(.top, 4)
    }

    private func statsGrid(for est: AudiobookEstimateResponse) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                StatTile(label: "Pages", value: "\(est.pageCount)", icon: "doc.text", appFont: vm.appFont, accentColor: accentColor)
                StatTile(label: "Words", value: numberFormat(est.wordCountEstimate), icon: "textformat", appFont: vm.appFont, accentColor: accentColor)
            }
            HStack(spacing: 12) {
                StatTile(label: "Processing", value: "~\(DurationFormatter.short(est.estimatedProcessingSeconds))", icon: "clock", appFont: vm.appFont, accentColor: accentColor)
                StatTile(label: "Length", value: "~\(DurationFormatter.short(est.estimatedAudioSeconds))", icon: "waveform", appFont: vm.appFont, accentColor: accentColor)
            }
            HStack(spacing: 12) {
                StatTile(
                    label: "Cleanup Tokens",
                    value: useCleanup ? numberFormat(est.estimatedTokenCount) : "OFF",
                    icon: "number",
                    appFont: vm.appFont,
                    accentColor: accentColor
                )
                StatTile(
                    label: "Cleanup Cost",
                    value: cleanupCostLabel(for: est),
                    icon: "dollarsign.circle",
                    appFont: vm.appFont,
                    accentColor: accentColor
                )
            }
        }
    }

    private func notices(for est: AudiobookEstimateResponse) -> some View {
        VStack(spacing: 10) {
            if useCleanup, est.costWarning {
                notice(
                    "dollarsign.circle.fill",
                    "\(providerName)'s conservative cost envelope is \(formatCost(est.maximumCostUsd ?? est.estimatedCostUsd)). " +
                        "The shown estimate may be lower; Voqora will not silently switch to a more expensive tier."
                )
            }
            if useCleanup, est.pricingKnown == false {
                notice(
                    "dollarsign.circle.fill",
                    "Voqora has no published rate for \(est.llmModel ?? "this model"), so it budgets the book at a conservative rate."
                )
            }
            if est.isImageOnly, hasProvider, est.readsImages == false {
                notice(
                    "doc.viewfinder",
                    "\(est.llmModel ?? providerName) can't read scanned pages. Choose another provider above."
                )
            }
            if est.isImageOnly, hasProvider, est.readsImages == nil {
                notice(
                    "doc.viewfinder",
                    "Voqora can't tell whether \(est.llmModel ?? providerName) reads scanned pages."
                )
            }
            if est.isImageOnly, !useCleanup, est.readsImages != false {
                notice("doc.viewfinder", "This scanned PDF needs AI cleanup to read its text.")
            }
            if let duplicateTitle = est.duplicateOfTitle {
                let kind = source.webPageURL == nil ? "file" : "page"
                notice("doc.on.doc.fill", "You already imported this exact \(kind) as \"\(duplicateTitle)\".")
            }
        }
    }

    private func notice(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(Palette.warning)
            Text(text)
                .font(vm.appFont(size: 11))
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Palette.warning.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var providerName: String {
        providers.activeProvider?.displayName ?? "The AI provider"
    }

    private var hasProvider: Bool {
        providers.activeCredential != nil
    }

    private func cleanupCostLabel(for est: AudiobookEstimateResponse) -> String {
        guard useCleanup else { return "OFF" }
        if est.maximumCostUsd == 0 {
            return "FREE"
        }
        return formatCost(est.estimatedCostUsd)
    }

    private var cleanupOption: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                if let provider = providers.activeProvider {
                    ProviderTile(provider: provider, size: 28)
                } else {
                    Image(systemName: "sparkles")
                        .foregroundStyle(accentColor)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(hasProvider ? "Clean Up with \(providerName)" : "AI Cleanup")
                        .font(vm.appFont(size: 12, weight: .semibold))
                        .foregroundStyle(Palette.textPrimary)
                    Text(cleanupSubtitle)
                        .font(vm.appFont(size: 11))
                        .foregroundStyle(Palette.textSecondary)
                }
                Spacer(minLength: 8)
                if hasProvider {
                    Toggle("Clean Up with \(providerName)", isOn: $useCleanup)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .tint(accentColor)
                }
            }
            providerRow
        }
        .padding(12)
        .background(accentColor.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var cleanupSubtitle: String {
        if let provider = providers.activeProvider {
            return provider.dataNotice
        }
        return providers.connectedProviders.isEmpty
            ? "Add an AI provider to use this."
            : "Choose which provider audiobooks use."
    }

    private var providerRow: some View {
        HStack(spacing: 8) {
            Text("Provider")
                .font(vm.appFont(size: 11))
                .foregroundStyle(Palette.textSecondary)
            Spacer(minLength: 8)
            if providers.connectedProviders.isEmpty {
                Button("Add Provider…") { addingProvider = true }
                    .buttonStyle(.bordered)
            } else {
                Menu {
                    ForEach(providers.connectedProviders) { provider in
                        Button {
                            choose(provider)
                        } label: {
                            if provider == providers.activeProvider {
                                Label(provider.displayName, systemImage: "checkmark")
                            } else {
                                Text(provider.displayName)
                            }
                        }
                    }
                    Divider()
                    Button("Add Provider…") { addingProvider = true }
                } label: {
                    Text(providerMenuTitle)
                }
                .fixedSize()
                .disabled(bookVM.startingProcessing)
                .accessibilityLabel("AI provider")
            }
        }
    }

    private var providerMenuTitle: String {
        guard let credential = providers.activeCredential else {
            return providers.activeProvider?.displayName ?? "Choose a Provider"
        }
        let model = credential.resolvedModel
        return model.isEmpty ? credential.provider.displayName : "\(credential.provider.displayName) · \(model)"
    }

    private func choose(_ provider: LLMProvider) {
        providers.use(provider)
        refreshEstimateIfStale()
    }

    private func refreshEstimateIfStale() {
        guard let estimate = bookVM.pendingEstimate,
              AudiobookViewModel.isEstimateStale(estimate, credential: providers.activeCredential)
        else { return }
        bookVM.refreshEstimate()
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button { cancel() } label: {
                Text("Cancel")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.voqoraSecondary)

            Button {
                if useCleanup, !hasProvider {
                    bookVM.showToast(AudiobookViewModel.missingProviderMessage, kind: .error)
                } else {
                    bookVM.startProcessing(useCleanup: useCleanup)
                }
            } label: {
                if bookVM.startingProcessing {
                    HStack(spacing: 8) {
                        ProgressView().tint(vm.onAccentColor(scheme: colorScheme, contrast: colorSchemeContrast)).scaleEffect(0.75)
                        Text("Starting…")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .font(vm.appFont(size: 13, weight: .bold))
                } else {
                    Label("Create Audiobook", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .font(vm.appFont(size: 13, weight: .bold))
                }
            }
            .buttonStyle(.voqoraPrimary)
            .disabled(Self.isStartDisabled(
                startingProcessing: bookVM.startingProcessing,
                isImageOnly: bookVM.pendingEstimate?.isImageOnly ?? false,
                useCleanup: useCleanup,
                hasProvider: hasProvider,
                providerReadsImages: bookVM.pendingEstimate?.readsImages
            ))
            .keyboardShortcut(.defaultAction)
        }
    }

    private var actionsCancelOnly: some View {
        HStack(spacing: 12) {
            Button { cancel() } label: {
                Text("Close").frame(maxWidth: .infinity).padding(.vertical, 8)
            }
            .buttonStyle(.voqoraSecondary)
            if source.webPageURL != nil {
                Button { bookVM.editWebPageLink() } label: {
                    Label("Edit Link", systemImage: "link")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.voqoraPrimary)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    static func isStartDisabled(
        startingProcessing: Bool,
        isImageOnly: Bool,
        useCleanup: Bool,
        hasProvider: Bool,
        providerReadsImages: Bool? = nil
    ) -> Bool {
        if startingProcessing {
            return true
        }
        if isImageOnly, !useCleanup {
            return true
        }
        if isImageOnly, useCleanup, providerReadsImages == false {
            return true
        }
        if useCleanup, !hasProvider {
            return true
        }
        return false
    }

    private var loadingState: some View {
        VStack(spacing: 16) {
            ProgressView().tint(accentColor)
            Text(source.webPageURL == nil ? "Reading File…" : "Fetching Page…")
                .font(vm.appFont(size: 13))
                .foregroundStyle(Palette.textSecondary)
        }
        .frame(maxHeight: .infinity)
    }

    private var errorState: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 32))
                .foregroundStyle(Palette.danger)
            Text(bookVM.loadingError ?? (source.webPageURL == nil ? "Could not read this file." : WebPageImportMessage.generic))
                .font(vm.appFont(size: 13))
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
        }
        .frame(maxHeight: .infinity)
    }

    private var prettyTitle: String {
        guard let title = bookVM.pendingEstimate?.title, !title.isEmpty else { return source.displayName }
        return AudiobookImportStaging.displayName(from: title)
    }

    private var byline: String? {
        if let author = bookVM.pendingEstimate?.displayAuthor {
            return "by \(author)"
        }
        guard bookVM.pendingEstimate != nil, let url = source.webPageURL else { return nil }
        return WebPageLink.siteName(of: url)
    }

    private var placeholderSymbol: String {
        if source.webPageURL != nil {
            return "globe"
        }
        return source.documentURL?.pathExtension.lowercased() == "epub" ? "book.closed.fill" : "doc.fill"
    }

    private func numberFormat(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    private func formatCost(_ usd: Double) -> String {
        if usd < 0.01 {
            return "< $0.01"
        }
        return String(format: "$%.2f", usd)
    }

    private func cancel() {
        bookVM.cancelUpload()
        dismiss()
    }
}

private struct StatTile: View {
    let label: String
    let value: String
    let icon: String
    let appFont: (CGFloat, Font.Weight) -> Font
    var accentColor: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(accentColor).font(.system(size: 11))
                Text(label)
                    .font(appFont(9, .medium))
                    .foregroundStyle(Palette.textSecondary)
            }
            Text(value)
                .font(appFont(18, .bold).monospaced())
                .foregroundStyle(Palette.textPrimary)
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .voqoraSurface(.raised, in: RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.medium, style: .continuous))
    }
}
