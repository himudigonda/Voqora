import SwiftUI

struct ContinueListeningCard: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var bookVM: AudiobookViewModel
    @EnvironmentObject var audio: AudioService
    @Environment(\.voqoraTheme) private var theme
    let book: Audiobook

    private static let coverWidth: CGFloat = 132

    private var isCurrent: Bool {
        bookVM.nowPlaying?.bookID == book.bookID
    }

    private var fraction: Double {
        bookVM.listenedFraction(for: book)
    }

    private var hasStarted: Bool {
        fraction > LibraryFilter.startedThreshold
    }

    private var isPlaying: Bool {
        isCurrent && audio.isPlaying
    }

    private var chapterTitle: String {
        book.subtitle(at: fraction * book.totalAudioSeconds, chapters: bookVM.chapters(for: book))
    }

    private var timeLeft: String {
        let remaining = book.totalAudioSeconds * (1 - fraction)
        return remaining >= 1 ? "\(DurationFormatter.listing(remaining)) left" : "Finished"
    }

    var body: some View {
        VoqoraCard(.elevated) {
            HStack(alignment: .center, spacing: Theme.Space.section - 4) {
                BookCover(bookID: book.bookID, radius: Theme.Shape.lg)
                    .frame(width: Self.coverWidth, height: Self.coverWidth / BookCover.aspectRatio)
                    .shadow(color: .black.opacity(0.16), radius: 12, y: 5)
                VStack(alignment: .leading, spacing: Theme.Space.item) {
                    Text(hasStarted ? "Continue listening" : "Up next")
                        .font(vm.font(.labelSmall))
                        .foregroundStyle(theme.primary)
                        .textCase(.uppercase)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(book.displayTitle)
                            .font(vm.font(.headline))
                            .foregroundStyle(theme.onSurface)
                            .lineLimit(2)
                            .help(book.displayTitle)
                        Text(chapterTitle)
                            .font(vm.font(.body))
                            .foregroundStyle(theme.onSurfaceVariant)
                            .lineLimit(1)
                            .help(chapterTitle)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        PlayerProgressBar(fraction: fraction, height: 6)
                        HStack {
                            Text("\(Int((fraction * 100).rounded())) percent listened")
                            Spacer(minLength: 8)
                            Text(timeLeft)
                        }
                        .font(vm.font(.labelSmall))
                        .monospacedDigit()
                        .foregroundStyle(theme.onSurfaceVariant)
                    }
                    HStack(spacing: Theme.Space.item) {
                        Button {
                            if isCurrent {
                                bookVM.togglePlayback()
                            } else {
                                bookVM.play(book)
                            }
                        } label: {
                            Label(isPlaying ? "Pause" : (hasStarted ? "Resume" : "Listen"), systemImage: isPlaying ? "pause.fill" : "play.fill")
                        }
                        .buttonStyle(.voqoraFilled)
                        .disabled(bookVM.isLoadingAudio)
                        Button("Open player") {
                            vm.openAudiobook(book.bookID)
                        }
                        .buttonStyle(.voqoraTonal)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}
