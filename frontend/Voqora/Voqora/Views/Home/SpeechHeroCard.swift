import SwiftUI

struct SpeechHeroCard: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var audio: AudioService
    @Environment(\.voqoraTheme) private var theme

    var body: some View {
        VoqoraCard(.elevated) {
            VStack(alignment: .leading, spacing: Theme.Space.card) {
                header
                TranscriptView(follower: vm.speechFollower, fontSize: 22) { line in
                    vm.playSpokenText(from: line)
                }
                .frame(height: 260)
                controls
            }
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.space) { vm.togglePlayback(); return .handled }
        .onKeyPress(.leftArrow) { vm.skipSpeech(by: -10); return .handled }
        .onKeyPress(.rightArrow) { vm.skipSpeech(by: 10); return .handled }
        .onKeyPress("[") { vm.setSpeechSpeed(vm.effectiveSpeechSpeed - 0.25); return .handled }
        .onKeyPress("]") { vm.setSpeechSpeed(vm.effectiveSpeechSpeed + 0.25); return .handled }
    }

    private var header: some View {
        HStack(spacing: Theme.Space.item + 4) {
            Image(systemName: "waveform")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(theme.onPrimaryContainer)
                .symbolEffect(.variableColor.iterative.dimInactiveLayers, isActive: audio.isPlaying)
                .frame(width: 48, height: 48)
                .background(theme.primaryContainer, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Selected Text")
                    .font(vm.font(.title))
                    .foregroundStyle(theme.onSurface)
                Text("Narrated by \(vm.currentVoiceDisplay)")
                    .font(vm.font(.bodySmall))
                    .foregroundStyle(theme.onSurfaceVariant)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if vm.status == .thinking {
                StatusChip(text: "Preparing", kind: .info)
            }
            ReadingModeButton()
        }
    }

    private var controls: some View {
        VStack(spacing: Theme.Space.item + 4) {
            PlaybackScrubber(
                isEnabled: audio.hasMedia,
                onScrub: { vm.speechFollower.scrub(to: $0) },
                onCommit: { audio.seek(toSeconds: $0) }
            )
            HStack(spacing: Theme.Space.item) {
                PlayerSpeedMenu(speed: vm.effectiveSpeechSpeed) { vm.setSpeechSpeed($0) }
                PlayerVolumeControl()
                Spacer(minLength: 0)
                TransportGlyph(systemName: "gobackward.10", label: "Back 10 Seconds", size: 20) { vm.skipSpeech(by: -10) }
                PlayerPlayButton(isPlaying: audio.isPlaying, isLoading: vm.status == .thinking, size: 60) {
                    vm.togglePlayback()
                }
                TransportGlyph(systemName: "goforward.10", label: "Forward 10 Seconds", size: 20) { vm.skipSpeech(by: 10) }
                Spacer(minLength: 0)
                PlayerCircleButton(systemName: "stop.fill", label: "Stop", isEnabled: audio.hasMedia) {
                    vm.stopPlayback()
                }
                PlayerCircleButton(
                    systemName: "square.and.arrow.down",
                    label: "Save Clip to Desktop",
                    isEnabled: audio.canExportLastClip
                ) {
                    vm.exportLastClip()
                }
            }
        }
    }
}
