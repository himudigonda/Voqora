import SwiftUI

struct VoiceCatalogView: View {
    @EnvironmentObject var vm: DashboardViewModel
    @ObservedObject private var store = SpeechEngineStore.shared
    @StateObject private var player = VoiceSamplePlayer()
    @Environment(\.voqoraTheme) private var theme
    @State private var filter = VoiceCatalogFilter.all
    @State private var language: String?
    @State private var query = ""

    private var sections: [VoiceCatalogSection] {
        VoiceCatalogBuilder.sections(engines: store.engines, filter: filter, language: language, query: query)
    }

    private var installable: [SpeechEngine] {
        VoiceCatalogBuilder.installableEngines(engines: store.engines, filter: filter)
    }

    private var languages: [String] {
        VoiceCatalogBuilder.languages(engines: store.engines, filter: filter)
    }

    var body: some View {
        let sections = sections
        PageScaffold(title: VoicesPage.catalog.title, subtitle: VoicesPage.catalog.subtitle) {
            SearchField(text: $query, prompt: "Search voices")
                .frame(width: 260)
        } content: {
            filterRow
            if let message = store.actionError {
                VoicesBanner(message: message)
            }
            ForEach(installable) { engine in
                EngineInstallCard(engine: engine) {
                    Task { await store.install(engine.id) }
                }
            }
            if sections.isEmpty {
                EmptyStateView(
                    symbol: "magnifyingglass",
                    title: "No voices found",
                    message: emptyMessage
                )
            } else {
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: Theme.Space.item) {
                        VoicesSectionHeader(title: section.title, trailing: "\(section.entries.count)")
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 300), spacing: Theme.Space.item, alignment: .top)],
                            alignment: .leading,
                            spacing: Theme.Space.item
                        ) {
                            ForEach(section.entries) { entry in
                                CatalogVoiceCard(
                                    entry: entry,
                                    isPlaying: player.playingVoice == entry.id,
                                    toggleSample: { toggleSample(entry) },
                                    filterEngine: { selectEngine(entry.engineID) }
                                )
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(VoicesPage.catalog.title)
        .task(id: vm.isBackendOnline) {
            if vm.isBackendOnline {
                await store.refresh()
            }
        }
        .onChange(of: filter) { _, _ in
            player.stop()
            if let language, !languages.contains(language) {
                self.language = nil
            }
        }
        .onDisappear { player.stop() }
    }

    private var filterRow: some View {
        HStack(spacing: Theme.Space.item) {
            ForEach(VoiceCatalogFilter.allCases) { option in
                FilterChip(title: option.title, isSelected: filter == option) {
                    filter = option
                }
            }
            Spacer(minLength: Theme.Space.item)
            Menu {
                Button("All Languages") { language = nil }
                Divider()
                ForEach(languages, id: \.self) { name in
                    Button(name) { language = name }
                }
            } label: {
                TonalMenuLabel(text: language ?? "All Languages", systemImage: "globe")
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Filter voices by language")
            .accessibilityValue(language ?? "All Languages")
        }
    }

    private var emptyMessage: String {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !needle.isEmpty {
            return "No voices match “\(needle)”. Try a name or a language."
        }
        if !installable.isEmpty {
            return "Install \(filter.title) above to see its voices."
        }
        return vm.isBackendOnline ? "Voices appear once the engines have loaded." : "Voices appear once Voqora has started."
    }

    private func selectEngine(_ engineID: String) {
        filter = VoiceCatalogFilter(rawValue: engineID) ?? .all
    }

    private func toggleSample(_ entry: VoiceCatalogEntry) {
        if entry.engineVoice != nil {
            player.stop()
            Task { await SpeechSource.$current.withValue(.sample) { await vm.speak(text: DashboardViewModel.sampleSentence(forVoice: entry.id), voice: entry.id) } }
        } else if player.playingVoice == entry.id {
            player.stop()
        } else {
            player.play(voice: entry.id, speed: vm.speechSpeed)
        }
    }
}

private struct CatalogVoiceCard: View {
    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.voqoraTheme) private var theme
    let entry: VoiceCatalogEntry
    let isPlaying: Bool
    let toggleSample: () -> Void
    let filterEngine: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.item) {
            HStack(spacing: Theme.Space.item) {
                VoiceInitialsAvatar(name: entry.name)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(vm.font(.titleSmall))
                        .foregroundStyle(theme.onSurface)
                        .lineLimit(1)
                    Text(entry.detail)
                        .font(vm.font(.bodySmall))
                        .foregroundStyle(theme.onSurfaceVariant)
                        .lineLimit(1)
                }
                Spacer(minLength: Theme.Space.unit)
                VoicePlayButton(
                    name: entry.name,
                    isPlaying: isPlaying,
                    isLoading: false,
                    isEnabled: entry.engineVoice == nil || vm.isBackendOnline,
                    action: toggleSample
                )
            }
            HStack(spacing: 6) {
                AssistChip(title: entry.engineName, action: filterEngine)
                    .help("Show only \(entry.engineName) voices")
                if entry.hasEmotions {
                    VoiceIconChip(systemImage: "face.smiling", help: "Supports emotions")
                }
                VoiceDefaultChips(voiceID: entry.id, compact: true)
                Spacer(minLength: 0)
                VoiceUseMenu(voiceID: entry.id, name: entry.name)
            }
        }
        .padding(Theme.Space.item + 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surfaceContainer, in: RoundedRectangle(cornerRadius: Theme.Shape.lg, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}
