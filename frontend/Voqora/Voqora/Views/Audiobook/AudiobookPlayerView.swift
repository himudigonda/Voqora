import SwiftUI

struct AudiobookPlayerView: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var bookVM: AudiobookViewModel
    @Environment(\.voqoraTheme) private var theme

    let book: Audiobook
    var onBack: () -> Void = {}
    @State private var panel: Panel = .transcript
    @StateObject private var assistant: AIAssistantViewModel
    @State private var pendingCitation: AICitation?

    init(book: Audiobook, onBack: @escaping () -> Void = {}) {
        self.book = book
        self.onBack = onBack
        _assistant = StateObject(wrappedValue: AIAssistantViewModel.restoring(bookID: book.bookID))
    }

    enum Panel: String, CaseIterable, Identifiable {
        case transcript = "Transcript"
        case chapters = "Chapters"
        case assistant = "Assistant"

        var id: String {
            rawValue
        }
    }

    private static let wideBreakpoint: CGFloat = 820
    private static let controlsWidth: CGFloat = 360

    var body: some View {
        PageScaffold(title: "Now Playing", scrolls: false) {
            GeometryReader { geometry in
                if geometry.size.width >= Self.wideBreakpoint {
                    wideLayout(height: geometry.size.height)
                } else {
                    compactLayout
                }
            }
        }
        .backButton("Library", action: onBack)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.space) { bookVM.togglePlayback(); return .handled }
        .onKeyPress(.leftArrow) { bookVM.skip(by: -15); return .handled }
        .onKeyPress(.rightArrow) { bookVM.skip(by: 30); return .handled }
        .onKeyPress("j") { bookVM.skip(by: -15); return .handled }
        .onKeyPress("l") { bookVM.skip(by: 30); return .handled }
        .onKeyPress("n") { bookVM.jumpToNextSection(in: book); return .handled }
        .onKeyPress("p") { bookVM.jumpToPreviousSection(in: book); return .handled }
        .onKeyPress("[") { bookVM.setSpeed(Double(bookVM.audio.playbackRate) - 0.25); return .handled }
        .onKeyPress("]") { bookVM.setSpeed(Double(bookVM.audio.playbackRate) + 0.25); return .handled }
        .onAppear {
            assistant.connect(bookVM.providers)
            bookVM.isPlayerViewActive = true
            if bookVM.nowPlaying?.bookID != book.bookID {
                bookVM.play(book)
            } else if bookVM.transcriptState == .unavailable || bookVM.transcriptState == .idle {
                bookVM.loadTranscript(for: book.bookID)
            }
        }
        .onDisappear {
            bookVM.isPlayerViewActive = false
            assistant.cancelAll()
        }
        .onChange(of: panel) { old, _ in
            if old == .assistant {
                assistant.cancelAll()
            }
        }
        .onChange(of: bookVM.transcriptState) { _, state in
            guard let citation = pendingCitation, isCurrentBook, state == .loaded || state == .unavailable else { return }
            jump(to: citation)
        }
    }

    private func wideLayout(height: CGFloat) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.section) {
            ScrollView {
                controlsColumn(coverHeight: min(280, max(150, height * 0.34)))
                    .padding(.bottom, Theme.Space.card)
            }
            .scrollIndicators(.never)
            .frame(width: Self.controlsWidth)
            rightPanel(fontSize: 24)
        }
        .padding(.horizontal, Theme.Space.gutter)
        .padding(.bottom, Theme.Space.card)
    }

    private var compactLayout: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.section) {
                controlsColumn(coverHeight: 150)
                    .frame(maxWidth: Self.controlsWidth)
                    .frame(maxWidth: .infinity)
                rightPanel(fontSize: 20)
                    .frame(height: 440)
            }
            .padding(.horizontal, Theme.Space.gutter)
            .padding(.bottom, Theme.Space.gutter)
        }
    }

    private func controlsColumn(coverHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.card) {
            PlayerArtwork(book: book, height: coverHeight)
                .frame(maxWidth: .infinity)
            AudiobookTitle(book: book)
            PlaybackScrubber(
                markers: bookVM.chapters(for: book).map(\.startTime),
                isEnabled: isCurrentBook,
                chapterTitle: chapterTitle(at:),
                onScrub: { bookVM.follower.scrub(to: $0) },
                onCommit: { bookVM.seek(toSeconds: $0) }
            )
            PlayerTransport(book: book)
                .frame(maxWidth: .infinity)
            PlayerSecondaryControls(book: book)
                .frame(maxWidth: .infinity)
        }
    }

    private func rightPanel(fontSize: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.item + 4) {
            HStack {
                SegmentedTabs(selection: $panel, options: Panel.allCases, title: { $0.rawValue })
                Spacer(minLength: 0)
                ReadingModeButton()
            }
            switch panel {
            case .transcript:
                transcript(fontSize: fontSize)
            case .chapters:
                PlayerChaptersList(book: book)
            case .assistant:
                AIAssistantPanel(model: assistant, onCitation: open(_:))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var isCurrentBook: Bool {
        bookVM.nowPlaying?.bookID == book.bookID
    }

    private func open(_ citation: AICitation) {
        if isCurrentBook, bookVM.transcriptState == .loaded || bookVM.transcriptState == .unavailable {
            jump(to: citation)
            return
        }
        pendingCitation = citation
        if !isCurrentBook {
            bookVM.play(book)
        } else if bookVM.transcriptState == .idle {
            bookVM.loadTranscript(for: book.bookID)
        }
    }

    private func jump(to citation: AICitation) {
        pendingCitation = nil
        if let line = AICitationLocator.line(for: citation, in: bookVM.follower.document) {
            bookVM.play(fromLine: line)
        } else if let start = book.pageToTime[String(citation.page)] {
            bookVM.seek(toSeconds: start)
            if !bookVM.audio.isPlaying {
                bookVM.audio.resume()
            }
        } else {
            bookVM.showToast("Voqora could not find that passage in the audio.")
            return
        }
        panel = .transcript
    }

    private func chapterTitle(at time: TimeInterval) -> String? {
        let chapters = bookVM.chapters(for: book)
        guard chapters.count > 1, let section = chapters.section(at: time) else { return nil }
        return AudiobookImportStaging.displayName(from: section.title)
    }

    @ViewBuilder
    private func transcript(fontSize: CGFloat) -> some View {
        switch (isCurrentBook, bookVM.transcriptState) {
        case (true, .loaded):
            TranscriptView(follower: bookVM.follower, fontSize: fontSize) { line in
                bookVM.play(fromLine: line)
            }
        case (true, .unavailable):
            EmptyStateView(
                symbol: "text.page.slash",
                title: "Transcript Unavailable",
                message: "Voqora could not load the text for this audiobook.",
                action: EmptyStateAction(title: "Try Again") { bookVM.loadTranscript(for: book.bookID) }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        default:
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Loading Transcript…")
                    .font(vm.font(.label))
                    .foregroundStyle(theme.onSurfaceMuted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct AudiobookTitle: View {
    @EnvironmentObject var bookVM: AudiobookViewModel
    @EnvironmentObject var audio: AudioService
    let book: Audiobook

    var body: some View {
        PlayerTitle(
            title: book.displayTitle,
            subtitle: book.subtitle(at: audio.currentTime, chapters: bookVM.chapters(for: book)),
            byline: book.displayAuthor.map { "by \($0)" }
        )
    }
}

private struct SectionSleepCountdown: View {
    @EnvironmentObject var bookVM: AudiobookViewModel
    @EnvironmentObject var audio: AudioService
    let book: Audiobook

    var body: some View {
        let remaining = bookVM.sectionEnd(in: book).map { max(0, $0 - audio.currentTime) } ?? 0
        Text(DurationFormatter.clock(remaining))
    }
}

private struct PlayerArtwork: View {
    @EnvironmentObject var audio: AudioService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let book: Audiobook
    let height: CGFloat

    var body: some View {
        let playing = audio.isPlaying
        BookCover(bookID: book.bookID, radius: Theme.Shape.lg)
            .frame(width: height * BookCover.aspectRatio, height: height)
            .shadow(color: .black.opacity(playing ? 0.24 : 0.12), radius: playing ? 22 : 10, y: playing ? 10 : 4)
            .scaleEffect(playing ? 1 : 0.96)
            .animation(reduceMotion ? nil : Theme.Motion.selection, value: playing)
    }
}

private struct PlayerTransport: View {
    @EnvironmentObject var bookVM: AudiobookViewModel
    @EnvironmentObject var audio: AudioService
    let book: Audiobook

    private var isCurrentBook: Bool {
        bookVM.nowPlaying?.bookID == book.bookID
    }

    var body: some View {
        HStack(spacing: 14) {
            TransportGlyph(systemName: "backward.end.fill", label: "Previous Section", size: 15) {
                bookVM.jumpToPreviousSection(in: book)
            }
            TransportGlyph(systemName: "gobackward.15", label: "Back 15 Seconds", size: 20) {
                bookVM.skip(by: -15)
            }
            PlayerPlayButton(
                isPlaying: isCurrentBook && audio.isPlaying,
                isLoading: bookVM.isLoadingAudio,
                size: 68
            ) {
                if isCurrentBook {
                    bookVM.togglePlayback()
                } else {
                    bookVM.play(book)
                }
            }
            TransportGlyph(systemName: "goforward.30", label: "Forward 30 Seconds", size: 20) {
                bookVM.skip(by: 30)
            }
            TransportGlyph(systemName: "forward.end.fill", label: "Next Section", size: 15) {
                bookVM.jumpToNextSection(in: book)
            }
        }
        .disabled(!isCurrentBook && bookVM.isLoadingAudio)
    }
}

private struct PlayerSecondaryControls: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var bookVM: AudiobookViewModel
    @EnvironmentObject var audio: AudioService
    let book: Audiobook
    @State private var showingPronunciations = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            PlayerSpeedMenu(speed: Double(audio.playbackRate), showsCaption: true) { bookVM.setSpeed($0) }
            PlayerVolumeButton()
            sleepMenu
            AudiobookExportButton(exports: bookVM.exports, book: book)
            moreMenu
        }
        .sheet(isPresented: $showingPronunciations) {
            BookPronunciationsSheet(book: book)
                .environmentObject(vm)
                .environmentObject(bookVM)
        }
    }

    private var moreMenu: some View {
        Menu {
            Button("Pronunciations for This Book…") { showingPronunciations = true }
            ReadingModeMenuButton()
        } label: {
            PlayerActionLabel(systemImage: "ellipsis", title: "More")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
        .accessibilityLabel("More")
    }

    private var sleepIsArmed: Bool {
        bookVM.sleepTimerEndsAt != nil || bookVM.sleepUntilEndOfBook || bookVM.sleepAtEndOfSection
    }

    private var sleepMenu: some View {
        Menu {
            ForEach(AudiobookViewModel.SleepDuration.allCases) { option in
                Button(option.menuTitle) { bookVM.startSleepTimer(option, currentBook: book) }
            }
            if sleepIsArmed {
                Divider()
                Button("Turn Off Sleep Timer") { bookVM.cancelSleepTimer() }
            }
        } label: {
            PlayerActionLabel(isActive: sleepIsArmed) {
                Image(systemName: sleepIsArmed ? "moon.zzz.fill" : "moon.zzz")
            } caption: {
                sleepCaption
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sleep Timer")
        .accessibilityLabel("Sleep Timer")
    }

    @ViewBuilder
    private var sleepCaption: some View {
        if let endsAt = bookVM.sleepTimerEndsAt {
            Text(timerInterval: Date() ... max(Date(), endsAt), countsDown: true)
        } else if bookVM.sleepAtEndOfSection {
            SectionSleepCountdown(book: book)
        } else if bookVM.sleepUntilEndOfBook {
            Text("End")
        } else {
            Text("Sleep")
        }
    }
}

private struct PlayerChaptersList: View {
    @EnvironmentObject var bookVM: AudiobookViewModel
    @EnvironmentObject var audio: AudioService
    let book: Audiobook

    var body: some View {
        let sections = bookVM.chapters(for: book)
        let isCurrentBook = bookVM.nowPlaying?.bookID == book.bookID
        let currentID = isCurrentBook ? sections.section(at: audio.currentTime)?.id : nil
        if sections.isEmpty {
            EmptyStateView(
                symbol: "list.number",
                title: "No chapters",
                message: "This audiobook has no chapter markers."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                ListGroup {
                    ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                        PlayerChapterRow(
                            section: section,
                            number: index + 1,
                            isCurrent: section.id == currentID,
                            isPlaying: audio.isPlaying
                        ) {
                            guard isCurrentBook else { return }
                            bookVM.seek(toSeconds: section.startTime)
                            if !audio.isPlaying {
                                audio.resume()
                            }
                        }
                    }
                }
                .padding(.bottom, Theme.Space.card)
            }
        }
    }
}

private struct PlayerChapterRow: View {
    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.voqoraTheme) private var theme
    let section: AudiobookSection
    let number: Int
    let isCurrent: Bool
    let isPlaying: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        let title = AudiobookImportStaging.displayName(from: section.title)
        Button(action: action) {
            HStack(spacing: 16) {
                Group {
                    if isCurrent, isPlaying {
                        Image(systemName: "waveform")
                            .symbolEffect(.variableColor.iterative, isActive: true)
                    } else {
                        Text("\(number)")
                    }
                }
                .font(vm.font(.label))
                .monospacedDigit()
                .foregroundStyle(isCurrent ? theme.onPrimaryContainer : theme.onSurfaceMuted)
                .frame(width: 28)
                Text(title)
                    .font(vm.font(isCurrent ? .titleSmall : .body))
                    .foregroundStyle(isCurrent ? theme.onPrimaryContainer : theme.onSurface)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .help(title)
                Spacer(minLength: 12)
                Text(DurationFormatter.clock(section.startTime))
                    .font(vm.font(.label))
                    .monospacedDigit()
                    .foregroundStyle(theme.onSurfaceVariant)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background, in: RoundedRectangle(cornerRadius: Theme.Shape.md, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Theme.Shape.md, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(Theme.Motion.hover, value: isHovered)
        .accessibilityLabel("\(title), \(DurationFormatter.clock(section.startTime))")
        .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
    }

    private var background: Color {
        if isCurrent {
            return theme.secondaryContainer
        }
        return isHovered ? theme.surfaceContainerHigh : theme.surfaceContainer
    }
}
