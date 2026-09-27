import KeyboardShortcuts
import SwiftUI

struct MainDashboardView: View {
    @EnvironmentObject var bookVM: AudiobookViewModel

    var body: some View {
        if let book = bookVM.nowPlaying {
            AudiobookPlayerView(book: book)
                .id(book.bookID)
        } else {
            SpeechPlayerView()
        }
    }
}

private struct SpeechPlayerView: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var permissions: PermissionsService

    var body: some View {
        VStack(spacing: 0) {
            EngineStatusBanner()
            if !permissions.accessibilityGranted {
                AccessibilityBanner()
            }
            if vm.spokenText != nil {
                PlayerScaffold { height in
                    SpeechArtwork(height: height)
                } header: { alignment in
                    PlayerTitle(title: "Selected Text", subtitle: "Narrated by \(vm.currentVoiceDisplay)", alignment: alignment)
                } controls: { compact in
                    SpeechControls(compact: compact)
                } content: { fontSize in
                    TranscriptView(follower: vm.speechFollower, fontSize: fontSize) { line in
                        vm.playSpokenText(from: line)
                    }
                    .padding(.top, 24)
                }
                .focusable()
                .focusEffectDisabled()
                .onKeyPress(.space) { vm.togglePlayback(); return .handled }
                .onKeyPress(.leftArrow) { vm.skipSpeech(by: -10); return .handled }
                .onKeyPress(.rightArrow) { vm.skipSpeech(by: 10); return .handled }
            } else {
                IdleState()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) { StatusMessage() }
    }
}

private struct SpeechArtwork: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var audio: AudioService
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let height: CGFloat

    var body: some View {
        let playing = audio.isPlaying
        let ramp = Palette.accentRamp(for: vm.accentColorID, appearance: colorScheme, increaseContrast: contrast == .increased)
        let radius: CGFloat = height > 120 ? 18 : 10
        let side = height > 120 ? height * AudiobookCardView.coverAspectRatio : height
        ZStack {
            LinearGradient(colors: [Color(ramp.strong), Color(ramp.muted)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "waveform")
                .font(.system(size: side * 0.3, weight: .medium))
                .foregroundStyle(.white.opacity(0.92))
                .symbolEffect(.variableColor.iterative.dimInactiveLayers, isActive: playing && !reduceMotion)
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .shadow(color: .black.opacity(playing ? 0.3 : 0.18), radius: playing ? 22 : 10, y: playing ? 10 : 5)
        .scaleEffect(playing || height <= 120 ? 1 : 0.94)
        .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.8), value: playing)
        .accessibilityHidden(true)
    }
}

private struct SpeechControls: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var audio: AudioService
    let compact: Bool

    var body: some View {
        VStack(spacing: compact ? 14 : 22) {
            PlaybackScrubber(
                isEnabled: audio.hasMedia,
                onScrub: { vm.speechFollower.scrub(to: $0) },
                onCommit: { audio.seek(toSeconds: $0) }
            )
            HStack(spacing: compact ? 14 : 22) {
                TransportGlyph(systemName: "gobackward.10", label: "Back 10 Seconds") { vm.skipSpeech(by: -10) }
                PlayerPlayButton(isPlaying: audio.isPlaying, isLoading: vm.status == .thinking, size: compact ? 48 : 64) {
                    vm.togglePlayback()
                }
                TransportGlyph(systemName: "goforward.10", label: "Forward 10 Seconds") { vm.skipSpeech(by: 10) }
            }
            HStack(spacing: 10) {
                PlayerCircleButton(systemName: "stop.fill", label: "Stop", isEnabled: audio.hasMedia) {
                    vm.stopPlayback()
                }
                Spacer(minLength: 0)
                PlayerVolumeControl()
                Spacer(minLength: 0)
                PlayerCircleButton(
                    systemName: "square.and.arrow.down",
                    label: "Save Clip to Desktop",
                    isEnabled: audio.canExportLastClip
                ) {
                    vm.exportLastClip()
                }
            }
            .frame(maxWidth: compact ? 420 : .infinity)
        }
    }
}

private struct IdleState: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var bookVM: AudiobookViewModel

    private var shortcut: String {
        KeyboardShortcuts.getShortcut(for: .playText)?.description ?? "⌘⇧."
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Palette.textTertiary)
            VStack(spacing: 6) {
                Text("Nothing Playing")
                    .font(vm.appFont(size: 20, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                Text("Press \(shortcut) to hear selected text from any app")
                    .font(vm.appFont(size: 13))
                    .foregroundStyle(Palette.textSecondary)
            }
            if let book = bookVM.continueListeningBook {
                Button {
                    vm.openAudiobook(book.bookID)
                } label: {
                    Label("Resume \(book.displayTitle)", systemImage: "play.fill")
                        .lineLimit(1)
                }
                .buttonStyle(.voqoraSecondary)
                .padding(.top, 6)
            }
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct EngineStatusBanner: View {
    @EnvironmentObject var vm: DashboardViewModel

    var body: some View {
        if !vm.isBackendOnline {
            HStack(spacing: 8) {
                if vm.isBackendInitializing {
                    ProgressView().controlSize(.mini)
                    Text("Starting speech engine…")
                } else {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Palette.warning)
                    Text(vm.backendRecoveryMessage ?? "Speech engine unavailable. Retrying…")
                        .lineLimit(2)
                }
            }
            .font(vm.appFont(size: 12, weight: .medium))
            .foregroundStyle(Palette.textSecondary)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(Palette.surfaceRaised)
            .overlay(alignment: .bottom) { Rectangle().fill(Palette.separator).frame(height: 1) }
        }
    }
}

private struct AccessibilityBanner: View {
    @EnvironmentObject var vm: DashboardViewModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(Palette.textSecondary)
            Text("Allow Accessibility access to read selected text.")
                .font(vm.appFont(size: 12, weight: .medium))
                .foregroundStyle(Palette.textPrimary)
            Spacer()
            Button("Open System Settings") {
                PermissionsService.shared.openAccessibilitySettings()
            }
            .buttonStyle(.voqoraSecondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Palette.surfaceRaised)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.separator).frame(height: 1) }
    }
}

private struct StatusMessage: View {
    @EnvironmentObject var vm: DashboardViewModel

    private var message: (text: String, isError: Bool)? {
        if let feedback = vm.actionFeedback {
            return (feedback, false)
        }
        if case let .error(text) = vm.status {
            return (text, true)
        }
        return nil
    }

    var body: some View {
        Group {
            if let message {
                Text(message.text)
                    .font(vm.appFont(size: 12, weight: .medium))
                    .foregroundStyle(message.isError ? Palette.danger : Palette.textPrimary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().stroke(Palette.separator, lineWidth: 0.5))
                    .padding(.top, 14)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: message?.text)
    }
}
