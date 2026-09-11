import SwiftUI

/// Persistent bottom bar shown when an audiobook is playing and the user is
/// NOT on the player view. Mirrors the existing miniPlayerHUD pattern but
/// dedicated to audiobook playback.
struct NowPlayingBar: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var bookVM: AudiobookViewModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    var onTap: () -> Void

    /// The app's accent, resolved once per body pass — matches
    /// `VoqoraWindow`'s own `accentColor` pattern.
    private var accentColor: Color {
        vm.accentColor(scheme: colorScheme, contrast: colorSchemeContrast)
    }

    var body: some View {
        if let book = bookVM.nowPlaying {
            content(for: book)
        }
    }

    @ViewBuilder
    private func content(for book: Audiobook) -> some View {
        VStack(spacing: 0) {
            // Accent progress underline at the very top
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Palette.separator)
                    Rectangle()
                        .fill(accentColor)
                        .frame(width: geo.size.width * bookVM.audio.progress)
                        .animation(.linear(duration: 0.1), value: bookVM.audio.progress)
                }
            }
            .frame(height: 2)

            HStack(spacing: 14) {
                AuthenticatedBackendImage(path: "audiobook/\(book.bookID)/cover") { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Image(systemName: "book.fill")
                        .foregroundStyle(accentColor.opacity(0.6))
                }
                .frame(width: 40, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(prettyTitle(book))
                        .font(vm.appFont(size: 12, weight: .bold))
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(1)
                    if let section = bookVM.currentSection(in: book) {
                        Text(section.title.uppercased())
                            .font(vm.font(.sectionHeader))
                            .kerning(0.6)
                            .foregroundStyle(accentColor)
                            .lineLimit(1)
                    } else {
                        Text("AUDIOBOOK")
                            .font(vm.font(.sectionHeader))
                            .kerning(0.6)
                            .foregroundStyle(accentColor)
                    }
                }
                Spacer()

                Text("\(DurationFormatter.clock(bookVM.audio.currentTime)) / \(DurationFormatter.clock(bookVM.audio.duration))")
                    .font(vm.font(.caption).monospaced())
                    .foregroundStyle(Palette.textSecondary)

                HStack(spacing: 8) {
                    Button { bookVM.togglePlayback() } label: {
                        Image(systemName: bookVM.audio.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 13, weight: .black))
                            .foregroundStyle(Palette.textPrimary)
                            .frame(width: 32, height: 32)
                            .voqoraSurface(.control, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(bookVM.audio.isPlaying ? "Pause" : "Play")
                    .help(bookVM.audio.isPlaying ? "Pause" : "Play")

                    Button { bookVM.stopPlayback() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Palette.textSecondary)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Stop")
                    .help("Stop")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        // `voqoraSurface` only paints a background/border behind `content` —
        // it doesn't clip it — and the progress underline above spans the
        // bar's full width with square corners, so an explicit clip is still
        // needed to round them off (matching the old `.ultraThinMaterial` +
        // `.clipShape` pairing this replaces).
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.large, style: .continuous))
        .voqoraSurface(.floating, in: RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.large, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .onTapGesture { onTap() }
    }

    private func prettyTitle(_ book: Audiobook) -> String {
        let t = book.title
        for ext in [".pdf", ".docx", ".txt", ".md"] {
            if t.lowercased().hasSuffix(ext) { return String(t.dropLast(ext.count)) }
        }
        return t
    }
}
