import SwiftUI

struct VoiceCatalogView: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var bookVM: AudiobookViewModel
    @StateObject private var player = VoiceSamplePlayer()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Layout.sectionGap) {
                VoicesPageHeader(page: .catalog)
                Text("\(DashboardViewModel.voiceCatalog.count) voices in \(DashboardViewModel.languageGroups.count) languages")
                    .font(vm.font(.rowSubtitle))
                    .foregroundStyle(Palette.textTertiary)
                ForEach(DashboardViewModel.languageGroups) { group in
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                        PaneSectionHeader(title: group.beta ? "\(group.flag) \(group.id) (Beta)" : "\(group.flag) \(group.id)")
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(group.voices) { voice in
                                VoiceCatalogRow(
                                    voice: voice,
                                    player: player,
                                    isSpeechVoice: vm.selectedVoice == voice.id,
                                    isBookVoice: bookVM.defaultBookVoice == voice.id
                                )
                                if voice.id != group.voices.last?.id {
                                    Divider()
                                }
                            }
                        }
                        .voqoraSurface(.raised, in: RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.xLarge, style: .continuous))
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: 800, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Voice Catalog")
        .onDisappear { player.stop() }
    }
}

private struct VoiceCatalogRow: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var bookVM: AudiobookViewModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    let voice: DashboardViewModel.VoiceOption
    @ObservedObject var player: VoiceSamplePlayer
    let isSpeechVoice: Bool
    let isBookVoice: Bool

    private var isPlaying: Bool {
        player.playingVoice == voice.id
    }

    var body: some View {
        let accent = vm.accentColor(scheme: colorScheme, contrast: contrast)
        HStack(spacing: DesignTokens.Spacing.md) {
            PlayerCircleButton(
                systemName: isPlaying ? "stop.fill" : "play.fill",
                label: isPlaying ? "Stop \(voice.name) sample" : "Play \(voice.name) sample"
            ) {
                if isPlaying {
                    player.stop()
                } else {
                    player.play(voice: voice.id, speed: vm.speechSpeed)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    Text(voice.name)
                        .font(vm.appFont(size: 14, weight: .semibold))
                        .foregroundStyle(Palette.textPrimary)
                    if isSpeechVoice {
                        VoicesChip(text: "Speech", tint: accent)
                    }
                    if isBookVoice {
                        VoicesChip(text: "Audiobooks", tint: accent)
                    }
                }
                Text(voice.language)
                    .font(vm.font(.rowSubtitle))
                    .foregroundStyle(Palette.textSecondary)
            }
            Spacer(minLength: 0)
            Menu("Use") {
                Button("Use for Speech") { vm.selectedVoice = voice.id }
                    .disabled(isSpeechVoice)
                Button("Use for Audiobooks") { bookVM.defaultBookVoice = voice.id }
                    .disabled(isBookVoice)
            }
            .fixedSize()
            .accessibilityLabel("Use \(voice.name)")
        }
        .padding(.horizontal, DesignTokens.Layout.cardInset)
        .padding(.vertical, 10)
        .contextMenu {
            Button("Use for Speech") { vm.selectedVoice = voice.id }
                .disabled(isSpeechVoice)
            Button("Use for Audiobooks") { bookVM.defaultBookVoice = voice.id }
                .disabled(isBookVoice)
        }
    }
}
