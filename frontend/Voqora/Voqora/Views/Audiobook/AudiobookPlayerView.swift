import AppKit
import SwiftUI

struct AudiobookPlayerView: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var bookVM: AudiobookViewModel

    let book: Audiobook
    @State private var panel: Panel = .transcript
    @State private var tint: Color?

    enum Panel: String, CaseIterable, Identifiable {
        case transcript = "Transcript"
        case sections = "Sections"

        var id: String {
            rawValue
        }
    }

    var body: some View {
        PlayerScaffold(tint: tint) { height in
            PlayerArtwork(book: book, height: height)
        } header: { alignment in
            AudiobookTitle(book: book, alignment: alignment)
        } controls: { compact in
            VStack(spacing: compact ? 14 : 22) {
                PlaybackScrubber(
                    markers: bookVM.chapters(for: book).map(\.startTime),
                    isEnabled: isCurrentBook,
                    chapterTitle: chapterTitle(at:),
                    onScrub: { bookVM.follower.scrub(to: $0) },
                    onCommit: { bookVM.seek(toSeconds: $0) }
                )
                PlayerTransport(book: book, compact: compact)
                PlayerSecondaryControls(book: book)
                    .frame(maxWidth: compact ? 420 : .infinity)
            }
        } content: { fontSize in
            VStack(spacing: 0) {
                PlayerSegmentedHeader(selection: $panel)
                switch panel {
                case .transcript:
                    transcript(fontSize: fontSize)
                case .sections:
                    PlayerSectionsList(book: book)
                }
            }
        }
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
            bookVM.isPlayerViewActive = true
            if bookVM.nowPlaying?.bookID != book.bookID {
                bookVM.play(book)
            } else if bookVM.transcriptState == .unavailable || bookVM.transcriptState == .idle {
                bookVM.loadTranscript(for: book.bookID)
            }
        }
        .onDisappear {
            bookVM.isPlayerViewActive = false
        }
        .task(id: book.bookID) {
            let color = await CoverColorExtractor.shared.dominantColor(forBackendPath: "audiobook/\(book.bookID)/cover")
            withAnimation(.easeInOut(duration: 0.6)) {
                tint = color
            }
        }
    }

    private var isCurrentBook: Bool {
        bookVM.nowPlaying?.bookID == book.bookID
    }

    private func chapterTitle(at time: TimeInterval) -> String? {
        let chapters = bookVM.chapters(for: book)
        guard chapters.count > 1, let section = chapters.section(at: time) else { return nil }
        return AudiobookImportStaging.strippingSupportedExtension(from: section.title)
    }

    @ViewBuilder
    private func transcript(fontSize: CGFloat) -> some View {
        switch (isCurrentBook, bookVM.transcriptState) {
        case (true, .loaded):
            TranscriptView(follower: bookVM.follower, fontSize: fontSize) { line in
                bookVM.play(fromLine: line)
            }
        case (true, .unavailable):
            VStack(spacing: 12) {
                Text("Transcript Unavailable")
                    .font(vm.appFont(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.textSecondary)
                Button("Try Again") { bookVM.loadTranscript(for: book.bookID) }
                    .buttonStyle(.voqoraSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        default:
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Loading Transcript…")
                    .font(vm.appFont(size: 12, weight: .medium))
                    .foregroundStyle(Palette.textTertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct AudiobookTitle: View {
    @EnvironmentObject var bookVM: AudiobookViewModel
    @EnvironmentObject var audio: AudioService
    let book: Audiobook
    let alignment: HorizontalAlignment

    var body: some View {
        PlayerTitle(
            title: book.displayTitle,
            subtitle: book.subtitle(at: audio.currentTime, chapters: bookVM.chapters(for: book)),
            alignment: alignment
        )
    }
}

private struct PlayerArtwork: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var audio: AudioService
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let book: Audiobook
    let height: CGFloat

    private var width: CGFloat {
        height * AudiobookCardView.coverAspectRatio
    }

    private var radius: CGFloat {
        height > 120 ? 14 : 8
    }

    var body: some View {
        let playing = audio.isPlaying
        let ramp = Palette.accentRamp(for: vm.accentColorID, appearance: colorScheme, increaseContrast: contrast == .increased)
        AuthenticatedBackendImage(path: "audiobook/\(book.bookID)/cover") { image in
            image.resizable().scaledToFill()
        } placeholder: {
            ZStack {
                LinearGradient(colors: [Color(ramp.muted), Color(ramp.subtle)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "book.fill")
                    .font(.system(size: height * 0.18, weight: .ultraLight))
                    .foregroundStyle(Palette.textPrimary.opacity(0.7))
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(Palette.separator, lineWidth: 1))
        .shadow(color: .black.opacity(playing ? 0.35 : 0.2), radius: playing ? 24 : 12, y: playing ? 12 : 6)
        .scaleEffect(playing || height <= 120 ? 1 : 0.94)
        .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.8), value: playing)
        .accessibilityHidden(true)
    }
}

private struct PlayerTransport: View {
    @EnvironmentObject var bookVM: AudiobookViewModel
    @EnvironmentObject var audio: AudioService
    let book: Audiobook
    let compact: Bool

    private var isCurrentBook: Bool {
        bookVM.nowPlaying?.bookID == book.bookID
    }

    var body: some View {
        HStack(spacing: compact ? 14 : 22) {
            TransportGlyph(systemName: "backward.end.fill", label: "Previous Section") {
                bookVM.jumpToPreviousSection(in: book)
            }
            TransportGlyph(systemName: "gobackward.15", label: "Back 15 Seconds") {
                bookVM.skip(by: -15)
            }
            PlayerPlayButton(
                isPlaying: isCurrentBook && audio.isPlaying,
                isLoading: bookVM.isLoadingAudio,
                size: compact ? 48 : 64
            ) {
                if isCurrentBook {
                    bookVM.togglePlayback()
                } else {
                    bookVM.play(book)
                }
            }
            TransportGlyph(systemName: "goforward.30", label: "Forward 30 Seconds") {
                bookVM.skip(by: 30)
            }
            TransportGlyph(systemName: "forward.end.fill", label: "Next Section") {
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
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    let book: Audiobook
    @State private var isExporting = false

    private var accent: Color {
        vm.accentColor(scheme: colorScheme, contrast: contrast)
    }

    var body: some View {
        HStack(spacing: 10) {
            PlayerSpeedMenu(speed: Double(audio.playbackRate)) { bookVM.setSpeed($0) }
            Spacer(minLength: 0)
            PlayerVolumeControl()
            Spacer(minLength: 0)
            sleepMenu
            PlayerCircleButton(
                systemName: "square.and.arrow.down",
                label: "Export Audio…",
                isEnabled: !isExporting && book.status == "done",
                action: export
            )
        }
    }

    private var sleepIsArmed: Bool {
        bookVM.sleepTimerEndsAt != nil || bookVM.sleepUntilEndOfBook
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
            HStack(spacing: 5) {
                Image(systemName: sleepIsArmed ? "moon.zzz.fill" : "moon.zzz")
                    .font(.system(size: 13, weight: .medium))
                if let endsAt = bookVM.sleepTimerEndsAt {
                    Text(timerInterval: Date() ... max(Date(), endsAt), countsDown: true)
                        .font(vm.appFont(size: 11, weight: .semibold))
                        .monospacedDigit()
                } else if bookVM.sleepUntilEndOfBook {
                    Text("End")
                        .font(vm.appFont(size: 11, weight: .semibold))
                }
            }
            .foregroundStyle(sleepIsArmed ? accent : Palette.textPrimary)
            .padding(.horizontal, sleepIsArmed ? 10 : 0)
            .frame(minWidth: 30, minHeight: 30)
            .background(Capsule().fill(Palette.controlFill))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sleep Timer")
        .accessibilityLabel("Sleep Timer")
    }

    private func export() {
        guard !isExporting else { return }
        isExporting = true
        Task { @MainActor in
            defer { isExporting = false }
            do {
                let source = try await bookVM.validatedAudioURL(for: book)
                let panel = NSSavePanel()
                panel.title = "Export Audio"
                panel.nameFieldStringValue = "\(book.displayTitle).wav"
                panel.canCreateDirectories = true
                guard panel.runModal() == .OK, let destination = panel.url else { return }
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: source, to: destination)
                bookVM.showToast("Exported \(destination.lastPathComponent)", kind: .success)
            } catch {
                bookVM.showToast("Couldn't export this audiobook.", kind: .error)
            }
        }
    }
}

private struct PlayerSectionsList: View {
    @EnvironmentObject var vm: DashboardViewModel
    @EnvironmentObject var bookVM: AudiobookViewModel
    @EnvironmentObject var audio: AudioService
    let book: Audiobook

    var body: some View {
        let sections = bookVM.chapters(for: book)
        let isCurrentBook = bookVM.nowPlaying?.bookID == book.bookID
        let currentID = isCurrentBook ? sections.section(at: audio.currentTime)?.id : nil
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                    PlayerSectionRow(
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
            .frame(maxWidth: 640)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
        }
        .overlay {
            if sections.isEmpty {
                Text("No Sections")
                    .font(vm.appFont(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.textSecondary)
            }
        }
    }
}

private struct PlayerSectionRow: View {
    @EnvironmentObject var vm: DashboardViewModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    let section: AudiobookSection
    let number: Int
    let isCurrent: Bool
    let isPlaying: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        let accent = vm.accentColor(scheme: colorScheme, contrast: contrast)
        let title = AudiobookImportStaging.strippingSupportedExtension(from: section.title)
        Button(action: action) {
            HStack(spacing: 14) {
                Group {
                    if isCurrent, isPlaying {
                        Image(systemName: "waveform")
                            .symbolEffect(.variableColor.iterative, isActive: true)
                            .foregroundStyle(accent)
                    } else {
                        Text("\(number)")
                            .foregroundStyle(isCurrent ? accent : Palette.textTertiary)
                    }
                }
                .font(vm.appFont(size: 12, weight: .semibold))
                .monospacedDigit()
                .frame(width: 24)
                Text(title)
                    .font(vm.appFont(size: 14, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? accent : Palette.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 12)
                Text(DurationFormatter.clock(section.startTime))
                    .font(vm.appFont(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Palette.textSecondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous)
                    .fill(isHovered ? Palette.controlFill : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.sm, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel("\(title), \(DurationFormatter.clock(section.startTime))")
        .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
    }
}
