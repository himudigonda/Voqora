import AppKit
import SwiftUI

struct NewPodcastView: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var studio: StudioViewModel
    @EnvironmentObject var bookVM: AudiobookViewModel
    @EnvironmentObject var providers: LLMProviderStore
    @ObservedObject var model: PodcastBriefModel

    var body: some View {
        PageScaffold(
            title: "New Podcast",
            subtitle: "Pick what to talk about and who is talking. Your AI provider writes the script, and you can edit every line before Voqora renders it.",
            scrolls: false
        ) {
            FormColumns {
                Group {
                    PodcastSourceSection(model: model)
                    PodcastFormatSection(model: model)
                    PodcastHostsSection(model: model)
                }
                .disabled(model.isGenerating)
            } side: {
                PodcastSummaryCard(model: model)
            }
        }
    }
}

private struct PodcastSourceSection: View {
    @ObservedObject var model: PodcastBriefModel

    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var bookVM: AudiobookViewModel
    @Environment(\.voqoraTheme) private var theme

    private var sourceBooks: [Audiobook] {
        bookVM.books
            .filter { !$0.isPodcast }
            .sorted { $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending }
    }

    private var chosenBook: Audiobook? {
        sourceBooks.first { $0.bookID == model.brief.bookID }
    }

    var body: some View {
        FormSection(step: 1, title: "Source", supporting: "What the hosts talk about.") {
            SegmentedTabs(
                selection: $model.brief.sourceKind,
                options: PodcastSourceKind.allCases,
                title: { $0 == .library ? "Library item" : "Paste text" }
            )
            switch model.brief.sourceKind {
            case .library: libraryPicker
            case .text: textSource
            }
        }
    }

    @ViewBuilder
    private var libraryPicker: some View {
        if sourceBooks.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.item) {
                Text("Your Library is empty. Create an audiobook first, or paste text instead.")
                    .voqoraFont(.body)
                    .foregroundStyle(theme.onSurfaceVariant)
                Button("New Audiobook") { vm.selectedTab = TabKey.createAudiobook }
                    .buttonStyle(.voqoraTonal)
            }
        } else {
            Menu {
                ForEach(sourceBooks) { book in
                    Button {
                        model.brief.bookID = book.bookID
                    } label: {
                        if book.bookID == model.brief.bookID {
                            Label(book.displayTitle, systemImage: "checkmark")
                        } else {
                            Text(book.displayTitle)
                        }
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "books.vertical")
                        .accessibilityHidden(true)
                    Text(chosenBook?.displayTitle ?? "Choose an item…")
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                }
                .voqoraFont(.body)
                .foregroundStyle(chosenBook == nil ? theme.onSurfaceVariant : theme.onSurface)
                .padding(.horizontal, 16)
                .frame(height: 44)
                .background(theme.surfaceContainerHigh, in: Capsule())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .accessibilityLabel("Library item")
            if let chosenBook {
                Text(chosenBook.creditLine)
                    .voqoraFont(.bodySmall)
                    .foregroundStyle(theme.onSurfaceVariant)
                    .lineLimit(1)
            }
        }
    }

    private var textSource: some View {
        VStack(alignment: .leading, spacing: Theme.Space.item) {
            TextEditor(text: $model.brief.text)
                .voqoraFont(.body)
                .scrollContentBackground(.hidden)
                .padding(12)
                .frame(minHeight: 160, maxHeight: 260)
                .background(theme.surfaceContainerHigh, in: RoundedRectangle(cornerRadius: Theme.Shape.md, style: .continuous))
                .accessibilityLabel("Source text")
            HStack(spacing: Theme.Space.item) {
                Button("Paste from Clipboard") { pasteClipboard() }
                    .buttonStyle(.voqoraTonal)
                if let spoken = vm.spokenText, !spoken.isEmpty {
                    Button("Use Last Spoken Text") { model.brief.text = spoken }
                        .buttonStyle(.voqoraTonal)
                }
                Spacer(minLength: 0)
                let length = PodcastLimits.length(of: model.brief.text)
                Text("\(length.formatted()) / \(PodcastLimits.sourceCharacters.formatted())")
                    .voqoraFont(.bodySmall)
                    .monospacedDigit()
                    .foregroundStyle(length > PodcastLimits.sourceCharacters ? theme.danger : theme.onSurfaceVariant)
                    .accessibilityLabel("\(length) characters")
            }
        }
    }

    private func pasteClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            bookVM.showToast("The clipboard has no text to use.", kind: .info)
            return
        }
        model.brief.text = text
    }
}

private struct PodcastFormatSection: View {
    @ObservedObject var model: PodcastBriefModel

    @EnvironmentObject var studio: StudioViewModel
    @Environment(\.voqoraTheme) private var theme

    var body: some View {
        FormSection(step: 2, title: "Format", supporting: "Style, length and language.") {
            VStack(alignment: .leading, spacing: 8) {
                FlowLayout {
                    ForEach(PodcastStyle.allCases) { style in
                        FilterChip(title: style.displayName, isSelected: model.brief.style == style) {
                            model.brief.applyStyle(style)
                        }
                    }
                }
                Text(model.brief.style.summary)
                    .voqoraFont(.bodySmall)
                    .foregroundStyle(theme.onSurfaceVariant)
            }
            SettingsSliderRow(
                title: "Length",
                value: minutesBinding,
                range: Double(PodcastLimits.minutes.lowerBound) ... Double(PodcastLimits.minutes.upperBound),
                step: 1,
                valueLabel: "\(model.brief.minutes) min"
            )
            SettingsPickerRow(title: "Language", valueLabel: model.brief.language.displayName) {
                ForEach(PodcastLanguage.allCases) { language in
                    Button {
                        model.brief.applyLanguage(language, blends: studio.blends)
                    } label: {
                        if language == model.brief.language {
                            Label(language.displayName, systemImage: "checkmark")
                        } else {
                            Text(language.displayName)
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Title")
                    .voqoraFont(.label)
                    .foregroundStyle(theme.onSurfaceVariant)
                TextField("Optional. The AI suggests one if you leave this empty.", text: $model.brief.title)
                    .textFieldStyle(.plain)
                    .voqoraFont(.body)
                    .padding(.horizontal, 16)
                    .frame(height: 40)
                    .background(theme.surfaceContainerHigh, in: Capsule())
                    .accessibilityLabel("Title")
            }
        }
    }

    private var minutesBinding: Binding<Double> {
        Binding(get: { Double(model.brief.minutes) }, set: { model.brief.minutes = Int($0.rounded()) })
    }
}

private struct PodcastHostsSection: View {
    @ObservedObject var model: PodcastBriefModel

    @Environment(\.voqoraTheme) private var theme

    var body: some View {
        FormSection(step: 3, title: "Hosts", supporting: "Podcasts use Kokoro voices and your blends.") {
            ForEach(model.brief.hosts.indices, id: \.self) { index in
                if index > 0 {
                    Divider().overlay(theme.outlineVariant)
                }
                hostBlock(index)
            }
            if model.brief.canAddHost {
                Button {
                    model.brief.addHost()
                } label: {
                    Label("Add Host", systemImage: "plus")
                }
                .buttonStyle(.voqoraTonal)
            }
        }
    }

    private func hostBlock(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.item) {
            HStack(spacing: Theme.Space.item) {
                TextField("Host \(index + 1) name", text: hostNameBinding(index))
                    .textFieldStyle(.plain)
                    .voqoraFont(.body)
                    .padding(.horizontal, 16)
                    .frame(height: 40)
                    .background(theme.surfaceContainerHigh, in: Capsule())
                    .accessibilityLabel("Host \(index + 1) name")
                if model.brief.canRemoveHost {
                    Button {
                        model.brief.removeHost(at: index)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.voqoraIcon)
                    .help("Remove host")
                    .accessibilityLabel("Remove host \(index + 1)")
                }
            }
            VoicePickerCard(
                title: "Host \(index + 1) voice",
                voiceID: hostVoiceBinding(index),
                scope: .podcast(model.brief.language)
            )
        }
    }

    private func hostNameBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { model.brief.hosts.indices.contains(index) ? model.brief.hosts[index].name : "" },
            set: {
                if model.brief.hosts.indices.contains(index) {
                    model.brief.hosts[index].name = $0
                }
            }
        )
    }

    private func hostVoiceBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { model.brief.hosts.indices.contains(index) ? model.brief.hosts[index].voice : "" },
            set: {
                if model.brief.hosts.indices.contains(index) {
                    model.brief.hosts[index].voice = $0
                }
            }
        )
    }
}

private struct PodcastSummaryCard: View {
    @ObservedObject var model: PodcastBriefModel

    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var studio: StudioViewModel
    @EnvironmentObject var providers: LLMProviderStore
    @Environment(\.voqoraTheme) private var theme

    private var brief: PodcastBrief {
        model.brief
    }

    private var hasProvider: Bool {
        providers.activeCredential != nil
    }

    var body: some View {
        SummaryCard {
            VStack(alignment: .leading, spacing: 4) {
                Text(brief.title.isEmpty ? "Untitled podcast" : brief.title)
                    .voqoraFont(.titleSmall)
                    .foregroundStyle(theme.onSurface)
                    .lineLimit(2)
                Text("\(brief.style.displayName) · \(brief.language.displayName)")
                    .voqoraFont(.bodySmall)
                    .foregroundStyle(theme.onSurfaceVariant)
            }
            statRow("Length", "About \(brief.minutes) min", systemImage: "waveform")
            statRow("Hosts", brief.hosts.map(\.name).joined(separator: ", "), systemImage: "person.2")
            statRow("Written by", providers.activeProvider?.displayName ?? "No provider", systemImage: "sparkles")
            if hasProvider {
                generator
            } else {
                providerPrompt
            }
        }
    }

    @ViewBuilder
    private var generator: some View {
        if model.isGenerating {
            HStack(spacing: Theme.Space.item) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Writing your script…")
                        .voqoraFont(.label)
                        .foregroundStyle(theme.onSurface)
                    Text("This can take a minute or two for longer podcasts.")
                        .voqoraFont(.bodySmall)
                        .foregroundStyle(theme.onSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button("Cancel") { model.cancel() }
                .buttonStyle(.voqoraOutlined)
                .frame(maxWidth: .infinity)
        } else {
            if case let .failed(message) = model.state {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .voqoraFont(.bodySmall)
                    .foregroundStyle(theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            issueList
            Button("Generate Script") {
                studio.previewer.stop()
                model.generate(blends: studio.blends)
            }
            .buttonStyle(.voqoraFilled)
            .frame(maxWidth: .infinity)
            .keyboardShortcut(.return, modifiers: .command)
            .help("Write the script with your AI provider (Command-Return)")
            Button("Write It Myself") { studio.startBlankScript() }
                .buttonStyle(.voqoraText)
                .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var issueList: some View {
        let issues = model.issues(blends: studio.blends)
        if model.showsIssues, issues.count > 1 {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(issues, id: \.self) { issue in
                    Label(issue.message, systemImage: "exclamationmark.circle")
                        .voqoraFont(.bodySmall)
                        .foregroundStyle(theme.onSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var providerPrompt: some View {
        VStack(alignment: .leading, spacing: Theme.Space.item) {
            Text(providers.needsActiveChoice ? "Choose an AI provider to write scripts" : "Connect an AI provider to write scripts")
                .voqoraFont(.titleSmall)
                .foregroundStyle(theme.onSurface)
            Text("Voqora sends the source text to the provider you connect. You can also skip AI and write a script yourself.")
                .voqoraFont(.bodySmall)
                .foregroundStyle(theme.onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)
            Button("Add Provider") { vm.showSettings(.ai) }
                .buttonStyle(.voqoraFilled)
                .frame(maxWidth: .infinity)
            Button("Write It Myself") { studio.startBlankScript() }
                .buttonStyle(.voqoraTonal)
                .frame(maxWidth: .infinity)
        }
    }

    private func statRow(_ title: String, _ value: String, systemImage: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label(title, systemImage: systemImage)
                .voqoraFont(.label)
                .foregroundStyle(theme.onSurfaceVariant)
            Spacer(minLength: 8)
            Text(value)
                .voqoraFont(.label)
                .foregroundStyle(theme.onSurface)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(value)
        }
    }
}
