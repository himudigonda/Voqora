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
            speed: Double(audio.playbackRate),
            openLabel: "Open \(book.displayTitle)",
            onOpen: { vm.openAudiobook(book.bookID) },
            onToggle: { bookVM.togglePlayback() },
            onSkip: { bookVM.skip(by: $0) },
            onSpeed: { bookVM.setSpeed($0) },
            onClose: { vm.stopPlayback() }
        ) {
            BookCover(bookID: book.bookID, radius: Theme.Shape.xs)
                .frame(width: 32, height: 44)
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
    @Environment(\.voqoraTheme) private var theme

    var body: some View {
        MiniPlayerChrome(
            progress: audio.progress,
            isPlaying: audio.isPlaying,
            speed: vm.effectiveSpeechSpeed,
            openLabel: "Open Now Playing",
            onOpen: { vm.selectedTab = TabKey.home },
            onToggle: { vm.togglePlayback() },
            onSkip: { vm.skipSpeech(by: $0) },
            onSpeed: { vm.setSpeechSpeed($0) },
            onClose: { vm.stopPlayback() },
            extraActions: {
                Button {
                    vm.exportLastClip()
                } label: {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 14, weight: .medium))
                }
                .buttonStyle(.voqoraIcon)
                .disabled(!audio.canExportLastClip)
                .help("Save Clip to Desktop")
                .accessibilityLabel("Save Clip to Desktop")
            }
        ) {
            Image(systemName: "waveform")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(theme.onPrimaryContainer)
                .symbolEffect(.variableColor.iterative, isActive: audio.isPlaying)
                .frame(width: 44, height: 44)
                .background(theme.primaryContainer, in: RoundedRectangle(cornerRadius: Theme.Shape.sm, style: .continuous))
        } title: {
            Text(vm.spokenText ?? "Selected Text")
        } subtitle: {
            Text(vm.status == .thinking ? "Preparing…" : vm.currentVoiceDisplay)
        }
    }
}

private struct MiniPlayerChrome<Artwork: View, Title: View, Subtitle: View, Extra: View>: View {
    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.voqoraTheme) private var theme
    @Environment(\.openWindow) private var openWindow
    let progress: Double
    let isPlaying: Bool
    let speed: Double
    let openLabel: String
    let onOpen: () -> Void
    let onToggle: () -> Void
    let onSkip: (TimeInterval) -> Void
    let onSpeed: (Double) -> Void
    let onClose: () -> Void
    let extra: Extra
    @ViewBuilder let artwork: () -> Artwork
    @ViewBuilder let title: () -> Title
    @ViewBuilder let subtitle: () -> Subtitle

    init(
        progress: Double,
        isPlaying: Bool,
        speed: Double,
        openLabel: String,
        onOpen: @escaping () -> Void,
        onToggle: @escaping () -> Void,
        onSkip: @escaping (TimeInterval) -> Void,
        onSpeed: @escaping (Double) -> Void,
        onClose: @escaping () -> Void,
        @ViewBuilder extraActions: () -> Extra,
        @ViewBuilder artwork: @escaping () -> Artwork,
        @ViewBuilder title: @escaping () -> Title,
        @ViewBuilder subtitle: @escaping () -> Subtitle
    ) {
        self.progress = progress
        self.isPlaying = isPlaying
        self.speed = speed
        self.openLabel = openLabel
        self.onOpen = onOpen
        self.onToggle = onToggle
        self.onSkip = onSkip
        self.onSpeed = onSpeed
        self.onClose = onClose
        extra = extraActions()
        self.artwork = artwork
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: Theme.Space.item) {
                Button(action: onOpen) {
                    HStack(spacing: Theme.Space.item) {
                        artwork()
                        VStack(alignment: .leading, spacing: 2) {
                            title()
                                .font(vm.font(.titleSmall))
                                .foregroundStyle(theme.onSurface)
                            subtitle()
                                .font(vm.font(.bodySmall))
                                .foregroundStyle(theme.onSurfaceVariant)
                        }
                        .lineLimit(1)
                        Spacer(minLength: 8)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(openLabel)
                .help(openLabel)

                controls
            }
            PlayerProgressBar(fraction: progress, height: 3)
                .padding(.horizontal, 4)
        }
        .padding(.horizontal, Theme.Space.item + 4)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .voqoraCardBackground(.elevated, radius: Theme.Shape.xl)
        .overlay(RoundedRectangle(cornerRadius: Theme.Shape.xl, style: .continuous).strokeBorder(theme.outlineVariant, lineWidth: 1))
        .frame(maxWidth: 720)
        .padding(16)
        .frame(maxWidth: .infinity)
    }

    private var controls: some View {
        HStack(spacing: 2) {
            Button { onSkip(-10) } label: {
                Image(systemName: "gobackward.10").font(.system(size: 16, weight: .medium))
            }
            .buttonStyle(.voqoraIcon)
            .help("Back 10 Seconds")
            .accessibilityLabel("Back 10 Seconds")

            PlayerPlayButton(isPlaying: isPlaying, isLoading: false, size: 40, action: onToggle)

            Button { onSkip(10) } label: {
                Image(systemName: "goforward.10").font(.system(size: 16, weight: .medium))
            }
            .buttonStyle(.voqoraIcon)
            .help("Forward 10 Seconds")
            .accessibilityLabel("Forward 10 Seconds")

            PlayerSpeedMenu(speed: speed, onSelect: onSpeed)
                .padding(.horizontal, 4)

            Button { openWindow.openReadingMode() } label: {
                Image(systemName: "doc.plaintext").font(.system(size: 14, weight: .medium))
            }
            .buttonStyle(.voqoraIcon)
            .help(ReadingModeWindow.title)
            .accessibilityLabel(ReadingModeWindow.title)

            extra

            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.voqoraIcon)
            .help("Stop")
            .accessibilityLabel("Stop")
        }
    }
}

extension MiniPlayerChrome where Extra == EmptyView {
    init(
        progress: Double,
        isPlaying: Bool,
        speed: Double,
        openLabel: String,
        onOpen: @escaping () -> Void,
        onToggle: @escaping () -> Void,
        onSkip: @escaping (TimeInterval) -> Void,
        onSpeed: @escaping (Double) -> Void,
        onClose: @escaping () -> Void,
        @ViewBuilder artwork: @escaping () -> Artwork,
        @ViewBuilder title: @escaping () -> Title,
        @ViewBuilder subtitle: @escaping () -> Subtitle
    ) {
        self.init(
            progress: progress,
            isPlaying: isPlaying,
            speed: speed,
            openLabel: openLabel,
            onOpen: onOpen,
            onToggle: onToggle,
            onSkip: onSkip,
            onSpeed: onSpeed,
            onClose: onClose,
            extraActions: { EmptyView() },
            artwork: artwork,
            title: title,
            subtitle: subtitle
        )
    }
}
