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
                TranscriptView(follower: vm.speechFollower, fontSize: 28, anchor: 0.32) { line in
                    vm.playSpokenText(from: line)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                SpeechControls()
                    .frame(maxWidth: 560)
                    .padding(.horizontal, 40)
                    .padding(.top, 8)
                    .padding(.bottom, 28)
            } else {
                IdleState()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) { StatusMessage() }
    }
}

private struct SpeechControls: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var audio: AudioService
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(spacing: 14) {
            PlaybackScrubber(
                isEnabled: audio.hasMedia,
                onScrub: { vm.speechFollower.scrub(to: $0) },
                onCommit: { audio.seek(toSeconds: $0) }
            )
            ZStack {
                HStack {
                    Text(vm.currentVoiceDisplay)
                        .font(vm.appFont(size: 12, weight: .medium))
                        .foregroundStyle(Palette.textSecondary)
                    Spacer()
                    if audio.canExportLastClip {
                        Button {
                            vm.exportLastClip()
                        } label: {
                            Image(systemName: "square.and.arrow.down")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Palette.textPrimary)
                                .frame(width: 30, height: 30)
                                .background(Circle().fill(Palette.controlFill))
                        }
                        .buttonStyle(.plain)
                        .help("Save Clip to Desktop")
                        .accessibilityLabel("Save Clip to Desktop")
                    }
                }
                HStack(spacing: 22) {
                    TransportGlyph(systemName: "gobackward.10", label: "Back 10 Seconds") { audio.skip(by: -10) }
                    playButton
                    TransportGlyph(systemName: "goforward.10", label: "Forward 10 Seconds") { audio.skip(by: 10) }
                }
            }
        }
    }

    private var playButton: some View {
        let playing = audio.isPlaying
        return Button {
            vm.togglePlayback()
        } label: {
            ZStack {
                Circle().fill(vm.accentColor(scheme: colorScheme, contrast: contrast))
                if vm.status == .thinking {
                    ProgressView()
                        .controlSize(.small)
                        .tint(vm.onAccentColor(scheme: colorScheme, contrast: contrast))
                } else {
                    Image(systemName: playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(vm.onAccentColor(scheme: colorScheme, contrast: contrast))
                        .offset(x: playing ? 0 : 2)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .frame(width: 60, height: 60)
            .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        }
        .buttonStyle(PressScaleButtonStyle())
        .accessibilityLabel(playing ? "Pause" : "Play")
        .help(playing ? "Pause" : "Play")
    }
}

private struct IdleState: View {
    @EnvironmentObject var vm: DashboardViewModel

    private var shortcut: String {
        KeyboardShortcuts.getShortcut(for: .playText)?.description ?? "⌘⇧."
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "text.bubble")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Palette.textTertiary)
            Text("Nothing Playing")
                .font(vm.appFont(size: 20, weight: .semibold))
                .foregroundStyle(Palette.textPrimary)
            Text("Select text in any app, then press \(shortcut).")
                .font(vm.appFont(size: 13))
                .foregroundStyle(Palette.textSecondary)
        }
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
