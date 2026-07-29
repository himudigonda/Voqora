import SwiftUI

/// Persistent bottom bar shown when an audiobook is playing and the user is
/// NOT on the player view. Mirrors the existing miniPlayerHUD pattern but
/// dedicated to audiobook playback.
struct NowPlayingBar: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var bookVM: AudiobookViewModel
    var onTap: () -> Void

    private let baseURL = URL(string: "http://127.0.0.1:10101")!

    var body: some View {
        if let book = bookVM.nowPlaying {
            content(for: book)
        }
    }

    @ViewBuilder
    private func content(for book: Audiobook) -> some View {
        VStack(spacing: 0) {
            // Cyan progress underline at the very top
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.primary.opacity(0.06))
                    Rectangle()
                        .fill(.cyan)
                        .frame(width: geo.size.width * bookVM.audio.progress)
                        .animation(.linear(duration: 0.1), value: bookVM.audio.progress)
                }
            }
            .frame(height: 2)

            HStack(spacing: 14) {
                AsyncImage(url: baseURL.appendingPathComponent("audiobook/\(book.bookID)/cover")) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Image(systemName: "book.fill")
                        .foregroundStyle(.cyan.opacity(0.6))
                }
                .frame(width: 40, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(prettyTitle(book))
                        .font(vm.appFont(size: 12, weight: .bold))
                        .lineLimit(1)
                    if let section = bookVM.currentSection(in: book) {
                        Text(section.title.uppercased())
                            .font(vm.appFont(size: 9, weight: .black))
                            .kerning(1)
                            .foregroundStyle(.cyan)
                            .lineLimit(1)
                    } else {
                        Text("AUDIOBOOK")
                            .font(vm.appFont(size: 9, weight: .black))
                            .kerning(1)
                            .foregroundStyle(.cyan)
                    }
                }
                Spacer()

                Text("\(DurationFormatter.clock(bookVM.audio.currentTime)) / \(DurationFormatter.clock(bookVM.audio.duration))")
                    .font(vm.appFont(size: 10).monospaced())
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Button { bookVM.togglePlayback() } label: {
                        Image(systemName: bookVM.audio.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 13, weight: .black))
                            .foregroundStyle(.primary)
                            .frame(width: 32, height: 32)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)

                    Button { bookVM.stopPlayback() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
        .onTapGesture { onTap() }
    }

    private func prettyTitle(_ book: Audiobook) -> String {
        var t = book.title
        for ext in [".pdf", ".docx", ".txt", ".md"] {
            if t.lowercased().hasSuffix(ext) { return String(t.dropLast(ext.count)) }
        }
        return t
    }
}
