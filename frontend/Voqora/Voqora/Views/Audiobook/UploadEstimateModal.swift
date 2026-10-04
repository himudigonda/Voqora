import PDFKit
import SwiftUI

struct UploadEstimateModal: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var bookVM: AudiobookViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    let documentURL: URL

    @State private var useGeminiCleanup = false

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
                geminiOption
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
        .onAppear { bookVM.refreshKeyState() }
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
            if let pdf = PDFDocument(url: documentURL),
               let page = pdf.page(at: 0)
            {
                let nsImage = page.thumbnail(of: NSSize(width: 280, height: 392), for: .cropBox)
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 140, height: 196)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else {
                Image(systemName: "doc.fill")
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
                    label: "Gemini Tokens",
                    value: useGeminiCleanup ? numberFormat(est.estimatedTokenCount) : "OFF",
                    icon: "number",
                    appFont: vm.appFont,
                    accentColor: accentColor
                )
                StatTile(
                    label: "Gemini Cost",
                    value: useGeminiCleanup ? formatCost(est.estimatedCostUsd) : "OFF",
                    icon: "dollarsign.circle",
                    appFont: vm.appFont,
                    accentColor: accentColor
                )
            }
        }
    }

    private func notices(for est: AudiobookEstimateResponse) -> some View {
        VStack(spacing: 10) {
            if useGeminiCleanup, est.costWarning {
                notice(
                    "dollarsign.circle.fill",
                    "Gemini's conservative cost envelope is \(formatCost(est.maximumCostUsd ?? est.estimatedCostUsd)). " +
                        "The shown estimate may be lower; Voqora will not silently switch to a more expensive tier."
                )
            }
            if est.isImageOnly, !useGeminiCleanup {
                notice("doc.viewfinder", "This scanned PDF needs Gemini to read its text.")
            }
            if let duplicateTitle = est.duplicateOfTitle {
                notice("doc.on.doc.fill", "You already imported this exact file as \"\(duplicateTitle)\".")
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

    private var geminiOption: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .foregroundStyle(accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Clean Up with Gemini")
                    .font(vm.appFont(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                Text(bookVM.hasStoredKey
                    ? "Sends page text and scanned pages to Google Gemini."
                    : "Add a Gemini API key in Preferences to use this.")
                    .font(vm.appFont(size: 11))
                    .foregroundStyle(Palette.textSecondary)
            }
            Spacer(minLength: 8)
            if bookVM.hasStoredKey {
                Toggle("Clean Up with Gemini", isOn: $useGeminiCleanup)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .tint(accentColor)
            } else {
                Button("Add Key…") {
                    cancel()
                    vm.selectedTab = "preferences"
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .background(accentColor.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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
                if useGeminiCleanup, !bookVM.keyVerified {
                    bookVM.showToast(
                        "Set a Gemini API key in Preferences first.",
                        kind: .error
                    )
                } else {
                    bookVM.startProcessing(useGeminiCleanup: useGeminiCleanup)
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
                useGeminiCleanup: useGeminiCleanup,
                hasStoredKey: bookVM.hasStoredKey
            ))
            .keyboardShortcut(.defaultAction)
        }
    }

    private var actionsCancelOnly: some View {
        Button { cancel() } label: {
            Text("Close").frame(maxWidth: .infinity).padding(.vertical, 8)
        }
        .buttonStyle(.voqoraSecondary)
    }

    static func isStartDisabled(
        startingProcessing: Bool,
        isImageOnly: Bool,
        useGeminiCleanup: Bool,
        hasStoredKey: Bool
    ) -> Bool {
        if startingProcessing {
            return true
        }
        if isImageOnly, !useGeminiCleanup {
            return true
        }
        if useGeminiCleanup, !hasStoredKey {
            return true
        }
        return false
    }

    private var loadingState: some View {
        VStack(spacing: 16) {
            ProgressView().tint(accentColor)
            Text("Reading File…")
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
            Text(bookVM.loadingError ?? "Could not read this file.")
                .font(vm.appFont(size: 13))
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
        }
        .frame(maxHeight: .infinity)
    }

    private var prettyTitle: String {
        AudiobookImportStaging.strippingSupportedExtension(from: documentURL.lastPathComponent)
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
