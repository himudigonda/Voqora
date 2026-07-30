import PDFKit
import SwiftUI

struct UploadEstimateModal: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var bookVM: AudiobookViewModel
    @Environment(\.dismiss) private var dismiss

    let documentURL: URL

    /// An explicit, per-book choice. Text documents stay local unless this is
    /// turned on; image-only PDFs need it because local extraction has no text
    /// to narrate.
    @State private var useGeminiCleanup = false

    var body: some View {
        VStack(spacing: 24) {
            header
            // S6: re-check stored key whenever the modal becomes visible —
            // covers the case where the user adds/removes a key in
            // Preferences while this modal is open.
            EmptyView().task { bookVM.refreshKeyState() }
            if let est = bookVM.pendingEstimate {
                cover
                statsGrid(for: est)
                Spacer(minLength: 0)
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
        .background(.ultraThinMaterial)
        .background(adaptiveSheetBackground)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("NEW AUDIOBOOK")
                    .font(vm.appFont(size: 9, weight: .black))
                    .kerning(2)
                    .foregroundStyle(.cyan)
                Text(prettyTitle)
                    .font(vm.appFont(size: 18, weight: .bold))
                    .lineLimit(1)
            }
            Spacer()
            Button { cancel() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
    }

    private var cover: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
                .frame(width: 140, height: 196)
                .shadow(color: .black.opacity(0.3), radius: 14, y: 8)
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
                    .foregroundStyle(.cyan.opacity(0.5))
            }
        }
        .padding(.top, 4)
    }

    private func statsGrid(for est: AudiobookEstimateResponse) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                StatTile(label: "PAGES", value: "\(est.pageCount)", icon: "doc.text", appFont: vm.appFont)
                StatTile(label: "WORDS", value: numberFormat(est.wordCountEstimate), icon: "textformat", appFont: vm.appFont)
            }
            HStack(spacing: 12) {
                StatTile(label: "PROCESSING", value: "~\(DurationFormatter.short(est.estimatedProcessingSeconds))", icon: "clock", appFont: vm.appFont)
                StatTile(label: "AUDIO", value: "~\(DurationFormatter.short(est.estimatedAudioSeconds))", icon: "waveform", appFont: vm.appFont)
            }
            HStack(spacing: 12) {
                StatTile(label: "GEMINI TOKENS", value: useGeminiCleanup ? numberFormat(est.estimatedTokenCount) : "OFF", icon: "number", appFont: vm.appFont)
                StatTile(label: "GEMINI COST", value: useGeminiCleanup ? formatCost(est.estimatedCostUsd) : "OFF", icon: "dollarsign.circle", appFont: vm.appFont)
            }
        }
    }

    private var actions: some View {
        VStack(spacing: 10) {
            if let est = bookVM.pendingEstimate, useGeminiCleanup, est.costWarning {
                HStack(spacing: 8) {
                    Image(systemName: "dollarsign.circle.fill").foregroundStyle(.orange)
                    Text("This book's estimated Gemini cost is \(formatCost(est.estimatedCostUsd)). Proceed anyway?")
                        .font(vm.appFont(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .padding(10)
                .background(Color.orange.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            Toggle(isOn: $useGeminiCleanup) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Use Gemini cleanup for this book")
                        .font(vm.appFont(size: 11, weight: .medium))
                    Text("Optional for text PDFs. When enabled, page text and scanned-page images are sent transiently to Google Gemini for cleanup or OCR.")
                        .font(vm.appFont(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
            .toggleStyle(.checkbox)
            .padding(10)
            .background(Color.cyan.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            if let est = bookVM.pendingEstimate, est.isImageOnly, !useGeminiCleanup {
                HStack(spacing: 8) {
                    Image(systemName: "doc.viewfinder").foregroundStyle(.orange)
                    Text("This scanned PDF needs Gemini OCR. Turn on cleanup to continue.")
                        .font(vm.appFont(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 4)
            }
            if useGeminiCleanup && !bookVM.hasStoredKey {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                    Text("Set a Gemini API key in Preferences first.")
                        .font(vm.appFont(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 4)
            }
            HStack(spacing: 12) {
                Button { cancel() } label: {
                    Text("Cancel")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.bordered)

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
                            ProgressView().tint(.white).scaleEffect(0.75)
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
                .buttonStyle(.borderedProminent)
                .tint(.cyan)
                .disabled(bookVM.startingProcessing || requiresGeminiOCR)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var actionsCancelOnly: some View {
        Button { cancel() } label: {
            Text("Close").frame(maxWidth: .infinity).padding(.vertical, 8)
        }
        .buttonStyle(.bordered)
    }

    private var requiresGeminiOCR: Bool {
        (bookVM.pendingEstimate?.isImageOnly ?? false) && !useGeminiCleanup
    }

    private var loadingState: some View {
        VStack(spacing: 16) {
            ProgressView().tint(.cyan)
            Text("Reading your file...")
                .font(vm.appFont(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxHeight: .infinity)
    }

    private var errorState: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 32))
                .foregroundStyle(.red)
            Text(bookVM.loadingError ?? "Could not read this file.")
                .font(vm.appFont(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
        }
        .frame(maxHeight: .infinity)
    }

    private var prettyTitle: String {
        let n = documentURL.lastPathComponent
        for ext in [".pdf", ".docx", ".txt", ".md"] {
            if n.lowercased().hasSuffix(ext) { return String(n.dropLast(ext.count)) }
        }
        return n
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

    private var adaptiveSheetBackground: some View {
        LinearGradient(
            colors: [.cyan.opacity(0.05), .clear],
            startPoint: .top, endPoint: .bottom
        )
        .ignoresSafeArea()
    }
}

private struct StatTile: View {
    let label: String
    let value: String
    let icon: String
    let appFont: (CGFloat, Font.Weight) -> Font

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(.cyan).font(.system(size: 11))
                Text(label)
                    .font(appFont(9, .black))
                    .kerning(1.5)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(appFont(18, .bold).monospaced())
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.ultraThinMaterial.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        )
    }
}
