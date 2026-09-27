import SwiftUI

struct NowPlayingBar: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var bookVM: AudiobookViewModel
    @EnvironmentObject var audio: AudioService
    let book: Audiobook

    var body: some View {
        MiniPlayerChrome(
            progress: audio.progress,
            isPlaying: audio.isPlaying,
            elapsed: audio.currentTime,
            duration: audio.duration,
            openLabel: "Open \(book.displayTitle)",
            onOpen: { vm.openAudiobook(book.bookID) },
            onToggle: { bookVM.togglePlayback() },
            onClose: { vm.stopPlayback() }
        ) {
            AuthenticatedBackendImage(path: "audiobook/\(book.bookID)/cover") { image in
                image.resizable().scaledToFill()
            } placeholder: {
                ZStack {
                    Palette.controlFill
                    Image(systemName: "book.closed.fill")
                        .foregroundStyle(Palette.textTertiary)
                }
            }
            .frame(width: 32, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(Palette.separator, lineWidth: 1))
        } title: {
            Text(book.displayTitle)
        } subtitle: {
            Text(book.subtitle(at: audio.currentTime, chapters: bookVM.chapters(for: book)))
        }
    }
}

struct SpeechNowPlayingBar: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var audio: AudioService

    var body: some View {
        MiniPlayerChrome(
            progress: audio.progress,
            isPlaying: audio.isPlaying,
            elapsed: audio.currentTime,
            duration: audio.duration,
            openLabel: "Open Now Playing",
            onOpen: { vm.selectedTab = "home" },
            onToggle: { vm.togglePlayback() },
            onClose: { vm.stopPlayback() }
        ) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.controlFill)
                Image(systemName: "waveform")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.textSecondary)
                    .symbolEffect(.variableColor.iterative, isActive: audio.isPlaying)
            }
            .frame(width: 40, height: 40)
        } title: {
            Text(vm.spokenText ?? "Selected Text")
        } subtitle: {
            Text(vm.status == .thinking ? "Preparing…" : vm.currentVoiceDisplay)
        }
    }
}

private struct MiniPlayerChrome<Artwork: View, Title: View, Subtitle: View>: View {
    @EnvironmentObject var vm: DashboardViewModel
    let progress: Double
    let isPlaying: Bool
    let elapsed: TimeInterval
    let duration: TimeInterval
    let openLabel: String
    let onOpen: () -> Void
    let onToggle: () -> Void
    let onClose: () -> Void
    @ViewBuilder let artwork: () -> Artwork
    @ViewBuilder let title: () -> Title
    @ViewBuilder let subtitle: () -> Subtitle
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    artwork()
                    VStack(alignment: .leading, spacing: 2) {
                        title()
                            .font(vm.appFont(size: 13, weight: .semibold))
                            .foregroundStyle(Palette.textPrimary)
                        subtitle()
                            .font(vm.appFont(size: 11))
                            .foregroundStyle(Palette.textSecondary)
                    }
                    .lineLimit(1)
                    Spacer(minLength: 8)
                    Text("\(DurationFormatter.clock(elapsed)) / \(DurationFormatter.clock(duration))")
                        .font(vm.appFont(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(Palette.textSecondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(openLabel)
            .help(openLabel)

            TransportGlyph(systemName: isPlaying ? "pause.fill" : "play.fill", label: isPlaying ? "Pause" : "Play", size: 15, action: onToggle)
            TransportGlyph(systemName: "xmark", label: "Stop", size: 12, action: onClose)
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(alignment: .bottom) {
            GeometryReader { geometry in
                Rectangle()
                    .fill(Palette.textPrimary.opacity(0.35))
                    .frame(width: geometry.size.width * min(1, max(0, progress)), height: 2)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .animation(.linear(duration: 0.1), value: progress)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.large, style: .continuous))
        .voqoraSurface(.floating, in: RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.large, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.large, style: .continuous)
                .stroke(Palette.textPrimary.opacity(hovering ? 0.18 : 0), lineWidth: 1)
        )
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .frame(maxWidth: 720)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }
}
