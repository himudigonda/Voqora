import SwiftUI

/// Persistent bottom bar shown when an audiobook is playing and the user is
/// NOT on the player view. Mirrors the existing miniPlayerHUD pattern but
/// dedicated to audiobook playback.
struct NowPlayingBar: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var bookVM: AudiobookViewModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @State private var hovering = false
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
                    image.resizable().scaledToFill()
                } placeholder: {
                    Image(systemName: "book.fill")
                        .foregroundStyle(accentColor.opacity(0.6))
                }
                .frame(width: 40, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                // The only cover in the app drawn without a hairline. A
                // scanned document's cover is a white page, and this bar is
                // `surfaceRaised` — near-white in light mode — so the
                // thumbnail had no edge at all there and read as a smear of
                // grey text floating in the bar. Every other cover (the
                // player's cover column and compact header, the library
                // card) already strokes `Palette.separator`.
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Palette.separator, lineWidth: 1)
                )

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

                    // Was a 28pt box next to the play button's 32pt one: two
                    // adjacent controls on different grids, and the smaller
                    // of the two was the one you least want to mis-click.
                    //
                    // Routed through `vm.stopPlayback()` (DashboardViewModel),
                    // NOT `bookVM.stopPlayback()` directly. Both stop the same
                    // shared AudioService the same way — `vm.stopPlayback()`
                    // delegates to `audiobookVM.stopPlayback()` here too — but
                    // only the dashboard's own `stopPlayback()` also resets
                    // `status` back to `.ready` afterward. A manual mid-book
                    // stop is not a natural completion, so `audio.playbackCompleted`
                    // is false and the `audio.$isPlaying` sink in
                    // DashboardViewModel leaves `status` at `.paused` — with
                    // `bookVM.stopPlayback()` called directly, nothing ever
                    // moved it off `.paused` again, so switching to a
                    // non-home tab kept showing `miniPlayerHUD` ("PAUSED",
                    // stale dashboard-TTS history text) indefinitely even
                    // though nothing was playing or paused.
                    Button { vm.stopPlayback() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Palette.textSecondary)
                            .frame(width: 32, height: 32)
                            .contentShape(Circle())
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
        // The whole bar opens the full player, but nothing said so: no
        // hover feedback, no tooltip, no pointer change. It read as a
        // static status strip with two buttons on it.
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.large, style: .continuous)
                .stroke(accentColor.opacity(hovering ? 0.55 : 0), lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .help("Open the full player")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens the full audiobook player")
    }

    private func prettyTitle(_ book: Audiobook) -> String {
        let t = book.title
        for ext in [".pdf", ".docx", ".txt", ".md"] where t.lowercased().hasSuffix(ext) {
            return String(t.dropLast(ext.count))
        }
        return t
    }
}
