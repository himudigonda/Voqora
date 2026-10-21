import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct NewAudiobookSourceSection: View {
    @ObservedObject var form: AudiobookCreateForm
    let chooseFile: () -> Void

    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var bookVM: AudiobookViewModel
    @Environment(\.voqoraTheme) private var theme
    @State private var isDropTargeted = false
    @FocusState private var isTitleFocused: Bool

    var body: some View {
        FormSection(step: 1, title: "Source", supporting: "A document, a web page, or text you paste.") {
            if let source = bookVM.pendingSource {
                loadedSource(source)
            } else {
                SegmentedTabs(
                    selection: $form.sourceTab,
                    options: AudiobookCreateForm.SourceTab.allCases,
                    title: { $0.title }
                )
                switch form.sourceTab {
                case .file: fileInput
                case .link: linkInput
                case .text: textInput
                }
            }
        }
    }

    private var fileInput: some View {
        DropZone(
            title: "Drop a document here",
            supporting: AudiobookImportStaging.supportedFormatsDescription,
            buttonTitle: "Choose File…",
            isTargeted: isDropTargeted,
            action: chooseFile
        )
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            guard let provider = providers.first else { return false }
            Task {
                guard let url = await AudiobookImportStaging.fileURL(from: provider) else {
                    bookVM.showToast("Voqora could not read that dropped file.", kind: .error)
                    return
                }
                AudiobookCreateRequest.shared.pending = .file(url)
            }
            return true
        }
    }

    private var linkInput: some View {
        VStack(alignment: .leading, spacing: Theme.Space.item) {
            HStack(spacing: Theme.Space.item) {
                TextField("https://example.com/article", text: $form.linkText)
                    .textFieldStyle(.plain)
                    .voqoraFont(.body)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 16)
                    .frame(height: 40)
                    .background(theme.surfaceContainerHigh, in: Capsule())
                    .onSubmit { form.submitLink(library: bookVM) }
                    .onChange(of: form.linkText) { _, _ in form.clearLinkProblem() }
                    .accessibilityLabel("Web page address")
                Button("Fetch") { form.submitLink(library: bookVM) }
                    .buttonStyle(.voqoraFilled)
                    .disabled(!form.canSubmitLink)
            }
            if let problem = form.linkProblem {
                Label(problem.message, systemImage: "exclamationmark.triangle.fill")
                    .voqoraFont(.bodySmall)
                    .foregroundStyle(theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Voqora reads the article on the page, or the PDF the link points to.")
                    .voqoraFont(.bodySmall)
                    .foregroundStyle(theme.onSurfaceVariant)
            }
        }
    }

    private var textInput: some View {
        VStack(alignment: .leading, spacing: Theme.Space.item) {
            TextEditor(text: $form.pasteText)
                .voqoraFont(.body)
                .scrollContentBackground(.hidden)
                .padding(12)
                .frame(minHeight: 180, maxHeight: 280)
                .background(theme.surfaceContainerHigh, in: RoundedRectangle(cornerRadius: Theme.Shape.md, style: .continuous))
                .accessibilityLabel("Text to narrate")
            HStack(spacing: Theme.Space.item) {
                Text(AudiobookCreateSummary.characterSummary(of: form.pasteText))
                    .voqoraFont(.bodySmall)
                    .monospacedDigit()
                    .foregroundStyle(theme.onSurfaceVariant)
                Spacer(minLength: 0)
                Button("Paste from Clipboard") { pasteFromClipboard() }
                    .buttonStyle(.voqoraText)
            }
            TextField("Title (optional)", text: $form.pasteTitle)
                .textFieldStyle(.plain)
                .voqoraFont(.body)
                .padding(.horizontal, 16)
                .frame(height: 40)
                .background(theme.surfaceContainerHigh, in: Capsule())
                .accessibilityLabel("Title")
            Button("Add Text") { form.submitText(library: bookVM) }
                .buttonStyle(.voqoraTonal)
                .disabled(!form.canSubmitText)
        }
    }

    private func loadedSource(_ source: AudiobookImportSource) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.card) {
            SourceCover(source: source)
            VStack(alignment: .leading, spacing: 8) {
                sourceDetail(source)
            }
            Spacer(minLength: Theme.Space.item)
            Button("Replace") { form.replaceSource(library: bookVM) }
                .buttonStyle(.voqoraText)
        }
        .onAppear { syncTitle() }
        .onChange(of: bookVM.pendingEstimate?.bookID) { _, _ in syncTitle() }
    }

    @ViewBuilder
    private func sourceDetail(_ source: AudiobookImportSource) -> some View {
        if let estimate = bookVM.pendingEstimate {
            titleField(source)
            if let byline = byline(for: estimate, source: source) {
                Text(byline)
                    .voqoraFont(.body)
                    .foregroundStyle(theme.onSurfaceVariant)
            }
            Text(sizeSummary(of: estimate))
                .voqoraFont(.bodySmall)
                .foregroundStyle(theme.onSurfaceVariant)
        } else if bookVM.uploadInProgress {
            HStack(spacing: Theme.Space.item) {
                ProgressView().controlSize(.small)
                Text(source.webPageURL == nil ? "Reading file…" : "Fetching page…")
                    .voqoraFont(.body)
                    .foregroundStyle(theme.onSurfaceVariant)
            }
            Text(source.displayName)
                .voqoraFont(.bodySmall)
                .foregroundStyle(theme.onSurfaceMuted)
                .lineLimit(1)
        } else {
            Label(
                bookVM.loadingError ?? (source.webPageURL == nil ? "Could not read this file." : WebPageImportMessage.generic),
                systemImage: "exclamationmark.triangle.fill"
            )
            .voqoraFont(.body)
            .foregroundStyle(theme.danger)
            .fixedSize(horizontal: false, vertical: true)
            Text("Choose Replace to try another source.")
                .voqoraFont(.bodySmall)
                .foregroundStyle(theme.onSurfaceVariant)
        }
    }

    @ViewBuilder
    private func titleField(_ source: AudiobookImportSource) -> some View {
        if source.documentURL != nil {
            TextField("Title", text: $form.titleDraft)
                .textFieldStyle(.plain)
                .voqoraFont(.titleSmall)
                .padding(.horizontal, 14)
                .frame(height: 38)
                .background(theme.surfaceContainerHigh, in: Capsule())
                .focused($isTitleFocused)
                .onSubmit { bookVM.retitlePending(form.titleDraft) }
                .onChange(of: isTitleFocused) { _, focused in
                    if !focused {
                        bookVM.retitlePending(form.titleDraft)
                    }
                }
                .accessibilityLabel("Audiobook title")
                .help("Rename the audiobook")
        } else {
            Text(form.titleDraft)
                .voqoraFont(.titleSmall)
                .foregroundStyle(theme.onSurface)
                .lineLimit(2)
                .help(form.titleDraft)
        }
    }

    private func sizeSummary(of estimate: AudiobookEstimateResponse) -> String {
        let pages = AudiobookCreateSummary.formattedCount(estimate.pageCount)
        let words = AudiobookCreateSummary.formattedCount(estimate.wordCountEstimate)
        return "\(pages) \(estimate.pageCount == 1 ? "page" : "pages") · \(words) words"
    }

    private func byline(for estimate: AudiobookEstimateResponse, source: AudiobookImportSource) -> String? {
        if let author = estimate.displayAuthor {
            return "by \(author)"
        }
        return source.webPageURL.map(WebPageLink.siteName(of:))
    }

    private func syncTitle() {
        guard let estimate = bookVM.pendingEstimate else { return }
        form.titleDraft = AudiobookImportStaging.displayName(from: estimate.title)
    }

    private func pasteFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            bookVM.showToast("The clipboard has no text to use.", kind: .info)
            return
        }
        form.pasteText = text
    }
}
