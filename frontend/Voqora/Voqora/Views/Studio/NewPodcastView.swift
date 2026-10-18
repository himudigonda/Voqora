import AppKit
import SwiftUI

struct NewPodcastView: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var studio: StudioViewModel
    @EnvironmentObject var bookVM: AudiobookViewModel
    @EnvironmentObject var providers: LLMProviderStore
    @ObservedObject var model: PodcastBriefModel
    @State private var hasProvider: Bool?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Layout.sectionGap) {
                StudioPageHeader(
                    title: "New Podcast",
                    subtitle: "Pick what to talk about and who's talking. Your AI provider writes the script, then you can edit every line before Voqora renders it.",
                    onBack: { studio.goHome() }
                ) {
                    EmptyView()
                }
                if hasProvider == false {
                    providerPrompt
                }
                sourceSection
                formatSection
                hostsSection
                footer
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: 800, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .disabled(model.isGenerating)
        .onAppear { refreshProvider() }
        .onChange(of: providers.activeProvider) { refreshProvider() }
        .onChange(of: providers.connected) { refreshProvider() }
        .overlay {
            if model.isGenerating {
                generatingOverlay
            }
        }
    }

    private var brief: PodcastBrief {
        model.brief
    }

    private var issues: [PodcastBriefIssue] {
        model.issues(blends: studio.blends)
    }

    private var providerPrompt: some View {
        StudioCard {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                Label(providerPromptTitle, systemImage: "sparkles")
                    .font(vm.font(.sectionTitle))
                    .foregroundStyle(Palette.textPrimary)
                Text("Voqora sends the source text to the AI provider you connect. You can also skip AI and write a script yourself.")
                    .font(vm.font(.rowTitle))
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: DesignTokens.Spacing.sm) {
                    Button("Open Preferences") { vm.selectedTab = "preferences" }
                        .buttonStyle(.voqoraPrimary)
                    Button("New Blank Script") { studio.startBlankScript() }
                        .buttonStyle(.voqoraSecondary)
                }
            }
        }
    }

    private var providerPromptTitle: String {
        providers.needsActiveChoice ? "Choose an AI provider to write scripts" : "Connect an AI provider to write scripts"
    }

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            PaneSectionHeader(title: "Source")
            StudioCard {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                    Picker("Source", selection: $model.brief.sourceKind) {
                        ForEach(PodcastSourceKind.allCases) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityLabel("Source")
                    switch brief.sourceKind {
                    case .library:
                        libraryPicker
                    case .text:
                        textSource
                    }
                }
            }
        }
    }

    private var sourceBooks: [Audiobook] {
        bookVM.books
            .filter { !$0.isPodcast }
            .sorted { $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending }
    }

    @ViewBuilder
    private var libraryPicker: some View {
        if sourceBooks.isEmpty {
            Text("Your Library is empty. Add a document to the Library, or paste text instead.")
                .font(vm.font(.rowTitle))
                .foregroundStyle(Palette.textSecondary)
        } else {
            Picker("Library item", selection: $model.brief.bookID) {
                Text("Choose an item…").tag(String?.none)
                ForEach(sourceBooks) { book in
                    Text(book.displayTitle).tag(String?.some(book.bookID))
                }
            }
            .accessibilityLabel("Library item")
        }
    }

    private var textSource: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            TextEditor(text: $model.brief.text)
                .font(vm.appFont(size: 13))
                .scrollContentBackground(.hidden)
                .padding(DesignTokens.Spacing.sm)
                .frame(minHeight: 140, maxHeight: 240)
                .voqoraSurface(.control, in: RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous))
                .accessibilityLabel("Source text")
            HStack(spacing: DesignTokens.Spacing.sm) {
                Button("Paste from Clipboard") { pasteClipboard() }
                    .buttonStyle(.voqoraSecondary)
                if let spoken = vm.spokenText, !spoken.isEmpty {
                    Button("Use Last Spoken Text") { model.brief.text = spoken }
                        .buttonStyle(.voqoraSecondary)
                }
                Spacer()
                Text("\(PodcastLimits.length(of: brief.text).formatted()) / \(PodcastLimits.sourceCharacters.formatted())")
                    .font(vm.font(.caption))
                    .monospacedDigit()
                    .foregroundStyle(PodcastLimits.length(of: brief.text) > PodcastLimits.sourceCharacters ? Palette.danger : Palette.textTertiary)
                    .accessibilityLabel("\(PodcastLimits.length(of: brief.text)) characters")
            }
        }
    }

    private var formatSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            PaneSectionHeader(title: "Format")
            StudioCard {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.lg) {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                        Picker("Style", selection: styleBinding) {
                            ForEach(PodcastStyle.allCases) { style in
                                Text(style.displayName).tag(style)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .accessibilityLabel("Style")
                        Text(brief.style.summary)
                            .font(vm.font(.rowSubtitle))
                            .foregroundStyle(Palette.textSecondary)
                    }
                    HStack(spacing: DesignTokens.Spacing.md) {
                        Text("Length")
                            .font(vm.font(.rowTitle))
                            .frame(width: 80, alignment: .leading)
                        Slider(value: minutesBinding, in: Double(PodcastLimits.minutes.lowerBound) ... Double(PodcastLimits.minutes.upperBound), step: 1)
                            .accessibilityLabel("Length")
                            .accessibilityValue("\(brief.minutes) minutes")
                        Text("\(brief.minutes) min")
                            .font(vm.font(.rowTitle))
                            .monospacedDigit()
                            .frame(width: 56, alignment: .trailing)
                            .accessibilityHidden(true)
                    }
                    HStack(spacing: DesignTokens.Spacing.md) {
                        Text("Language")
                            .font(vm.font(.rowTitle))
                            .frame(width: 80, alignment: .leading)
                        Picker("Language", selection: languageBinding) {
                            ForEach(PodcastLanguage.allCases) { language in
                                Text(language.displayName).tag(language)
                            }
                        }
                        .labelsHidden()
                        .accessibilityLabel("Language")
                    }
                    HStack(spacing: DesignTokens.Spacing.md) {
                        Text("Title")
                            .font(vm.font(.rowTitle))
                            .frame(width: 80, alignment: .leading)
                        TextField("Optional. The AI suggests one if you leave this empty.", text: $model.brief.title)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Title")
                    }
                }
            }
        }
    }

    private var hostsSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            PaneSectionHeader(title: "Hosts")
            StudioCard {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                    ForEach(brief.hosts.indices, id: \.self) { index in
                        hostRow(index)
                    }
                    StudioPreviewErrorLabel(previewer: studio.previewer)
                    if brief.canAddHost {
                        Button {
                            model.brief.addHost()
                        } label: {
                            Label("Add Host", systemImage: "plus")
                        }
                        .buttonStyle(.voqoraSecondary)
                    }
                }
            }
        }
    }

    private func hostRow(_ index: Int) -> some View {
        let host = brief.hosts[index]
        return HStack(spacing: DesignTokens.Spacing.md) {
            TextField("Name", text: hostNameBinding(index))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)
                .accessibilityLabel("Host \(index + 1) name")
            StudioVoicePicker(
                title: "Host \(index + 1) voice",
                selection: hostVoiceBinding(index),
                groups: StudioVoiceCatalog.groups(blends: studio.blends, language: brief.language),
                blends: studio.blends
            )
            StudioPreviewButton(previewer: studio.previewer, voice: host.voice, speakerName: host.name, blends: studio.blends)
            if brief.canRemoveHost {
                Button {
                    model.brief.removeHost(at: index)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Remove host")
                .accessibilityLabel("Remove host \(index + 1)")
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            if case let .failed(message) = model.state {
                StudioBanner(message: message, tint: Palette.danger)
            }
            if model.showsIssues, issues.count > 1 {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                    ForEach(issues, id: \.self) { issue in
                        Label(issue.message, systemImage: "exclamationmark.circle")
                            .font(vm.font(.rowSubtitle))
                            .foregroundStyle(Palette.textSecondary)
                    }
                }
            }
            HStack {
                Text(providers.activeProvider.map { "Written by \($0.displayName)" } ?? "")
                    .font(vm.font(.rowSubtitle))
                    .foregroundStyle(Palette.textTertiary)
                Spacer()
                Button("Generate Script") {
                    studio.previewer.stop()
                    model.generate(blends: studio.blends)
                }
                .buttonStyle(.voqoraPrimary)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(hasProvider != true)
                .help("Write the script with your AI provider (Command-Return)")
            }
        }
    }

    private var generatingOverlay: some View {
        ZStack {
            Palette.surfaceBase.opacity(0.7).ignoresSafeArea()
            VStack(spacing: DesignTokens.Spacing.md) {
                ProgressView()
                Text("Writing your script…")
                    .font(vm.font(.sectionTitle))
                    .foregroundStyle(Palette.textPrimary)
                Text("This can take a minute or two for longer podcasts.")
                    .font(vm.font(.rowSubtitle))
                    .foregroundStyle(Palette.textSecondary)
                Button("Cancel") { model.cancel() }
                    .buttonStyle(.voqoraSecondary)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(DesignTokens.Spacing.xl)
            .voqoraSurface(.floating, in: RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.xLarge, style: .continuous))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Writing your script")
        }
    }

    private var styleBinding: Binding<PodcastStyle> {
        Binding(get: { model.brief.style }, set: { model.brief.applyStyle($0) })
    }

    private var languageBinding: Binding<PodcastLanguage> {
        Binding(get: { model.brief.language }, set: { model.brief.applyLanguage($0, blends: studio.blends) })
    }

    private var minutesBinding: Binding<Double> {
        Binding(get: { Double(model.brief.minutes) }, set: { model.brief.minutes = Int($0.rounded()) })
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

    private func refreshProvider() {
        hasProvider = providers.activeCredential != nil
    }

    private func pasteClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            bookVM.showToast("The clipboard has no text to use.", kind: .info)
            return
        }
        model.brief.text = text
    }
}

struct StudioCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DesignTokens.Layout.cardInset)
            .voqoraSurface(.raised, in: RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.xLarge, style: .continuous))
    }
}
