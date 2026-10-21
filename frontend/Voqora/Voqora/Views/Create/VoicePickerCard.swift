import SwiftUI

struct StudioVoiceAvatar: View {
    let name: String
    var size: CGFloat = 48

    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.voqoraTheme) private var theme

    var body: some View {
        Text(Self.initial(of: name))
            .font(vm.appFont(size: size * 0.4, weight: .semibold))
            .foregroundStyle(theme.onPrimaryContainer)
            .frame(width: size, height: size)
            .background(theme.primaryContainer, in: Circle())
            .accessibilityHidden(true)
    }

    static func initial(of name: String) -> String {
        let letter = name.first { $0.isLetter || $0.isNumber }
        return letter.map { String($0).uppercased() } ?? "V"
    }
}

struct VoicePickerCard: View {
    enum Style {
        case inline
        case tile
    }

    let title: String
    @Binding var voiceID: String
    var scope: VoicePickerScope
    var style: Style

    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.voqoraTheme) private var theme
    @ObservedObject private var blendStore = VoiceBlendStore.shared
    @StateObject private var previewer = StudioVoicePreviewer(service: PodcastService())
    @State private var isChoosing = false

    init(title: String, voiceID: Binding<String>, scope: VoicePickerScope = .everything, style: Style = .inline) {
        self.title = title
        _voiceID = voiceID
        self.scope = scope
        self.style = style
    }

    private var descriptor: VoicePickerDescriptor {
        VoicePickerCatalog.descriptor(forVoice: voiceID, blends: blendStore.blends)
    }

    private var isPlaying: Bool {
        previewer.playingVoice == voiceID
    }

    private var isLoading: Bool {
        previewer.loadingVoice == voiceID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.item) {
            HStack(spacing: Theme.Space.item + 4) {
                StudioVoiceAvatar(name: descriptor.name)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .voqoraFont(.labelSmall)
                        .foregroundStyle(theme.onSurfaceVariant)
                    Text(descriptor.name)
                        .voqoraFont(.titleSmall)
                        .foregroundStyle(theme.onSurface)
                        .lineLimit(1)
                        .help(descriptor.name)
                    HStack(spacing: 8) {
                        StatusChip(text: descriptor.engineName, kind: .info)
                        if !descriptor.languageLabel.isEmpty {
                            Text(descriptor.languageLabel)
                                .voqoraFont(.bodySmall)
                                .foregroundStyle(theme.onSurfaceVariant)
                                .lineLimit(1)
                        }
                    }
                }
                Spacer(minLength: Theme.Space.item)
                sampleButton
                Button("Change") { isChoosing = true }
                    .buttonStyle(.voqoraTonal)
                    .popover(isPresented: $isChoosing, arrowEdge: .bottom) {
                        VoiceBrowserPopover(
                            selection: $voiceID,
                            scope: scope,
                            previewer: previewer,
                            dismiss: { isChoosing = false }
                        )
                        .environmentObject(vm)
                        .environment(\.voqoraTheme, theme)
                    }
                    .accessibilityLabel("Change \(title)")
            }
            if let message = previewer.errorMessage {
                Label(message, systemImage: "exclamationmark.circle.fill")
                    .voqoraFont(.bodySmall)
                    .foregroundStyle(theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(style == .tile ? Theme.Space.item + 4 : 0)
        .background {
            if style == .tile {
                RoundedRectangle(cornerRadius: Theme.Shape.md, style: .continuous).fill(theme.surfaceContainerHigh)
            }
        }
        .onDisappear { previewer.stop() }
        .onChange(of: voiceID) { _, _ in previewer.stop() }
    }

    private var sampleButton: some View {
        Button {
            previewer.toggle(voice: voiceID, sentence: DashboardViewModel.sampleSentence(forVoice: voiceID))
        } label: {
            if isLoading {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: isPlaying ? "stop.fill" : "play.fill")
            }
        }
        .buttonStyle(.voqoraIconTonal)
        .disabled(voiceID.isEmpty)
        .help(isPlaying ? "Stop sample" : "Play sample")
        .accessibilityLabel(isPlaying ? "Stop sample of \(descriptor.name)" : "Play sample of \(descriptor.name)")
    }
}

private struct VoiceBrowserPopover: View {
    @Binding var selection: String
    let scope: VoicePickerScope
    @ObservedObject var previewer: StudioVoicePreviewer
    let dismiss: () -> Void

    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.voqoraTheme) private var theme
    @ObservedObject private var blendStore = VoiceBlendStore.shared
    @ObservedObject private var engineStore = SpeechEngineStore.shared
    @State private var query = ""

    private var sections: [VoicePickerSection] {
        VoicePickerCatalog.sections(
            blends: blendStore.blends,
            engines: engineStore.engines,
            query: query,
            scope: scope
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.item) {
            SearchField(text: $query, prompt: "Search voices")
            let current = sections
            if current.isEmpty {
                Text("No voices match \u{201C}\(query)\u{201D}.")
                    .voqoraFont(.body)
                    .foregroundStyle(theme.onSurfaceVariant)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.Space.item) {
                        ForEach(current) { section in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(section.title)
                                    .voqoraFont(.labelSmall)
                                    .foregroundStyle(theme.primary)
                                    .padding(.horizontal, 8)
                                    .padding(.bottom, 4)
                                ForEach(section.entries) { entry in
                                    row(entry)
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(Theme.Space.item + 4)
        .frame(width: 380, height: 440)
        .background(theme.surfaceContainerHigh)
        .task {
            if scope.includesEngineVoices, engineStore.engines.isEmpty {
                await engineStore.refresh()
            }
        }
    }

    private func row(_ entry: VoicePickerEntry) -> some View {
        let isSelected = entry.id == selection
        return HStack(spacing: Theme.Space.item) {
            Button {
                selection = entry.id
                dismiss()
            } label: {
                HStack(spacing: Theme.Space.item) {
                    StudioVoiceAvatar(name: entry.name, size: 32)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.name)
                            .voqoraFont(.label)
                            .foregroundStyle(theme.onSurface)
                            .lineLimit(1)
                        if !entry.detail.isEmpty {
                            Text(entry.detail)
                                .voqoraFont(.labelSmall)
                                .foregroundStyle(theme.onSurfaceVariant)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(theme.primary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button {
                previewer.toggle(voice: entry.id, sentence: DashboardViewModel.sampleSentence(forVoice: entry.id))
            } label: {
                if previewer.loadingVoice == entry.id {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: previewer.playingVoice == entry.id ? "stop.fill" : "play.fill")
                }
            }
            .buttonStyle(.voqoraIcon)
            .accessibilityLabel("Play sample of \(entry.name)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(isSelected ? theme.secondaryContainer : .clear, in: RoundedRectangle(cornerRadius: Theme.Shape.sm, style: .continuous))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
