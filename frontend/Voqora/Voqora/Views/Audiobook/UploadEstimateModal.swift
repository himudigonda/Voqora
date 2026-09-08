import PDFKit
import SwiftUI

struct UploadEstimateModal: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var bookVM: AudiobookViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    let documentURL: URL

    /// An explicit, per-book choice. Text documents stay local unless this is
    /// turned on; image-only PDFs need it because local extraction has no text
    /// to narrate.
    @State private var useGeminiCleanup = false

    private var accentColor: Color {
        vm.accentColor(scheme: colorScheme, contrast: colorSchemeContrast)
    }

    var body: some View {
        VStack(spacing: 18) {
            header
            // S6: re-check stored key whenever the modal becomes visible —
            // covers the case where the user adds/removes a key in
            // Preferences while this modal is open.
            EmptyView().task { bookVM.refreshKeyState() }
            if let est = bookVM.pendingEstimate {
                // The estimate can be taller than a 640-point sheet once the
                // privacy choice and Gemini warnings are present. Keep the
                // primary action anchored and let only the details scroll,
                // rather than clipping the bottom controls.
                ScrollView {
                    VStack(spacing: 18) {
                        cover
                        statsGrid(for: est)
                        processingOptions(for: est)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 1)
                }
                .frame(maxHeight: .infinity)
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
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("NEW AUDIOBOOK")
                    .font(vm.font(.sectionHeader))
                    .kerning(0.6)
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
               let page = pdf.page(at: 0) {
                // S7: PDFPage.thumbnail renders the page properly at the
                // requested point size, unlike NSImage(data:) on a raw PDF
                // page-representation blob (which sometimes shows the whole
                // PDF or renders at low resolution).
                let nsImage = page.thumbnail(of: NSSize(width: 280, height: 392), for: .cropBox)
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
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
                StatTile(label: "PAGES", value: "\(est.pageCount)", icon: "doc.text", appFont: vm.appFont, accentColor: accentColor)
                StatTile(label: "WORDS", value: numberFormat(est.wordCountEstimate), icon: "textformat", appFont: vm.appFont, accentColor: accentColor)
            }
            HStack(spacing: 12) {
                StatTile(label: "PROCESSING", value: "~\(DurationFormatter.short(est.estimatedProcessingSeconds))", icon: "clock", appFont: vm.appFont, accentColor: accentColor)
                StatTile(label: "AUDIO", value: "~\(DurationFormatter.short(est.estimatedAudioSeconds))", icon: "waveform", appFont: vm.appFont, accentColor: accentColor)
            }
            HStack(spacing: 12) {
                StatTile(label: "GEMINI TOKENS", value: useGeminiCleanup ? numberFormat(est.estimatedTokenCount) : "OFF", icon: "number", appFont: vm.appFont, accentColor: accentColor)
                StatTile(label: "GEMINI COST", value: useGeminiCleanup ? formatCost(est.estimatedCostUsd) : "OFF", icon: "dollarsign.circle", appFont: vm.appFont, accentColor: accentColor)
            }
        }
    }

    private func processingOptions(for est: AudiobookEstimateResponse) -> some View {
        VStack(spacing: 10) {
            if useGeminiCleanup, est.costWarning {
                HStack(spacing: 8) {
                    Image(systemName: "dollarsign.circle.fill").foregroundStyle(Palette.warning)
                    Text("This book's estimated Gemini cost is \(formatCost(est.estimatedCostUsd)). Proceed anyway?")
                        .font(vm.appFont(size: 11))
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(2)
                }
                .padding(10)
                .background(Palette.warning.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            Toggle(isOn: $useGeminiCleanup) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Use Gemini cleanup for this book")
                        .font(vm.appFont(size: 11, weight: .medium))
                        .foregroundStyle(Palette.textPrimary)
                    Text("Optional for text documents. When enabled, page text and scanned-PDF images are sent transiently to Google Gemini for cleanup or OCR.")
                        .font(vm.appFont(size: 10))
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(3)
                }
            }
            .toggleStyle(.checkbox)
            .padding(10)
            .background(accentColor.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            if est.isImageOnly, !useGeminiCleanup {
                HStack(spacing: 8) {
                    Image(systemName: "doc.viewfinder").foregroundStyle(Palette.warning)
                    Text("This scanned PDF needs Gemini OCR. Turn on cleanup to continue.")
                        .font(vm.appFont(size: 11))
                        .foregroundStyle(Palette.textSecondary)
                }
                .padding(.bottom, 4)
            }
            if useGeminiCleanup && !bookVM.hasStoredKey {
                // Consistent with the cost/OCR warnings above (both warning-toned)
                // — this used to be .yellow for no evident semantic reason,
                // despite all three being the same "Start is blocked" class
                // of warning in this same modal.
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.warning)
                    Text("Set a Gemini API key in Preferences first.")
                        .font(vm.appFont(size: 11))
                        .foregroundStyle(Palette.textSecondary)
                }
                .padding(.bottom, 4)
            }
            if let duplicateTitle = bookVM.pendingEstimate?.duplicateOfTitle {
                HStack(spacing: 8) {
                    Image(systemName: "doc.on.doc.fill").foregroundStyle(Palette.warning)
                    Text("You already imported this exact file as \"\(duplicateTitle)\".")
                        .font(vm.appFont(size: 11))
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(2)
                }
                .padding(.bottom, 4)
            }
        }
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
                if useGeminiCleanup && !bookVM.keyVerified {
                    bookVM.showToast(
                        "Set a Gemini API key in Preferences first.",
                        kind: .error
                    )
                } else {
                    // Do NOT call dismiss() here — modal dismisses automatically
                    // when startProcessing() clears pendingDocument on success.
                    // Calling dismiss() immediately would race with the async
                    // /start call: the sheet binding setter fires cancelUpload()
                    // which deletes the staged book before /start completes.
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
                    Label("Start Processing", systemImage: "play.fill")
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

    /// T-19: pure Start-Processing disabled-condition, kept testable without
    /// a live view per the `AudiobookPlayerLayout`/`AudiobookPlayerView`
    /// precedent. A scanned (image-only) PDF needs Gemini OCR to have any
    /// text to narrate; Gemini cleanup toggled on with no saved key can
    /// never succeed either -- both proactively disable Start rather than
    /// letting the user tap it and hit a toast.
    static func isStartDisabled(
        startingProcessing: Bool,
        isImageOnly: Bool,
        useGeminiCleanup: Bool,
        hasStoredKey: Bool
    ) -> Bool {
        if startingProcessing { return true }
        if isImageOnly && !useGeminiCleanup { return true }
        if useGeminiCleanup && !hasStoredKey { return true }
        return false
    }

    private var loadingState: some View {
        VStack(spacing: 16) {
            ProgressView().tint(accentColor)
            Text("Reading your file...")
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
        if usd < 0.01 { return "< $0.01" }
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
                    .kerning(0.6)
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
